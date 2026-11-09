import CMeadAndroid
import Glibc
import MeadInterface
import MeadJNI
import MeadJava
import MeadWindow

@_cdecl("mead_provider_startup")
public func meadAndroidProviderStartup(_ info: UnsafePointer<mead_startup_info>) {
    AndroidEnvironment.loader = info
    let lookup = info.pointee.lookup_symbol
    JavaRuntime.shared.nativeLookup = { name in name.withCString { lookup?(nil, $0) } }
    JavaRuntime.shared.attachCurrentThread()
    JavaFramework.register()

    let directory: String
    if let data = info.pointee.data_dir {
        directory = String(cString: data)
    } else if let program = info.pointee.progname {
        let path = String(cString: program)
        directory = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "."
    } else {
        directory = "."
    }
    AssetManager.shared.root = "\(directory)/assets"
}

/// Runs one ANativeActivity, playing the part of Android: the window, the
/// lifecycle calls, and turning SDL's events into input events.
final class ActivityRunner {
    private let lock = Mutex()
    private var finishRequested = false
    private let queue = InputQueue()
    private var pointerDown = false
    private var pointerDownTime: Int64 = 0

    func requestFinish() {
        lock.withLock { finishRequested = true }
    }

    private var finishing: Bool {
        lock.withLock { finishRequested }
    }

    private func environmentSize(_ name: String, default fallback: Int32) -> Int32 {
        getenv(name).flatMap { Int32(String(cString: $0)) } ?? fallback
    }

    func run(onCreate: mead_activity_on_create, title: String) -> Int32 {
        guard SDL.loadOnce() else {
            writeError("SDL3 (libSDL3.so.0) could not be loaded")
            return 1
        }
        guard SDL.initialize(UInt32(MEAD_SDL_INIT_VIDEO) | UInt32(MEAD_SDL_INIT_EVENTS)) else {
            writeError("SDL_Init: \(SDL.lastError)")
            return 1
        }
        defer { SDL.quit() }

        let width = environmentSize("MEAD_WINDOW_WIDTH", default: 1280)
        let height = environmentSize("MEAD_WINDOW_HEIGHT", default: 720)
        guard let sdlWindow = SDL.createWindow(title, width, height, MEAD_SDL_WINDOW_RESIZABLE) else {
            writeError("SDL_CreateWindow: \(SDL.lastError)")
            return 1
        }
        defer { SDL.destroyWindow(sdlWindow) }
        let window = NativeWindow(handle: sdlWindow, width: width, height: height)
        NativeWindow.current = window

        let thread = JavaRuntime.shared.attachCurrentThread()
        let javaActivity = JavaNativeActivity()
        javaActivity.onFinish = { [unowned self] in requestFinish() }

        let callbacks = UnsafeMutablePointer<ANativeActivityCallbacks>.allocate(capacity: 1)
        callbacks.initialize(to: ANativeActivityCallbacks())
        let local = thread.newLocal(javaActivity)
        var activity = ANativeActivity()
        activity.callbacks = callbacks
        activity.vm = UnsafeMutablePointer(JavaRuntime.shared.vm)
        activity.env = thread.env
        activity.clazz = jni_NewGlobalRef(UnsafeMutableRawPointer(thread.env), local)
        activity.internalDataPath = UnsafePointer(strdup(AndroidEnvironment.filesDirectory))
        activity.externalDataPath = UnsafePointer(strdup(AndroidEnvironment.filesDirectory))
        activity.sdkVersion = JavaBuildVersion.sdkInt
        activity.assetManager = AssetManager.shared.pointer
        activity.obbPath = UnsafePointer(strdup(AndroidEnvironment.dataDirectory))

        let pointer = UnsafeMutablePointer<ANativeActivity>.allocate(capacity: 1)
        pointer.initialize(to: activity)
        ActivityRunner.current = (self, pointer)

        onCreate(pointer, nil, 0)
        let table = callbacks.pointee
        table.onStart?(pointer)
        table.onResume?(pointer)
        table.onNativeWindowCreated?(pointer, window.pointer)
        table.onInputQueueCreated?(pointer, Unmanaged.passUnretained(queue).toOpaque())
        table.onWindowFocusChanged?(pointer, 1)

        var event = mead_sdl_event()
        var running = true
        while running, !finishing {
            guard SDL.waitEventTimeout(&event, 10) else { continue }
            repeat {
                running = handle(&event, window: window, activity: pointer) && running
            } while SDL.waitEventTimeout(&event, 0)
        }

        table.onWindowFocusChanged?(pointer, 0)
        table.onPause?(pointer)
        table.onStop?(pointer)
        table.onInputQueueDestroyed?(pointer, Unmanaged.passUnretained(queue).toOpaque())
        table.onNativeWindowDestroyed?(pointer, window.pointer)
        table.onDestroy?(pointer)
        return 0
    }

    nonisolated(unsafe) static var current: (runner: ActivityRunner, activity: UnsafeMutablePointer<ANativeActivity>)?

    private func writeError(_ text: String) {
        var line = "mead: \(text)\n"
        line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
    }

    /// False when the event means the app should stop.
    private func handle(_ event: UnsafeMutablePointer<mead_sdl_event>, window: NativeWindow, activity: UnsafeMutablePointer<ANativeActivity>) -> Bool {
        let type = Int(event.pointee.type)
        let time = Int64(event.pointee.common.timestamp)
        switch type {
        case MEAD_SDL_EVENT_QUIT, MEAD_SDL_EVENT_WINDOW_CLOSE_REQUESTED:
            return false
        case MEAD_SDL_EVENT_WINDOW_RESIZED:
            window.windowWasResized()
            activity.pointee.callbacks.pointee.onNativeWindowResized?(activity, window.pointer)
        case MEAD_SDL_EVENT_WINDOW_FOCUS_GAINED:
            activity.pointee.callbacks.pointee.onWindowFocusChanged?(activity, 1)
        case MEAD_SDL_EVENT_WINDOW_FOCUS_LOST:
            activity.pointee.callbacks.pointee.onWindowFocusChanged?(activity, 0)
        case MEAD_SDL_EVENT_KEY_DOWN, MEAD_SDL_EVENT_KEY_UP:
            let key = event.pointee.key
            let code = androidKeyCode(forScancode: key.scancode)
            guard code != 0 else { break }
            queue.enqueue(InputEvent(type: AINPUT_EVENT_TYPE_KEY, source: AINPUT_SOURCE_KEYBOARD,
                                     action: key.down ? AKEY_EVENT_ACTION_DOWN : AKEY_EVENT_ACTION_UP,
                                     eventTime: time, downTime: time, keyCode: code, scanCode: Int32(key.scancode),
                                     repeatCount: key.`repeat` ? 1 : 0))
        case MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN, MEAD_SDL_EVENT_MOUSE_BUTTON_UP:
            let button = event.pointee.button
            guard Int(button.button) == MEAD_SDL_BUTTON_LEFT else { break }
            motion(action: button.down ? AMOTION_EVENT_ACTION_DOWN : AMOTION_EVENT_ACTION_UP, x: button.x, y: button.y, time: time)
        case MEAD_SDL_EVENT_MOUSE_MOTION:
            if pointerDown {
                motion(action: AMOTION_EVENT_ACTION_MOVE, x: event.pointee.motion.x, y: event.pointee.motion.y, time: time)
            }
        case MEAD_SDL_EVENT_FINGER_DOWN, MEAD_SDL_EVENT_FINGER_UP, MEAD_SDL_EVENT_FINGER_MOTION:
            // Fingers come in the window's 0-to-1 range.
            let finger = event.pointee.finger
            let action: Int32 = type == MEAD_SDL_EVENT_FINGER_DOWN ? AMOTION_EVENT_ACTION_DOWN
                : type == MEAD_SDL_EVENT_FINGER_UP ? AMOTION_EVENT_ACTION_UP : AMOTION_EVENT_ACTION_MOVE
            motion(action: action, x: finger.x * Float(window.width), y: finger.y * Float(window.height), time: time)
        default:
            break
        }
        return true
    }

    private func motion(action: Int32, x: Float, y: Float, time: Int64) {
        if action == AMOTION_EVENT_ACTION_DOWN {
            pointerDown = true
            pointerDownTime = time
        } else if action == AMOTION_EVENT_ACTION_UP {
            pointerDown = false
        }
        queue.enqueue(InputEvent(type: AINPUT_EVENT_TYPE_MOTION, source: AINPUT_SOURCE_TOUCHSCREEN,
                                 action: action, eventTime: time, downTime: pointerDownTime, x: x, y: y))
    }
}

@_cdecl("mead_android_run_activity")
public func meadAndroidRunActivity(_ onCreate: UnsafeMutableRawPointer, _ library: UnsafePointer<CChar>) -> Int32 {
    let create = unsafeBitCast(onCreate, to: mead_activity_on_create.self)
    return ActivityRunner().run(onCreate: create, title: String(cString: library))
}

@_cdecl("ANativeActivity_finish")
public func ANativeActivity_finish(_ activity: UnsafeMutableRawPointer) {
    ActivityRunner.current?.runner.requestFinish()
}

@_cdecl("ANativeActivity_setWindowFormat")
public func ANativeActivity_setWindowFormat(_ activity: UnsafeMutableRawPointer, _ format: Int32) {}

@_cdecl("ANativeActivity_setWindowFlags")
public func ANativeActivity_setWindowFlags(_ activity: UnsafeMutableRawPointer, _ add: UInt32, _ remove: UInt32) {}

@_cdecl("ANativeActivity_showSoftInput")
public func ANativeActivity_showSoftInput(_ activity: UnsafeMutableRawPointer, _ flags: UInt32) {}

@_cdecl("ANativeActivity_hideSoftInput")
public func ANativeActivity_hideSoftInput(_ activity: UnsafeMutableRawPointer, _ flags: UInt32) {}

// Input for tests: real SDL events, so that the whole path is exercised.

@_cdecl("mead_android_inject_key")
public func meadAndroidInjectKey(_ scancode: UInt32, _ down: Bool) {
    var event = mead_sdl_event()
    event.key.type = UInt32(down ? MEAD_SDL_EVENT_KEY_DOWN : MEAD_SDL_EVENT_KEY_UP)
    event.key.scancode = scancode
    event.key.down = down
    _ = SDL.pushEvent(&event)
}

@_cdecl("mead_android_inject_touch")
public func meadAndroidInjectTouch(_ x: Float, _ y: Float, _ down: Bool) {
    var event = mead_sdl_event()
    event.button.type = UInt32(down ? MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN : MEAD_SDL_EVENT_MOUSE_BUTTON_UP)
    event.button.button = UInt8(MEAD_SDL_BUTTON_LEFT)
    event.button.down = down
    event.button.x = x
    event.button.y = y
    _ = SDL.pushEvent(&event)
}
