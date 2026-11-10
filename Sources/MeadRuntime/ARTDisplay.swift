internal import CSwiftJavaJNI
import Glibc
import MeadWindow
internal import SwiftJavaJNICore

/// Mead's display bridge for ART: SDL windows as the framework's surfaces,
/// and SDL's input as the framework's input events.
///
/// Mead's libgui (art_standalone's `frameworks/mead/gui`, interface in
/// `mead/gui.h`) stands where SurfaceFlinger is on Android. This fills it in:
/// the display it describes, the windowing connection hwui's EGL display is
/// made on, and for each window a surface whose software frames
/// (`Surface.lockCanvas`) this copies to the window, and whose native window
/// hwui's GL pipeline renders to (`Surface.lockHardwareCanvas`,
/// `HardwareRenderer`). Each window can have an input channel
/// (`frameworks/mead/android_runtime/include/mead/input.h`), whose client
/// end an `InputEventReceiver` reads, as an app's window gets from the
/// window manager; SDL's keys, mouse, touches and gamepads arrive on it as
/// `KeyEvent`s and `MotionEvent`s. Choreographer's vsync comes from libgui.
///
/// SDL is all on the bridge's own thread, which makes the windows and pumps
/// their events, so that Java's threads are free to run their loopers.
///
/// Until the window manager (phase 5) hands out surfaces, Java asks for a
/// window through `mead.view.MeadWindow`, whose natives this registers when
/// the app has that class.
final class ARTDisplay {
    /// libgui's and libandroid_runtime's functions for the bridge.
    struct Functions {
        typealias SetDisplay = @convention(c) (UnsafeRawPointer) -> Void
        typealias SetNativeDisplay = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Void
        typealias CreateSurface = @convention(c) (UInt32, UInt32, Int32, UnsafeRawPointer) -> UnsafeMutableRawPointer?
        typealias SetNativeWindow = @convention(c) (UnsafeMutableRawPointer, UInt) -> Void
        typealias ResizeSurface = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Void
        typealias SurfaceToJava = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, UnsafeMutableRawPointer) -> jobject?
        typealias OpenInput = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, UnsafePointer<CChar>, UnsafeMutablePointer<OpaquePointer?>) -> jobject?
        typealias SendKey = @convention(c) (OpaquePointer, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int64, Int64) -> Int32
        typealias SendMotion = @convention(c) (OpaquePointer, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int64, Int64,
                                               UInt32, UnsafePointer<Int32>, UnsafePointer<Int32>, UInt64, UnsafePointer<Float>) -> Int32

        let setDisplay: SetDisplay
        let setNativeDisplay: SetNativeDisplay
        let createSurface: CreateSurface
        let setNativeWindow: SetNativeWindow
        let resizeSurface: ResizeSurface
        let surfaceToJava: SurfaceToJava
        let openInput: OpenInput
        let sendKey: SendKey
        let sendMotion: SendMotion

        init(gui: UnsafeMutableRawPointer, runtime: UnsafeMutableRawPointer) throws {
            func symbol<T>(_ library: UnsafeMutableRawPointer, _ name: String) throws -> T {
                guard let found = dlsym(library, name) else { throw ART.Failure("no \(name) for Mead's display bridge") }
                return unsafeBitCast(found, to: T.self)
            }
            setDisplay = try symbol(gui, "mead_gui_set_display")
            setNativeDisplay = try symbol(gui, "mead_gui_set_native_display")
            createSurface = try symbol(gui, "mead_surface_create")
            setNativeWindow = try symbol(gui, "mead_surface_set_native_window")
            resizeSurface = try symbol(gui, "mead_surface_resize")
            surfaceToJava = try symbol(runtime, "mead_surface_to_java")
            openInput = try symbol(runtime, "mead_input_open")
            sendKey = try symbol(runtime, "mead_input_send_key")
            sendMotion = try symbol(runtime, "mead_input_send_motion")
        }
    }

    /// A window, the surface drawing to it and the input channel reading it.
    final class Window {
        let handle: SDL.Pointer
        let id: UInt32
        let native: SDLNativeWindow?
        /// The surface, an ANativeWindow from `mead_surface_create`.
        var surface: UnsafeMutableRawPointer?
        /// The surface as its Java Surface's mNativeObject has it: the
        /// android::Surface, which isn't at the ANativeWindow's address.
        var javaSurface: Int64 = 0
        /// The input channel's server end, from `mead_input_open`.
        var input: OpaquePointer?
        var pixelWidth: Int32 = 0
        var pixelHeight: Int32 = 0
        /// Pixels per SDL point, what SDL's mouse positions are in.
        var pixelsPerPoint: Float = 1

        // The display thread's input state.
        var keyDownTimes: [UInt32: Int64] = [:]
        var mouseButtons: Int32 = 0
        var mouseDownTime: Int64 = 0
        var fingers: [(sdl: UInt64, id: Int32, x: Float, y: Float, pressure: Float)] = []
        var touchDownTime: Int64 = 0

        // The latest software frame, handed from the thread queuing it to
        // the display thread.
        private var frameLock = pthread_mutex_t()
        private var frame: [UInt8] = []
        private var frameWidth: UInt32 = 0
        private var frameHeight: UInt32 = 0
        private var framePending = false
        private var frames = 0

        init(handle: SDL.Pointer) {
            self.handle = handle
            id = SDL.getWindowID(handle)
            native = SDLNativeWindow(handle)
            pthread_mutex_init(&frameLock, nil)
            measure()
        }

        func measure() {
            var width: Int32 = 0, height: Int32 = 0, points: Int32 = 0, pointHeight: Int32 = 0
            _ = SDL.getWindowSizeInPixels(handle, &width, &height)
            _ = SDL.getWindowSize(handle, &points, &pointHeight)
            pixelWidth = width
            pixelHeight = height
            pixelsPerPoint = points > 0 ? Float(width) / Float(points) : 1
        }

        /// A software frame, in Android's RGBA 8888 or RGBX 8888: kept for the
        /// display thread to copy to the window. True when the display thread
        /// should be asked to.
        func queue(_ pixels: UnsafeRawPointer, width: UInt32, height: UInt32, stride: UInt32, format: Int32) -> Bool {
            defer { frames += 1 }
            // HAL_PIXEL_FORMAT_RGBA_8888 and RGBX_8888: R, G, B, A in memory.
            guard format == 1 || format == 2 else { return false }
            if frames % 60 == 0, let path = getenv("MEAD_FRAME_DUMP") {
                Self.dump(pixels, width: width, height: height, stride: stride, to: String(cString: path))
            }
            pthread_mutex_lock(&frameLock)
            defer { pthread_mutex_unlock(&frameLock) }
            let rowBytes = Int(width) * 4
            frame = [UInt8](repeating: 0, count: rowBytes * Int(height))
            frame.withUnsafeMutableBytes { target in
                for row in 0..<Int(height) {
                    memcpy(target.baseAddress! + row * rowBytes, pixels + row * Int(stride) * 4, rowBytes)
                }
            }
            frameWidth = width
            frameHeight = height
            let ask = !framePending
            framePending = true
            return ask
        }

        /// On the display thread: the latest frame, copied to the window.
        func present() {
            pthread_mutex_lock(&frameLock)
            let pixels = frame, width = frameWidth, height = frameHeight
            framePending = false
            pthread_mutex_unlock(&frameLock)
            guard !pixels.isEmpty, let target = SDL.getWindowSurface(handle) else { return }
            let copyWidth = min(Int32(width), target.pointee.w)
            let copyHeight = min(Int32(height), target.pointee.h)
            pixels.withUnsafeBytes { source in
                _ = SDL.convertPixels(copyWidth, copyHeight, MEAD_SDL_PIXELFORMAT_ABGR8888, source.baseAddress, Int32(width) * 4,
                                      target.pointee.format, target.pointee.pixels, target.pointee.pitch)
            }
            _ = SDL.updateWindowSurface(handle)
        }

        /// MEAD_FRAME_DUMP=path: the frame as a binary PPM, every 60 frames
        /// from the first, as Mead's EGL provider and hwui write theirs.
        private static func dump(_ pixels: UnsafeRawPointer, width: UInt32, height: UInt32, stride: UInt32, to path: String) {
            guard let file = fopen(path, "wb") else { return }
            defer { fclose(file) }
            fputs("P6\n\(width) \(height)\n255\n", file)
            var row = [UInt8](repeating: 0, count: Int(width) * 3)
            for y in 0..<Int(height) {
                let source = pixels.advanced(by: y * Int(stride) * 4).assumingMemoryBound(to: UInt8.self)
                for x in 0..<Int(width) {
                    row[x * 3] = source[x * 4]
                    row[x * 3 + 1] = source[x * 4 + 1]
                    row[x * 3 + 2] = source[x * 4 + 2]
                }
                _ = row.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, file) }
            }
        }
    }

    let functions: Functions
    /// The windows, which only the display thread changes.
    var windows: [Window] = []
    private var windowsLock = pthread_mutex_t()
    private var displayDescribed = false
    var focusedWindowID: UInt32 = 0
    var gamepads: [UInt32: SDL.Pointer] = [:]
    var gamepadAxes: [UInt32: [Int32: Float]] = [:]

    // The display thread and the work handed to it.
    private var thread = pthread_t()
    private var started = false
    private var queueLock = pthread_mutex_t()
    private var queued: [() -> Void] = []
    /// SDL's event type that wakes the display thread for queued work.
    private var wakeEvent: UInt32 = 0
    private var startFailure: String?

    nonisolated(unsafe) static var shared: ARTDisplay?

    /// The bridge for the libgui and libandroid_runtime installed at `home`,
    /// which ART has loaded.
    init(home: String) throws {
        let flags = RTLD_NOW | RTLD_NOLOAD
        guard let gui = dlopen("\(home)/lib/art/libgui.so", flags) else {
            throw ART.Failure("libgui isn't loaded: \(String(cString: dlerror()))")
        }
        guard let runtime = dlopen("\(home)/lib/java/dex/art/natives/libandroid_runtime.so", flags) else {
            throw ART.Failure("libandroid_runtime isn't loaded: \(String(cString: dlerror()))")
        }
        functions = try Functions(gui: gui, runtime: runtime)
        pthread_mutex_init(&windowsLock, nil)
        pthread_mutex_init(&queueLock, nil)
    }

    // MARK: The display thread

    /// Runs `work` on the display thread, starting it first, and waits for it.
    func onDisplayThread<T>(_ work: @escaping () -> T) -> T? {
        guard startThread() else { return nil }
        let completion = Completion<T>()
        enqueue { completion.finish(work()) }
        return completion.wait()
    }

    /// Hands `work` to the display thread without waiting.
    func enqueue(_ work: @escaping () -> Void) {
        pthread_mutex_lock(&queueLock)
        queued.append(work)
        pthread_mutex_unlock(&queueLock)
        var event = mead_sdl_event()
        event.type = wakeEvent
        _ = SDL.pushEvent(&event)
    }

    private func startThread() -> Bool {
        pthread_mutex_lock(&queueLock)
        defer { pthread_mutex_unlock(&queueLock) }
        if started { return startFailure == nil }
        started = true
        let ready = Completion<String?>()
        let context = Unmanaged.passRetained(Box((self, ready))).toOpaque()
        let result = pthread_create(&thread, nil, { context in
            let box = Unmanaged<Box<(ARTDisplay, Completion<String?>)>>.fromOpaque(context!).takeRetainedValue()
            box.value.0.run(ready: box.value.1)
            return nil
        }, context)
        guard result == 0 else {
            startFailure = "no display thread: \(result)"
            Self.report(startFailure!)
            return false
        }
        pthread_mutex_unlock(&queueLock)
        startFailure = ready.wait() ?? nil
        pthread_mutex_lock(&queueLock)
        if let startFailure { Self.report(startFailure) }
        return startFailure == nil
    }

    private func run(ready: Completion<String?>) {
        guard SDL.loadOnce(),
              SDL.initialize(UInt32(MEAD_SDL_INIT_VIDEO) | UInt32(MEAD_SDL_INIT_EVENTS) | UInt32(MEAD_SDL_INIT_GAMEPAD)) else {
            ready.finish("SDL: \(SDL.lastError)")
            return
        }
        wakeEvent = SDL.registerEvents(1)
        ready.finish(nil)
        var event = mead_sdl_event()
        while true {
            if SDL.waitEventTimeout(&event, 100) {
                if event.type != wakeEvent {
                    handle(event)
                }
            }
            pthread_mutex_lock(&queueLock)
            let work = queued
            queued.removeAll()
            pthread_mutex_unlock(&queueLock)
            work.forEach { $0() }
        }
    }

    func window(id: UInt32) -> Window? {
        pthread_mutex_lock(&windowsLock)
        defer { pthread_mutex_unlock(&windowsLock) }
        return windows.first { $0.id == id }
    }

    /// The window input without one goes to: the focused one, or the only
    /// one.
    var inputWindow: Window? {
        if let focused = window(id: focusedWindowID) { return focused }
        pthread_mutex_lock(&windowsLock)
        defer { pthread_mutex_unlock(&windowsLock) }
        return windows.count == 1 ? windows[0] : nil
    }

    /// The window an android.view.Surface draws to.
    func window(env: UnsafeMutablePointer<JNIEnv?>?, surface: jobject?) -> Window? {
        guard let env, let jni = env.pointee?.pointee, let surface,
              let type = jni.GetObjectClass(env, surface),
              let field = jni.GetFieldID(env, type, "mNativeObject", "J") else { return nil }
        let native = jni.GetLongField(env, surface, field)
        jni.DeleteLocalRef(env, type)
        pthread_mutex_lock(&windowsLock)
        defer { pthread_mutex_unlock(&windowsLock) }
        return windows.first { $0.javaSurface != 0 && $0.javaSurface == native }
    }

    // MARK: Surfaces

    /// A new window titled `title`, of width×height pixels, as an
    /// `android.view.Surface`; nil, with the reason on standard error, when
    /// there's no window to be had.
    func createSurface(env: UnsafeMutablePointer<JNIEnv?>?, title: String, width: Int32, height: Int32) -> jobject? {
        let made: Window?? = onDisplayThread { [self] in
            guard let handle = SDL.createWindow(title, width, height, 0) else {
                Self.report("no window: \(SDL.lastError)")
                return nil
            }
            let window = Window(handle: handle)
            describeDisplay(for: window)
            return window
        }
        guard let made, let window = made else { return nil }

        // MeadSurfaceCallbacks: the context, then present.
        typealias Present = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt32, UInt32, UInt32, Int32) -> Void
        let present: Present = { context, pixels, width, height, stride, format in
            guard let context, let pixels, let display = ARTDisplay.shared else { return }
            let window = Unmanaged<Window>.fromOpaque(context).takeUnretainedValue()
            if window.queue(pixels, width: width, height: height, stride: stride, format: format) {
                display.enqueue { window.present() }
            }
        }
        let callbacks = UnsafeMutableRawPointer.allocate(byteCount: 2 * MemoryLayout<UnsafeRawPointer>.size,
                                                         alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { callbacks.deallocate() }
        callbacks.storeBytes(of: Unmanaged.passUnretained(window).toOpaque(), as: UnsafeMutableRawPointer.self)
        callbacks.storeBytes(of: unsafeBitCast(present, to: UnsafeRawPointer.self),
                             toByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafeRawPointer.self)
        // HAL_PIXEL_FORMAT_RGBA_8888.
        guard let surface = functions.createSurface(UInt32(window.pixelWidth), UInt32(window.pixelHeight), 1, callbacks) else {
            Self.report("no surface for the window")
            enqueue { SDL.destroyWindow(window.handle) }
            return nil
        }
        window.surface = surface
        if let native = window.native {
            functions.setNativeWindow(surface, native.eglWindow)
        }
        // The Java Surface holds its own reference; the window keeps the one
        // mead_surface_create gave.
        guard let javaSurface = functions.surfaceToJava(env, surface) else { return nil }
        if let jni = env?.pointee?.pointee, let type = jni.GetObjectClass(env, javaSurface),
           let field = jni.GetFieldID(env, type, "mNativeObject", "J") {
            window.javaSurface = jni.GetLongField(env, javaSurface, field)
            jni.DeleteLocalRef(env, type)
        }
        pthread_mutex_lock(&windowsLock)
        windows.append(window)
        pthread_mutex_unlock(&windowsLock)
        return javaSurface
    }

    /// An input channel for the window `surface` draws to: its client end, an
    /// android.view.InputChannel, which an InputEventReceiver reads.
    func openInput(env: UnsafeMutablePointer<JNIEnv?>?, surface: jobject?) -> jobject? {
        guard let window = window(env: env, surface: surface) else {
            Self.report("openInput: that Surface isn't a window's")
            return nil
        }
        var input: OpaquePointer?
        let client = "mead window \(window.id)".withCString { functions.openInput(env, $0, &input) }
        guard let client, let input else { return nil }
        _ = onDisplayThread { window.input = input }
        return client
    }

    /// The display and windowing connection libgui reports, from the first
    /// window's. On the display thread.
    private func describeDisplay(for window: Window) {
        guard !displayDescribed else { return }
        displayDescribed = true
        if let native = window.native {
            functions.setNativeDisplay(native.kind.rawValue, native.display)
        }
        let display = SDL.getPrimaryDisplay()
        guard display != 0, let mode = SDL.getCurrentDisplayMode(display) else { return }
        let scale = max(SDL.getDisplayContentScale(display), 1)
        // MeadDisplay: width and height in pixels, xdpi, ydpi, refresh rate,
        // and density (1 at 160 dpi).
        var described = [UInt32](repeating: 0, count: 6)
        described[0] = UInt32(mode.pointee.w)
        described[1] = UInt32(mode.pointee.h)
        described[2] = (160 * scale).bitPattern
        described[3] = (160 * scale).bitPattern
        described[4] = (mode.pointee.refresh_rate > 0 ? mode.pointee.refresh_rate : 60).bitPattern
        described[5] = scale.bitPattern
        described.withUnsafeBytes { functions.setDisplay($0.baseAddress!) }
    }

    /// A window's new size, from SDL. On the display thread.
    func resized(_ window: Window) {
        window.measure()
        window.native?.resize(width: window.pixelWidth, height: window.pixelHeight)
        if let surface = window.surface {
            functions.resizeSurface(surface, UInt32(window.pixelWidth), UInt32(window.pixelHeight))
        }
    }

    static func report(_ message: String) {
        var line = "mead: display: \(message)\n"
        line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
    }
}

/// A value one thread hands another, which waits for it.
final class Completion<T> {
    private var lock = pthread_mutex_t()
    private var condition = pthread_cond_t()
    private var value: T?
    private var done = false

    init() {
        pthread_mutex_init(&lock, nil)
        pthread_cond_init(&condition, nil)
    }

    func finish(_ result: T) {
        pthread_mutex_lock(&lock)
        value = result
        done = true
        pthread_cond_broadcast(&condition)
        pthread_mutex_unlock(&lock)
    }

    func wait() -> T? {
        pthread_mutex_lock(&lock)
        while !done {
            pthread_cond_wait(&condition, &lock)
        }
        let result = value
        pthread_mutex_unlock(&lock)
        return result
    }
}

final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}
