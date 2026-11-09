import CMeadAndroid
import Glibc
import MeadInterface
import MeadJNI
import MeadJava
import MeadWindow

/// Runs a game built on the Android Game SDK's GameActivity, playing the part
/// of its Java class: registers the natives, creates the activity, and walks
/// it through its lifecycle while the main thread's looper turns.
final class GameActivityRunner {
    private typealias Initialize = @convention(c) (UnsafeMutableRawPointer, OpaquePointer?, OpaquePointer?, OpaquePointer?,
                                                   OpaquePointer?, OpaquePointer?, OpaquePointer?, OpaquePointer?) -> Int64
    private typealias Register = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private static let gameActivity = "com/google/androidgamesdk/GameActivity"

    private func writeError(_ text: String) {
        var line = "mead: \(text)\n"
        line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
    }

    private func size(_ name: String, default fallback: Int32) -> Int32 {
        getenv(name).flatMap { Int32(String(cString: $0)) } ?? fallback
    }

    func run(initialize: UnsafeMutableRawPointer, register: UnsafeMutableRawPointer?, title: String) -> Int32 {
        guard SDL.loadOnce(), SDL.initialize(UInt32(MEAD_SDL_INIT_VIDEO) | UInt32(MEAD_SDL_INIT_EVENTS)) else {
            writeError("SDL could not start: \(SDL.lastError)")
            return 1
        }
        defer { SDL.quit() }
        _ = SDL.initialize(UInt32(MEAD_SDL_INIT_GAMEPAD))

        let width = size("MEAD_WINDOW_WIDTH", default: 1280)
        let height = size("MEAD_WINDOW_HEIGHT", default: 720)
        var flags = MEAD_SDL_WINDOW_RESIZABLE
        if Int(mead_graphics_api()) == MEAD_GRAPHICS_VULKAN {
            flags |= MEAD_SDL_WINDOW_VULKAN
        }
        guard let sdlWindow = SDL.createWindow(title, width, height, flags) else {
            writeError("SDL_CreateWindow: \(SDL.lastError)")
            return 1
        }
        defer { SDL.destroyWindow(sdlWindow) }
        let window = NativeWindow(handle: sdlWindow, width: width, height: height)
        NativeWindow.current = window

        // GameActivity hands work to the main thread through its looper.
        let looper = Looper.prepare()
        let thread = JavaRuntime.shared.attachCurrentThread()
        let env = UnsafeMutableRawPointer(thread.env)

        // What the app's Java does before it gets to its activity. libpairipcore
        // is loaded already, as the game's first dependency, and on this
        // version nothing needs its JNI_OnLoad.
        for library in ["fmod", "minecraftpe"] {
            do {
                try JavaSystem.loadNamed(library)
            } catch {
                JavaRuntime.shared.trace("loadLibrary(\(library)): \(error)")
            }
        }

        if let register {
            _ = unsafeBitCast(register, to: Register.self)(env)
        }

        let activity = JavaMinecraftActivity()
        let assets = activity.getAssets()
        JavaMinecraftActivity.screenWidth = window.width
        JavaMinecraftActivity.screenHeight = window.height
        let configuration = thread.newLocal(JavaConfiguration())

        let dataPath = AndroidEnvironment.filesDirectory
        let handle = unsafeBitCast(initialize, to: Initialize.self)(
            env, thread.newLocal(activity), thread.newLocal(JavaString(dataPath)), thread.newLocal(JavaString(dataPath)),
            thread.newLocal(JavaString(dataPath)), thread.newLocal(assets), jni_new_array(env, CChar(UInt8(ascii: "B")), 0),
            configuration)
        guard handle != 0 else {
            writeError("GameActivity's initializeNativeCode returned nothing")
            return 1
        }

        var pointer = jvalue()
        pointer.j = handle
        func lifecycle(_ name: String, _ signature: String = "(J)V", _ more: [jvalue] = []) {
            JavaRuntime.shared.trace("GameActivity.\(name)")
            thread.call(Self.gameActivity, name, signature, on: activity, [pointer] + more)
        }

        lifecycle("onStartNative")
        lifecycle("onResumeNative")

        ANativeWindow_acquire(window.pointer)
        let surface = JavaSurface(nativeWindow: window.pointer)
        var surfaceValue = jvalue()
        surfaceValue.l = thread.newLocal(surface)
        lifecycle("onSurfaceCreatedNative", "(JLandroid/view/Surface;)V", [surfaceValue])
        var format = jvalue(), widthValue = jvalue(), heightValue = jvalue()
        format.i = 1 // RGBA_8888
        widthValue.i = window.width
        heightValue.i = window.height
        lifecycle("onSurfaceChangedNative", "(JLandroid/view/Surface;III)V", [surfaceValue, format, widthValue, heightValue])
        var focused = jvalue()
        focused.z = 1
        lifecycle("onWindowFocusChangedNative", "(JZ)V", [focused])

        var event = mead_sdl_event()
        var running = true
        while running {
            while looper.pollOnce(timeout: 0, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_CALLBACK {}
            for callback in activity.takeUiCallbacks() {
                var value = jvalue()
                value.j = callback
                thread.call("com/mojang/minecraftpe/MainActivity", "nativeRunNativeCallbackOnUiThread", "(J)V", on: activity, [value])
            }
            guard SDL.waitEventTimeout(&event, 10) else { continue }
            switch Int(event.type) {
            case MEAD_SDL_EVENT_QUIT, MEAD_SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                running = false
            case MEAD_SDL_EVENT_WINDOW_RESIZED:
                window.windowWasResized()
                widthValue.i = window.width
                heightValue.i = window.height
                lifecycle("onSurfaceChangedNative", "(JLandroid/view/Surface;III)V", [surfaceValue, format, widthValue, heightValue])
            default:
                break
            }
        }

        lifecycle("onPauseNative")
        lifecycle("onStopNative")
        lifecycle("onSurfaceDestroyedNative")
        return 0
    }
}

@_cdecl("mead_android_run_game_activity")
public func meadAndroidRunGameActivity(_ initialize: UnsafeMutableRawPointer, _ register: UnsafeMutableRawPointer?, _ library: UnsafePointer<CChar>) -> Int32 {
    setenv("MEAD_PACKAGE", "com.mojang", 0)
    return GameActivityRunner().run(initialize: initialize, register: register, title: "Minecraft")
}
