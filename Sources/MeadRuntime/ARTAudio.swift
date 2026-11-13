internal import CSwiftJavaJNI
import Glibc
import MeadWindow
internal import SwiftJavaJNICore

/// `android.media.AudioTrack`'s natives over SDL's audio: each track an SDL
/// audio stream on the default playback device, in place of Android's,
/// which talk to AudioFlinger.
///
/// A streaming track queues what's written, up to its buffer's size
/// (blocking writes wait for room); a static track keeps what's written and
/// queues it when played, as many times as its loop says. The playback head
/// is what's been written less what the stream still holds.
final class ARTAudioTrack {
    // AudioTrack's constants.
    static let success: Int32 = 0
    static let errorBadValue: Int32 = -2
    static let errorInvalidOperation: Int32 = -3
    static let modeStatic: Int32 = 0
    static let encodingPCM16: Int32 = 2
    static let encodingPCM8: Int32 = 3
    static let encodingFloat: Int32 = 4

    let stream: SDL.Pointer
    let sampleRate: Int32
    let frameSize: Int32
    let capacity: Int32
    let isStatic: Bool
    private var lock = pthread_mutex_t()
    private var playing = false
    /// Frames written to the stream since the last flush or stop.
    private var framesQueued: Int64 = 0
    private var staticData: [UInt8] = []
    private var loopCount: Int32 = 0
    private var playbackRate: Int32
    private var marker: Int32 = 0
    private var updatePeriod: Int32 = 0

    init(stream: SDL.Pointer, sampleRate: Int32, frameSize: Int32, capacity: Int32, isStatic: Bool) {
        self.stream = stream
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.capacity = capacity
        self.isStatic = isStatic
        playbackRate = sampleRate
        pthread_mutex_init(&lock, nil)
    }

    deinit {
        SDL.destroyAudioStream(stream)
    }

    // MARK: The natives' work

    func start() {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        if isStatic, !playing {
            queueStatic()
        }
        playing = true
        _ = SDL.resumeAudioStreamDevice(stream)
    }

    func stop() {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        playing = false
        _ = SDL.pauseAudioStreamDevice(stream)
        _ = SDL.clearAudioStream(stream)
        framesQueued = 0
    }

    func pause() {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        _ = SDL.pauseAudioStreamDevice(stream)
    }

    func flush() {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        _ = SDL.clearAudioStream(stream)
        framesQueued = 0
    }

    /// Writes bytes, waiting for room when blocking; the bytes written.
    func write(_ bytes: UnsafeRawPointer, count: Int32, blocking: Bool) -> Int32 {
        if isStatic {
            pthread_mutex_lock(&lock)
            defer { pthread_mutex_unlock(&lock) }
            let room = max(Int(capacity) - staticData.count, 0)
            let taken = min(Int(count), room)
            staticData.append(contentsOf: UnsafeRawBufferPointer(start: bytes, count: taken))
            return Int32(taken)
        }
        var written: Int32 = 0
        while written < count {
            let room = capacity - SDL.getAudioStreamQueued(stream)
            if room < frameSize {
                if !blocking { break }
                usleep(2000)
                continue
            }
            // Whole frames only.
            let chunk = min(count - written, room) / frameSize * frameSize
            guard chunk > 0 else { break }
            pthread_mutex_lock(&lock)
            let put = SDL.putAudioStreamData(stream, bytes + Int(written), chunk)
            if put { framesQueued += Int64(chunk / frameSize) }
            pthread_mutex_unlock(&lock)
            guard put else { break }
            written += chunk
        }
        return written
    }

    func reloadStatic() -> Int32 {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        _ = SDL.clearAudioStream(stream)
        framesQueued = 0
        if playing { queueStatic() }
        return Self.success
    }

    /// Under the lock: the static data, once and then once per loop.
    private func queueStatic() {
        guard !staticData.isEmpty else { return }
        let times = loopCount < 0 ? 64 : Int(loopCount) + 1
        staticData.withUnsafeBytes { data in
            for _ in 0..<times where SDL.putAudioStreamData(stream, data.baseAddress, Int32(data.count)) {
                framesQueued += Int64(data.count) / Int64(frameSize)
            }
        }
    }

    /// Frames played since the last flush or stop.
    var position: Int32 {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        let held = Int64(SDL.getAudioStreamQueued(stream) / frameSize)
        return Int32(truncatingIfNeeded: max(framesQueued - held, 0))
    }

    func setVolume(_ volume: Float) {
        _ = SDL.setAudioStreamGain(stream, volume)
    }

    func setPlaybackRate(_ rate: Int32) -> Int32 {
        guard rate > 0, SDL.setAudioStreamFrequencyRatio(stream, Float(rate) / Float(sampleRate)) else {
            return Self.errorBadValue
        }
        playbackRate = rate
        return Self.success
    }

    var currentPlaybackRate: Int32 { playbackRate }

    func setLoop(count: Int32) -> Int32 {
        loopCount = count
        return Self.success
    }

    func setMarker(_ position: Int32) -> Int32 {
        marker = position
        return Self.success
    }

    var markerPosition: Int32 { marker }

    func setUpdatePeriod(_ period: Int32) -> Int32 {
        updatePeriod = period
        return Self.success
    }

    var positionUpdatePeriod: Int32 { updatePeriod }

    // MARK: Opening

    /// The default playback device's rate, or 48 kHz when SDL can't say.
    static func outputSampleRate() -> Int32 {
        guard audioReady() else { return 48000 }
        var spec = mead_sdl_audio_spec()
        var frames: Int32 = 0
        guard SDL.getAudioDeviceFormat(MEAD_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, &frames), spec.freq > 0 else {
            return 48000
        }
        return spec.freq
    }

    /// SDL's audio subsystem, started once.
    nonisolated(unsafe) private static var ready: Bool?

    static func audioReady() -> Bool {
        if let ready { return ready }
        let started = SDL.loadOnce() && SDL.initialize(UInt32(MEAD_SDL_INIT_AUDIO))
        if !started {
            ARTDisplay.report("audio: SDL: \(SDL.lastError)")
        }
        ready = started
        return started
    }

    /// SDL's format for an AudioFormat encoding, and its bytes per sample.
    static func sdlFormat(_ encoding: Int32) -> (format: Int32, bytes: Int32)? {
        switch encoding {
        case encodingPCM16, 1: return (Int32(MEAD_SDL_AUDIO_S16LE), 2)  // 1: ENCODING_DEFAULT
        case encodingPCM8: return (Int32(MEAD_SDL_AUDIO_U8), 1)
        case encodingFloat: return (Int32(MEAD_SDL_AUDIO_F32LE), 4)
        default: return nil
        }
    }

    /// The channels in an AudioFormat channel mask (or channel index mask).
    static func channels(mask: Int32, indexMask: Int32) -> Int32 {
        let count = Int32((mask != 0 ? mask : indexMask).nonzeroBitCount)
        return max(count, 1)
    }

    static func open(rate: Int32, channels: Int32, encoding: Int32, bufferBytes: Int32, mode: Int32) -> ARTAudioTrack? {
        guard audioReady(), let (format, bytes) = sdlFormat(encoding) else { return nil }
        var spec = mead_sdl_audio_spec(format: format, channels: channels, freq: rate)
        guard let stream = SDL.openAudioDeviceStream(MEAD_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil) else {
            ARTDisplay.report("audio: no stream: \(SDL.lastError)")
            return nil
        }
        // SDL opens the device paused; play() resumes it.
        _ = SDL.pauseAudioStreamDevice(stream)
        let frameSize = channels * bytes
        let capacity = max(bufferBytes / frameSize * frameSize, frameSize)
        return ARTAudioTrack(stream: stream, sampleRate: rate, frameSize: frameSize, capacity: capacity,
                             isStatic: mode == modeStatic)
    }
}

extension ART {
    /// AudioTrack's Java fields: the track, as Android's JNI keeps it.
    nonisolated(unsafe) static var audioTrackField: jfieldID?

    /// The track an AudioTrack's natives work on.
    static func track(_ env: UnsafeMutablePointer<JNIEnv?>?, _ object: jobject?) -> ARTAudioTrack? {
        guard let env, let jni = env.pointee?.pointee, let object, let field = audioTrackField else { return nil }
        let pointer = jni.GetLongField(env, object, field)
        guard pointer != 0, let raw = UnsafeRawPointer(bitPattern: Int(pointer)) else { return nil }
        return Unmanaged<ARTAudioTrack>.fromOpaque(raw).takeUnretainedValue()
    }

    /// Registers AudioTrack's natives.
    func registerAudioTrack() throws {
        let env = try virtualMachine.environment()
        guard let jni = env.pointee?.pointee else { throw Failure("no JNIEnv") }
        guard let type = jni.FindClass(env, "android/media/AudioTrack"),
              let field = jni.GetFieldID(env, type, "mNativeTrackInJavaObj", "J") else {
            throw Failure("AudioTrack has no mNativeTrackInJavaObj\(describeException(env))")
        }
        Self.audioTrackField = field
        jni.DeleteLocalRef(env, type)

        typealias Env = UnsafeMutablePointer<JNIEnv?>?
        typealias Setup = @convention(c) (Env, jobject?, jobject?, jobject?, jintArray?, jint, jint, jint, jint, jint,
                                          jintArray?, jlong, jboolean) -> jint
        typealias Void0 = @convention(c) (Env, jobject?) -> Void
        typealias Int0 = @convention(c) (Env, jobject?) -> jint
        typealias Int1 = @convention(c) (Env, jobject?, jint) -> jint
        typealias Write = @convention(c) (Env, jobject?, jarray?, jint, jint, jint, jboolean) -> jint
        typealias WriteNative = @convention(c) (Env, jobject?, jobject?, jint, jint, jint, jboolean) -> jint
        typealias SetVolume = @convention(c) (Env, jobject?, jfloat, jfloat) -> Void
        typealias Timestamp = @convention(c) (Env, jobject?, jlongArray?) -> jint
        typealias SetLoop = @convention(c) (Env, jobject?, jint, jint, jint) -> jint
        typealias OutputRate = @convention(c) (Env, jclass?, jint) -> jint
        typealias MinBuffer = @convention(c) (Env, jclass?, jint, jint, jint) -> jint
        typealias Bool1 = @convention(c) (Env, jobject?, jint) -> jboolean
        typealias Padding = @convention(c) (Env, jobject?, jint, jint) -> Void
        typealias Object0 = @convention(c) (Env, jobject?) -> jobject?

        let setup: Setup = { env, this, _, _, sampleRate, channelMask, channelIndexMask, format, bufferBytes, mode,
                             session, _, _ in
            guard let env, let jni = env.pointee?.pointee, let sampleRate, let session else {
                return ARTAudioTrack.errorBadValue
            }
            var rate: jint = 0
            jni.GetIntArrayRegion(env, sampleRate, 0, 1, &rate)
            if rate == 0 {
                rate = ARTAudioTrack.outputSampleRate()
                jni.SetIntArrayRegion(env, sampleRate, 0, 1, &rate)
            }
            let channels = ARTAudioTrack.channels(mask: channelMask, indexMask: channelIndexMask)
            guard let track = ARTAudioTrack.open(rate: rate, channels: channels, encoding: format,
                                                 bufferBytes: bufferBytes, mode: mode) else {
                return ARTAudioTrack.errorInvalidOperation
            }
            var id: jint = 0
            jni.GetIntArrayRegion(env, session, 0, 1, &id)
            if id == 0 {
                id = 1
                jni.SetIntArrayRegion(env, session, 0, 1, &id)
            }
            let pointer = jlong(Int(bitPattern: Unmanaged.passRetained(track).toOpaque()))
            jni.SetLongField(env, this, ART.audioTrackField!, pointer)
            return ARTAudioTrack.success
        }
        let release: Void0 = { env, this in
            guard let env, let jni = env.pointee?.pointee, let this, let field = ART.audioTrackField else { return }
            let pointer = jni.GetLongField(env, this, field)
            jni.SetLongField(env, this, field, 0)
            guard pointer != 0, let raw = UnsafeRawPointer(bitPattern: Int(pointer)) else { return }
            Unmanaged<ARTAudioTrack>.fromOpaque(raw).release()
        }
        let start: Void0 = { env, this in ART.track(env, this)?.start() }
        let stop: Void0 = { env, this in ART.track(env, this)?.stop() }
        let pause: Void0 = { env, this in ART.track(env, this)?.pause() }
        let flush: Void0 = { env, this in ART.track(env, this)?.flush() }
        // Each array's elements, sizes counted in elements of elementSize bytes.
        func write(_ env: Env, _ this: jobject?, _ array: jarray?, _ offset: jint, _ size: jint, _ elementSize: Int32,
                   _ blocking: jboolean) -> jint {
            guard let env, let jni = env.pointee?.pointee, let array, let track = ART.track(env, this) else {
                return ARTAudioTrack.errorInvalidOperation
            }
            guard let elements = jni.GetPrimitiveArrayCritical(env, array, nil) else { return ARTAudioTrack.errorBadValue }
            let written = track.write(elements + Int(offset * elementSize), count: size * elementSize, blocking: blocking != 0)
            jni.ReleasePrimitiveArrayCritical(env, array, elements, JNI_ABORT)
            return written / elementSize
        }
        let writeByte: Write = { env, this, array, offset, size, _, blocking in write(env, this, array, offset, size, 1, blocking) }
        let writeShort: Write = { env, this, array, offset, size, _, blocking in write(env, this, array, offset, size, 2, blocking) }
        let writeFloat: Write = { env, this, array, offset, size, _, blocking in write(env, this, array, offset, size, 4, blocking) }
        let writeNative: WriteNative = { env, this, buffer, position, size, _, blocking in
            guard let env, let jni = env.pointee?.pointee, let buffer, let track = ART.track(env, this),
                  let address = jni.GetDirectBufferAddress(env, buffer) else { return ARTAudioTrack.errorBadValue }
            return track.write(address + Int(position), count: size, blocking: blocking != 0)
        }
        let reloadStatic: Int0 = { env, this in ART.track(env, this)?.reloadStatic() ?? ARTAudioTrack.errorInvalidOperation }
        let bufferFrames: Int0 = { env, this in
            guard let track = ART.track(env, this) else { return 0 }
            return track.capacity / track.frameSize
        }
        let setBufferFrames: Int1 = { env, this, _ in
            guard let track = ART.track(env, this) else { return ARTAudioTrack.errorInvalidOperation }
            return track.capacity / track.frameSize
        }
        let setVolume: SetVolume = { env, this, left, right in ART.track(env, this)?.setVolume(max(left, right)) }
        let setRate: Int1 = { env, this, rate in ART.track(env, this)?.setPlaybackRate(rate) ?? ARTAudioTrack.errorInvalidOperation }
        let getRate: Int0 = { env, this in ART.track(env, this)?.currentPlaybackRate ?? 0 }
        let setMarker: Int1 = { env, this, marker in ART.track(env, this)?.setMarker(marker) ?? ARTAudioTrack.errorInvalidOperation }
        let getMarker: Int0 = { env, this in ART.track(env, this)?.markerPosition ?? 0 }
        let setPeriod: Int1 = { env, this, period in ART.track(env, this)?.setUpdatePeriod(period) ?? ARTAudioTrack.errorInvalidOperation }
        let getPeriod: Int0 = { env, this in ART.track(env, this)?.positionUpdatePeriod ?? 0 }
        let setPosition: Int1 = { env, this, _ in ART.track(env, this) != nil ? ARTAudioTrack.success : ARTAudioTrack.errorInvalidOperation }
        let getPosition: Int0 = { env, this in ART.track(env, this)?.position ?? 0 }
        let latency: Int0 = { env, this in
            guard let track = ART.track(env, this) else { return 0 }
            return jint(Int64(track.capacity / track.frameSize) * 1000 / Int64(track.sampleRate))
        }
        let zero: Int0 = { _, _ in 0 }
        let timestamp: Timestamp = { env, this, longs in
            guard let env, let jni = env.pointee?.pointee, let longs, let track = ART.track(env, this) else {
                return ARTAudioTrack.errorInvalidOperation
            }
            var now = timespec()
            clock_gettime(CLOCK_MONOTONIC, &now)
            var values: [jlong] = [jlong(track.position), jlong(now.tv_sec) * 1_000_000_000 + jlong(now.tv_nsec)]
            jni.SetLongArrayRegion(env, longs, 0, 2, &values)
            return ARTAudioTrack.success
        }
        let setLoop: SetLoop = { env, this, _, _, count in ART.track(env, this)?.setLoop(count: count) ?? ARTAudioTrack.errorInvalidOperation }
        let outputRate: OutputRate = { _, _, _ in ARTAudioTrack.outputSampleRate() }
        // About 20 ms, as a device's buffer.
        let minBuffer: MinBuffer = { _, _, rate, channelConfig, encoding in
            guard rate > 0, let (_, bytes) = ARTAudioTrack.sdlFormat(encoding) else { return ARTAudioTrack.errorBadValue }
            let channels = ARTAudioTrack.channels(mask: channelConfig, indexMask: 0)
            return max(rate / 50, 256) * channels * bytes
        }
        // No effects: attaching one and its send level are accepted.
        let attachEffect: Int1 = { _, _, _ in ARTAudioTrack.success }
        typealias EffectLevel = @convention(c) (Env, jobject?, jfloat) -> jint
        let effectLevel: EffectLevel = { _, _, _ in ARTAudioTrack.success }
        let setOutputDevice: Bool1 = { _, _, _ in jboolean(JNI_TRUE) }
        let none: Void0 = { _, _ in }
        let padding: Padding = { _, _, _, _ in }
        let null: Object0 = { _, _ in nil }

        func pointer<T>(_ function: T) -> UnsafeMutableRawPointer { unsafeBitCast(function, to: UnsafeMutableRawPointer.self) }
        try register(env: env, className: "android/media/AudioTrack", natives: [
            ("native_setup", "(Ljava/lang/Object;Ljava/lang/Object;[IIIIII[IJZ)I", pointer(setup)),
            ("native_finalize", "()V", pointer(release)),
            ("native_release", "()V", pointer(release)),
            ("native_start", "()V", pointer(start)),
            ("native_stop", "()V", pointer(stop)),
            ("native_pause", "()V", pointer(pause)),
            ("native_flush", "()V", pointer(flush)),
            ("native_write_byte", "([BIIIZ)I", pointer(writeByte)),
            ("native_write_short", "([SIIIZ)I", pointer(writeShort)),
            ("native_write_float", "([FIIIZ)I", pointer(writeFloat)),
            ("native_write_native_bytes", "(Ljava/nio/ByteBuffer;IIIZ)I", pointer(writeNative)),
            ("native_reload_static", "()I", pointer(reloadStatic)),
            ("native_get_buffer_size_frames", "()I", pointer(bufferFrames)),
            ("native_set_buffer_size_frames", "(I)I", pointer(setBufferFrames)),
            ("native_get_buffer_capacity_frames", "()I", pointer(bufferFrames)),
            ("native_setVolume", "(FF)V", pointer(setVolume)),
            ("native_set_playback_rate", "(I)I", pointer(setRate)),
            ("native_get_playback_rate", "()I", pointer(getRate)),
            ("native_set_marker_pos", "(I)I", pointer(setMarker)),
            ("native_get_marker_pos", "()I", pointer(getMarker)),
            ("native_set_pos_update_period", "(I)I", pointer(setPeriod)),
            ("native_get_pos_update_period", "()I", pointer(getPeriod)),
            ("native_set_position", "(I)I", pointer(setPosition)),
            ("native_get_position", "()I", pointer(getPosition)),
            ("native_get_latency", "()I", pointer(latency)),
            ("native_get_underrun_count", "()I", pointer(zero)),
            ("native_get_flags", "()I", pointer(zero)),
            ("native_get_timestamp", "([J)I", pointer(timestamp)),
            ("native_set_loop", "(III)I", pointer(setLoop)),
            ("native_get_output_sample_rate", "(I)I", pointer(outputRate)),
            ("native_get_min_buff_size", "(III)I", pointer(minBuffer)),
            ("native_attachAuxEffect", "(I)I", pointer(attachEffect)),
            ("native_setAuxEffectSendLevel", "(F)I", pointer(effectLevel)),
            ("native_setOutputDevice", "(I)Z", pointer(setOutputDevice)),
            ("native_getRoutedDeviceId", "()I", pointer(zero)),
            ("native_enableDeviceCallback", "()V", pointer(none)),
            ("native_disableDeviceCallback", "()V", pointer(none)),
            ("native_getPortId", "()I", pointer(zero)),
            ("native_set_delay_padding", "(II)V", pointer(padding)),
            ("native_getMetrics", "()Landroid/os/PersistableBundle;", pointer(null)),
        ])
    }
}
