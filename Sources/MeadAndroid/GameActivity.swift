import CMeadAndroid
import Glibc
import MeadInterface
import MeadJNI
import MeadJava
import MeadMinecraft
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
        var flags = MEAD_SDL_WINDOW_RESIZABLE | NativeWindow.fullscreenFlag
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
        JavaMinecraftActivity.screenWidth = window.pixelWidth
        JavaMinecraftActivity.screenHeight = window.pixelHeight
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

        // Its text input goes through an object GameActivity keeps.
        let textInput = JavaTextInputConnection()
        var connection = jvalue()
        connection.l = thread.newLocal(textInput)
        lifecycle("setInputConnectionNative", "(JLcom/google/androidgamesdk/gametextinput/InputConnection;)V", [connection])

        lifecycle("onStartNative")
        lifecycle("onResumeNative")

        ANativeWindow_acquire(window.pointer)
        let surface = JavaSurface(nativeWindow: window.pointer)
        var surfaceValue = jvalue()
        surfaceValue.l = thread.newLocal(surface)
        lifecycle("onSurfaceCreatedNative", "(JLandroid/view/Surface;)V", [surfaceValue])
        var format = jvalue(), widthValue = jvalue(), heightValue = jvalue()
        format.i = 1 // RGBA_8888
        // The window's size, not any buffer size set since: on Android the
        // compositor scales those buffers to the window, and here the window
        // is what the game has to fill.
        widthValue.i = window.pixelWidth
        heightValue.i = window.pixelHeight
        lifecycle("onSurfaceChangedNative", "(JLandroid/view/Surface;III)V", [surfaceValue, format, widthValue, heightValue])
        var focused = jvalue()
        focused.z = 1
        lifecycle("onWindowFocusChangedNative", "(JZ)V", [focused])

        // The network is up, as far as the game is to know.
        var up = jvalue()
        up.z = 1
        thread.call("com/mojang/minecraftpe/NetworkMonitor", "nativeUpdateNetworkStatus", "(ZZZ)V", on: JavaNetworkMonitor(), [up, up, up])

        // Input, as GameActivity's Java hands it over.
        // Each event's references are local to a frame of their own, as they
        // are to a Java call: the main thread's would otherwise only grow.
        let input = GameActivityInput(sendMotion: { motion in
            thread.pushFrame()
            defer { thread.popFrame() }
            var event = jvalue(), pointerCount = jvalue(), historySize = jvalue(), deviceId = jvalue(), source = jvalue()
            var action = jvalue(), eventTime = jvalue(), downTime = jvalue(), flags = jvalue(), metaState = jvalue()
            var actionButton = jvalue(), buttonState = jvalue(), classification = jvalue(), edgeFlags = jvalue()
            var precisionX = jvalue(), precisionY = jvalue()
            event.l = thread.newLocal(motion)
            pointerCount.i = motion.getPointerCount()
            historySize.i = motion.getHistorySize()
            deviceId.i = motion.deviceId
            source.i = motion.source
            action.i = motion.action
            eventTime.j = motion.eventTime
            downTime.j = motion.downTime
            metaState.i = motion.metaState
            buttonState.i = motion.buttonState
            actionButton.i = motion.actionButton
            precisionX.f = 1
            precisionY.f = 1
            let handled = thread.call(Self.gameActivity, "onTouchEventNative", "(JLandroid/view/MotionEvent;IIIIIJJIIIIIIFF)Z", on: activity,
                                      [pointer, event, pointerCount, historySize, deviceId, source, action, eventTime, downTime, flags,
                                       metaState, actionButton, buttonState, classification, edgeFlags, precisionX, precisionY])
            JavaRuntime.shared.trace("onTouchEventNative action \(motion.action) source \(motion.source) -> \(handled.z != 0)")
        }, sendKey: { key in
            thread.pushFrame()
            defer { thread.popFrame() }
            var event = jvalue()
            event.l = thread.newLocal(key)
            let name = key.action == JavaKeyEvent.actionDown ? "onKeyDownNative" : "onKeyUpNative"
            _ = thread.call(Self.gameActivity, name, "(JLandroid/view/KeyEvent;)Z", on: activity, [pointer, event])
        }, editText: { edit in
            thread.pushFrame()
            defer { thread.popFrame() }
            let box = JavaMinecraftActivity.textBox
            if box.isActive {
                // Minecraft's own text box: the whole text, then the caret.
                let mainActivity = "com/mojang/minecraftpe/MainActivity"
                if edit == .submit, !box.isMultiline {
                    _ = thread.call(mainActivity, "nativeReturnKeyPressed", "()V", on: activity, [])
                    return
                }
                let after = box.apply(edit == .submit ? .insert("\n") : edit)
                var text = jvalue()
                text.l = thread.newLocal(JavaString(after.text))
                _ = thread.call(mainActivity, "nativeSetTextboxText", "(Ljava/lang/String;)V", on: activity, [text])
                var caret = jvalue()
                caret.i = Int32(after.start)
                _ = thread.call(mainActivity, "nativeCaretPosition", "(I)V", on: activity, [caret])
                return
            }
            var state = jvalue()
            state.l = thread.newLocal(textInput.apply(edit))
            thread.call(Self.gameActivity, "onTextInputEventNative", "(JLcom/google/androidgamesdk/gametextinput/State;)V",
                        on: activity, [pointer, state])
        })

        // MEAD_DEBUG_TAPS="seconds:x,y;...": clicks at those times after the main
        // loop starts, for trying a game's screens on a machine nobody is at.
        // Each tap moves the pointer there first and is held down for 150 ms,
        // as a click is: a UI takes the press on what the pointer is over.
        // "seconds:key=scancode" presses a key for 150 ms instead,
        // "seconds:wheel=notches" turns the mouse wheel, and
        // "seconds:look=dx,dy" moves the mouse by that much, and
        // "seconds:text=words" types them, as SDL's text input delivers typing.
        var debugTexts: [String] = []
        var taps: [(at: Double, x: Float, y: Float, kind: Int)] = (getenv("MEAD_DEBUG_TAPS").map { String(cString: $0) } ?? "")
            .split(separator: ";").flatMap { item -> [(at: Double, x: Float, y: Float, kind: Int)] in
                let halves = item.split(separator: ":", maxSplits: 1)
                guard halves.count == 2, let at = Double(halves[0]) else { return [] }
                if halves[1].hasPrefix("key="), let code = Float(halves[1].dropFirst(4)) {
                    return [(at, code, 0, 3), (at + 0.15, code, 0, 4)]
                }
                if halves[1].hasPrefix("wheel="), let notches = Float(halves[1].dropFirst(6)) {
                    return [(at, notches, 0, 5)]
                }
                if halves[1].hasPrefix("text=") {
                    debugTexts.append(String(halves[1].dropFirst(5)))
                    return [(at, Float(debugTexts.count - 1), 0, 7)]
                }
                if halves[1].hasPrefix("look=") {
                    let delta = halves[1].dropFirst(5).split(separator: ",").compactMap { Float($0) }
                    return delta.count == 2 ? [(at, delta[0], delta[1], 6)] : []
                }
                let parts = halves[1].split(separator: ",").compactMap { Float($0) }
                guard parts.count == 2 else { return [] }
                return [(at, parts[0], parts[1], 0), (at + 0.2, parts[0], parts[1], 1), (at + 0.35, parts[0], parts[1], 2)]
            }
        var started = timespec()
        clock_gettime(CLOCK_MONOTONIC, &started)

        var event = mead_sdl_event()
        var running = true
        activity.beginUiCallbacks()
        while running {
            while looper.pollOnce(timeout: 0, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_CALLBACK {}
            activity.runUiCallbacks()
            // Typing, likewise: on while the game has a text box open.
            let ownBoxOpen = JavaMinecraftActivity.textBox.isActive
            input.textInputTakesReturn = ownBoxOpen
            if (textInput.isActive || ownBoxOpen) != input.textInputActive {
                input.textInputActive = textInput.isActive || ownBoxOpen
                _ = input.textInputActive ? SDL.startTextInput(sdlWindow) : SDL.stopTextInput(sdlWindow)
            }
            // Pointer capture, asked for on the game's thread, applied on SDL's.
            let wantsCapture = JavaMinecraftActivity.cursorLocked
            if wantsCapture != input.pointerCaptured {
                input.pointerCaptured = wantsCapture
                JavaRuntime.shared.trace("pointer \(wantsCapture ? "captured" : "released")")
                if getenv("MEAD_DEBUG_TAPS") != nil { writeError("pointer \(wantsCapture ? "captured" : "released")") }
                _ = SDL.setWindowRelativeMouseMode(sdlWindow, wantsCapture)
            }
            if let tap = taps.first {
                var now = timespec()
                clock_gettime(CLOCK_MONOTONIC, &now)
                if Double(now.tv_sec - started.tv_sec) + Double(now.tv_nsec - started.tv_nsec) / 1e9 >= tap.at {
                    taps.removeFirst()
                    writeError("debug \(["move", "down", "up", "key down", "key up", "wheel", "look", "text"][tap.kind]) at \(tap.x),\(tap.y)")
                    do {
                        var click = mead_sdl_event()
                        switch tap.kind {
                        case 0:
                            click.motion.type = UInt32(MEAD_SDL_EVENT_MOUSE_MOTION)
                            click.motion.x = tap.x
                            click.motion.y = tap.y
                        case 1, 2:
                            let down = tap.kind == 1
                            click.button.type = UInt32(down ? MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN : MEAD_SDL_EVENT_MOUSE_BUTTON_UP)
                            click.button.button = UInt8(MEAD_SDL_BUTTON_LEFT)
                            click.button.down = down
                            click.button.x = tap.x
                            click.button.y = tap.y
                        case 3, 4:
                            click.key.type = UInt32(tap.kind == 3 ? MEAD_SDL_EVENT_KEY_DOWN : MEAD_SDL_EVENT_KEY_UP)
                            click.key.scancode = UInt32(tap.x)
                            click.key.down = tap.kind == 3
                        case 7:
                            writeError("debug text box open: \(textInput.isActive)")
                            debugTexts[Int(tap.x)].withCString { text in
                                click.text.type = UInt32(MEAD_SDL_EVENT_TEXT_INPUT)
                                click.text.text = text
                                input.handle(click, windowWidth: Float(window.pixelWidth), windowHeight: Float(window.pixelHeight))
                            }
                            continue
                        case 6:
                            click.motion.type = UInt32(MEAD_SDL_EVENT_MOUSE_MOTION)
                            click.motion.x = Float(window.pixelWidth) / 2
                            click.motion.y = Float(window.pixelHeight) / 2
                            click.motion.xrel = tap.x
                            click.motion.yrel = tap.y
                        default:
                            click.wheel.type = UInt32(MEAD_SDL_EVENT_MOUSE_WHEEL)
                            click.wheel.y = tap.x
                            click.wheel.mouse_x = Float(window.pixelWidth) / 2
                            click.wheel.mouse_y = Float(window.pixelHeight) / 2
                        }
                        input.handle(click, windowWidth: Float(window.pixelWidth), windowHeight: Float(window.pixelHeight))
                    }
                }
            }
            guard SDL.waitEventTimeout(&event, 10) else { continue }
            switch Int(event.type) {
            case MEAD_SDL_EVENT_QUIT, MEAD_SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                running = false
            case MEAD_SDL_EVENT_WINDOW_RESIZED, MEAD_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                window.windowWasResized()
                // A buffer size the game set was for the old window.
                window.bufferWidth = 0
                window.bufferHeight = 0
                JavaMinecraftActivity.screenWidth = window.pixelWidth
                JavaMinecraftActivity.screenHeight = window.pixelHeight
                widthValue.i = window.pixelWidth
                heightValue.i = window.pixelHeight
                lifecycle("onSurfaceChangedNative", "(JLandroid/view/Surface;III)V", [surfaceValue, format, widthValue, heightValue])
                // Minecraft's own Java tells it as well, and that is what it
                // lays its screens out by.
                _ = thread.call("com/mojang/minecraftpe/MainActivity", "nativeResize", "(II)V", on: activity, [widthValue, heightValue])
            default:
                input.handle(event, windowWidth: Float(window.pixelWidth), windowHeight: Float(window.pixelHeight),
                             pixelsPerPoint: window.pixelsPerPoint)
            }
        }

        activity.endUiCallbacks()
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
