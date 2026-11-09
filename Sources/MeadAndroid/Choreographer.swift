import Glibc

// AChoreographer: frame callbacks, as Android runs them at each vsync on the
// thread that asked. Here whatever runs the game's frames delivers them,
// once per frame, through `Choreographer.runFrame`.

public final class Choreographer {
    typealias FrameCallback = @convention(c) (Int, UnsafeMutableRawPointer?) -> Void
    typealias FrameCallback64 = @convention(c) (Int64, UnsafeMutableRawPointer?) -> Void

    private struct Pending {
        let callback: UnsafeRawPointer
        let data: UnsafeMutableRawPointer?
        let wide: Bool
        let due: Int64
    }

    static let shared = Choreographer()
    var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private var pending: [Pending] = []
    private var mutex = pthread_mutex_t()

    private init() {
        pthread_mutex_init(&mutex, nil)
    }

    static func now() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    func post(_ callback: UnsafeRawPointer?, _ data: UnsafeMutableRawPointer?, wide: Bool, delayNanos: Int64) {
        guard let callback else { return }
        pthread_mutex_lock(&mutex)
        pending.append(Pending(callback: callback, data: data, wide: wide, due: Self.now() + delayNanos))
        pthread_mutex_unlock(&mutex)
    }

    /// Runs the callbacks that are due, with this frame's time. Ones posted
    /// while they run wait for the next frame, as on Android.
    public static func runFrame() {
        let choreographer = shared
        let now = Self.now()
        pthread_mutex_lock(&choreographer.mutex)
        let due = choreographer.pending.filter { $0.due <= now }
        choreographer.pending.removeAll { $0.due <= now }
        pthread_mutex_unlock(&choreographer.mutex)
        for item in due {
            if item.wide {
                unsafeBitCast(item.callback, to: FrameCallback64.self)(now, item.data)
            } else {
                unsafeBitCast(item.callback, to: FrameCallback.self)(Int(now), item.data)
            }
        }
    }
}

@_cdecl("AChoreographer_getInstance")
public func AChoreographer_getInstance() -> UnsafeMutableRawPointer { Choreographer.shared.pointer }

@_cdecl("AChoreographer_postFrameCallback")
public func AChoreographer_postFrameCallback(_ choreographer: UnsafeMutableRawPointer?, _ callback: UnsafeRawPointer?,
                                             _ data: UnsafeMutableRawPointer?) {
    Choreographer.shared.post(callback, data, wide: false, delayNanos: 0)
}

@_cdecl("AChoreographer_postFrameCallbackDelayed")
public func AChoreographer_postFrameCallbackDelayed(_ choreographer: UnsafeMutableRawPointer?, _ callback: UnsafeRawPointer?,
                                                    _ data: UnsafeMutableRawPointer?, _ delayMillis: Int) {
    Choreographer.shared.post(callback, data, wide: false, delayNanos: Int64(delayMillis) * 1_000_000)
}

@_cdecl("AChoreographer_postFrameCallback64")
public func AChoreographer_postFrameCallback64(_ choreographer: UnsafeMutableRawPointer?, _ callback: UnsafeRawPointer?,
                                               _ data: UnsafeMutableRawPointer?) {
    Choreographer.shared.post(callback, data, wide: true, delayNanos: 0)
}

@_cdecl("AChoreographer_postFrameCallbackDelayed64")
public func AChoreographer_postFrameCallbackDelayed64(_ choreographer: UnsafeMutableRawPointer?, _ callback: UnsafeRawPointer?,
                                                      _ data: UnsafeMutableRawPointer?, _ delayMillis: UInt32) {
    Choreographer.shared.post(callback, data, wide: true, delayNanos: Int64(delayMillis) * 1_000_000)
}
