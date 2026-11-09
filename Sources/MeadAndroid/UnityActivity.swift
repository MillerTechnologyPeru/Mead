import CMeadAndroid
import Glibc
import MeadGooglePlay
import MeadInterface
import MeadJNI
import MeadJava
import MeadUnity
import MeadWindow

/// Runs a Unity game the way its UnityPlayerActivity would, playing the part
/// of Unity's own Java (Unity 6's com.unity3d.player):
///
/// 1. System.load(libmain.so), whose JNI_OnLoad registers NativeLoader;
///    NativeLoader.load(<library directory>) then loads libunity.so, whose
///    JNI_OnLoad registers the player's natives.
/// 2. initJni(activity, 0, ""): 0 is the "activity or service" kind.
/// 3. On Unity's main thread: nativeRecreateGfxState(0, surface),
///    nativeSendSurfaceChangedEvent(), nativeResume(), nativeFocusChanged(true).
/// 4. Each frame: the main thread's jobs, then nativeRender() until it says
///    to stop.
///
/// Here the process's main thread is Unity's main thread and its UI thread
/// both, and it pumps SDL's events between frames.
final class UnityRunner {
    private static let player = "com/unity3d/player/UnityPlayer"
    private static let playerForActivity = "com/unity3d/player/UnityPlayerForActivityOrService"

    private func writeError(_ text: String) {
        var line = "mead: \(text)\n"
        line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
    }

    private func size(_ name: String, default fallback: Int32) -> Int32 {
        getenv(name).flatMap { Int32(String(cString: $0)) } ?? fallback
    }

    func run(libraryDirectory: String, title: String) -> Int32 {
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
        DisplaySize.current.withLock { $0 = (window.pixelWidth, window.pixelHeight) }
        NativeWindow.current = window

        let looper = Looper.prepare()
        JavaLooper.setCurrent(JavaLooper.main)
        let thread = JavaRuntime.shared.attachCurrentThread()

        // 1. Unity's libraries, as UnityPlayer.loadNative loads them.
        do {
            try JavaSystem.load("\(libraryDirectory)/libmain.so")
        } catch {
            writeError("System.load(libmain.so): \(error)")
            return 1
        }
        var directory = jvalue()
        directory.l = thread.newLocal(JavaString(libraryDirectory))
        let loaded = thread.call("com/unity3d/player/NativeLoader", "load", "(Ljava/lang/String;)Z", isStatic: true,
                                 on: nil, [directory])
        guard loaded.z != 0 else {
            writeError("NativeLoader.load failed: Unity's libraries were not loaded")
            return 1
        }

        // 2. The player, and Unity's start.
        let activity = JavaUnityPlayerActivity()
        let player = JavaUnityPlayerForActivityOrService(activity: activity)
        var finished = false
        activity.onFinish = { finished = true }

        var context = jvalue()
        context.l = thread.newLocal(activity)
        var kind = jvalue()
        kind.i = 0
        var commandLine = jvalue()
        commandLine.l = thread.newLocal(JavaString(""))
        JavaRuntime.shared.trace("UnityPlayer.initJni")
        thread.call(Self.player, "initJni", "(Landroid/content/Context;ILjava/lang/String;)V", on: player,
                    [context, kind, commandLine])

        func native(_ name: String, _ signature: String = "()V", _ arguments: [jvalue] = []) -> jvalue {
            JavaRuntime.shared.trace("UnityPlayer.\(name)")
            return thread.call(Self.playerForActivity, name, signature, on: player, arguments)
        }

        // 3. Its window, then running and in focus.
        let surface = JavaSurface(nativeWindow: window.pointer)
        var display = jvalue()
        display.i = 0
        var surfaceValue = jvalue()
        surfaceValue.l = thread.newLocal(surface)
        _ = native("nativeRecreateGfxState", "(ILandroid/view/Surface;)V", [display, surfaceValue])
        _ = native("nativeSendSurfaceChangedEvent")
        _ = native("nativeResume")
        var focused = jvalue()
        focused.z = 1
        _ = native("nativeFocusChanged", "(Z)V", [focused])

        // Input, as Unity's Java passes it from its view: each event in a
        // frame of references of its own, for display 0.
        func inject(_ event: JavaObject) {
            thread.pushFrame()
            defer { thread.popFrame() }
            var value = jvalue()
            value.l = thread.newLocal(event)
            var display = jvalue()
            display.i = 0
            thread.call(Self.player, "nativeInjectEvent", "(Landroid/view/InputEvent;I)Z", on: player, [value, display])
        }
        let input = GameActivityInput(sendMotion: inject, sendKey: inject)
        input.mouseIsFinger = true

        // What Unity's SurfaceHolder callback does when the surface's size
        // changes: the graphics state is made again for it, which is when
        // Unity reads the new size. SDL reports one resize as two events,
        // and the window can be resized just after it opens: the compositor
        // fits it to the screen.
        var surfaceSize = (width: window.pixelWidth, height: window.pixelHeight)
        func surfaceChanged() {
            let size = (width: window.pixelWidth, height: window.pixelHeight)
            guard size != surfaceSize else { return }
            surfaceSize = size
            window.windowWasResized()
            DisplaySize.current.withLock { $0 = (size.width, size.height) }
            window.bufferWidth = 0
            window.bufferHeight = 0
            _ = native("nativeRecreateGfxState", "(ILandroid/view/Surface;)V", [display, surfaceValue])
            _ = native("nativeSendSurfaceChangedEvent")
        }

        // 4. Frames, until Unity or the window says to stop.
        var event = mead_sdl_event()
        var running = true
        while running && !finished {
            while SDL.waitEventTimeout(&event, 0) {
                switch Int(event.type) {
                case MEAD_SDL_EVENT_QUIT, MEAD_SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                    running = false
                case MEAD_SDL_EVENT_WINDOW_RESIZED, MEAD_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                    surfaceChanged()
                default:
                    input.handle(event, windowWidth: Float(window.pixelWidth), windowHeight: Float(window.pixelHeight),
                                 pixelsPerPoint: window.pixelsPerPoint)
                }
            }
            while looper.pollOnce(timeout: 0, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_CALLBACK {}
            Choreographer.runFrame()
            JavaLooper.main.runDue()
            thread.pushFrame()
            player.executeMainThreadJobs()
            let more = native("nativeRender", "()Z")
            thread.popFrame()
            if more.z == 0 {
                JavaRuntime.shared.trace("UnityPlayer.nativeRender says to stop")
                break
            }
        }

        _ = native("nativePause", "()Z")
        _ = native("nativeDone", "()Z")
        return 0
    }
}

@_cdecl("mead_android_run_unity")
public func meadAndroidRunUnity(_ libraryDirectory: UnsafePointer<CChar>) -> Int32 {
    let directory = String(cString: libraryDirectory)
    // The package, from the game's manifest beside its libraries.
    if getenv("MEAD_PACKAGE") == nil, let data = getenv("MEAD_DATA_DIR").map({ String(cString: $0) }),
       let manifest = AndroidManifest(path: "\(data)/AndroidManifest.xml") {
        setenv("MEAD_PACKAGE", manifest.packageName, 0)
    }
    let title = getenv("MEAD_PACKAGE").map { String(cString: $0) } ?? "Unity"
    return UnityRunner().run(libraryDirectory: directory, title: title)
}
