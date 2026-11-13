internal import CSwiftJavaJNI
import Glibc
import MeadWindow
internal import SwiftJavaJNICore

/// `mead.view.MeadWindow`'s natives: the Java face of the display bridge for
/// checks, until the window manager hands out surfaces and input channels.
extension ARTDisplay {
    typealias Env = UnsafeMutablePointer<JNIEnv?>

    /// Registers `mead.view.MeadWindow`'s natives, when mead-framework is on
    /// the boot class path.
    func registerNatives(env: JNIEnvironment) {
        guard let jni = env.pointee?.pointee else { return }
        guard let type = jni.FindClass(env, "mead/view/MeadWindow") else {
            jni.ExceptionClear(env)
            return
        }
        typealias Create = @convention(c) (Env?, jclass?, jstring?, jint, jint) -> jobject?
        typealias OpenInput = @convention(c) (Env?, jclass?, jobject?) -> jobject?
        typealias InjectKey = @convention(c) (Env?, jclass?, jobject?, jint, jboolean) -> Void
        typealias InjectTouch = @convention(c) (Env?, jclass?, jobject?, jint, jfloat, jfloat) -> Void

        let create: Create = { env, _, title, width, height in
            guard let env, let jni = env.pointee?.pointee, let display = ARTDisplay.shared else { return nil }
            var name = "Mead"
            if let title, let characters = jni.GetStringUTFChars(env, title, nil) {
                name = String(cString: characters)
                jni.ReleaseStringUTFChars(env, title, characters)
            }
            return display.createSurface(env: env, title: name, width: width, height: height)
        }
        let openInput: OpenInput = { env, _, surface in
            ARTDisplay.shared?.openInput(env: env, surface: surface)
        }
        // A key as SDL would report it for the window (or, with no Surface,
        // the window input goes to): through the same translation as the
        // keyboard's.
        let injectKey: InjectKey = { env, _, surface, scancode, down in
            guard let display = ARTDisplay.shared,
                  let window = surface == nil ? display.inputWindow : display.window(env: env, surface: surface) else { return }
            var event = mead_sdl_event()
            event.key.type = UInt32(down != 0 ? MEAD_SDL_EVENT_KEY_DOWN : MEAD_SDL_EVENT_KEY_UP)
            event.key.windowID = window.id
            event.key.scancode = UInt32(scancode)
            event.key.down = down != 0
            _ = SDL.pushEvent(&event)
        }
        // A touch as SDL would report it for the window, at a position from 0
        // to 1 across it: 0 down, 1 up, 2 moved.
        let injectTouch: InjectTouch = { env, _, surface, action, x, y in
            guard let display = ARTDisplay.shared,
                  let window = surface == nil ? display.inputWindow : display.window(env: env, surface: surface) else { return }
            var event = mead_sdl_event()
            let types = [MEAD_SDL_EVENT_FINGER_DOWN, MEAD_SDL_EVENT_FINGER_UP, MEAD_SDL_EVENT_FINGER_MOTION]
            guard action >= 0, Int(action) < types.count else { return }
            event.finger.type = UInt32(types[Int(action)])
            event.finger.touchID = 1
            event.finger.fingerID = 1
            event.finger.x = x
            event.finger.y = y
            event.finger.pressure = action == 1 ? 0 : 1
            event.finger.windowID = window.id
            _ = SDL.pushEvent(&event)
        }

        // A gamepad button as SDL would report it for the first gamepad.
        typealias InjectGamepadButton = @convention(c) (Env?, jclass?, jint, jboolean) -> Void
        let injectGamepadButton: InjectGamepadButton = { _, _, button, down in
            var event = mead_sdl_event()
            event.gbutton.type = UInt32(down != 0 ? MEAD_SDL_EVENT_GAMEPAD_BUTTON_DOWN : MEAD_SDL_EVENT_GAMEPAD_BUTTON_UP)
            event.gbutton.which = 0
            event.gbutton.button = UInt8(truncatingIfNeeded: button)
            event.gbutton.down = down != 0
            _ = SDL.pushEvent(&event)
        }

        let natives: [(String, String, UnsafeMutableRawPointer)] = [
            ("create", "(Ljava/lang/String;II)Landroid/view/Surface;", unsafeBitCast(create, to: UnsafeMutableRawPointer.self)),
            ("openInput", "(Landroid/view/Surface;)Landroid/view/InputChannel;", unsafeBitCast(openInput, to: UnsafeMutableRawPointer.self)),
            ("injectKey", "(Landroid/view/Surface;IZ)V", unsafeBitCast(injectKey, to: UnsafeMutableRawPointer.self)),
            ("injectTouch", "(Landroid/view/Surface;IFF)V", unsafeBitCast(injectTouch, to: UnsafeMutableRawPointer.self)),
            ("injectGamepadButton", "(IZ)V", unsafeBitCast(injectGamepadButton, to: UnsafeMutableRawPointer.self)),
        ]
        let names = natives.map { strdup($0.0)! }, signatures = natives.map { strdup($0.1)! }
        defer {
            names.forEach { free($0) }
            signatures.forEach { free($0) }
        }
        var methods = natives.indices.map {
            JNINativeMethod(name: names[$0], signature: signatures[$0], fnPtr: natives[$0].2)
        }
        if jni.RegisterNatives(env, type, &methods, jint(methods.count)) != JNI_OK {
            jni.ExceptionClear(env)
            Self.report("mead.view.MeadWindow's natives didn't register")
        }
        jni.DeleteLocalRef(env, type)
    }
}

/// WindowManagerService's natives: the window manager's windows, each a
/// display bridge window, made when the window is first laid out.
extension ARTDisplay {
    func windowManagerNatives() -> [(String, String, UnsafeMutableRawPointer)] {
        typealias Env = UnsafeMutablePointer<JNIEnv?>?
        typealias Create = @convention(c) (Env, jclass?, jstring?, jint, jobject?, jint, jint, jint, jint) -> jlong
        typealias SetFrame = @convention(c) (Env, jclass?, jobject?, jint, jint, jint, jint, jboolean) -> Void
        typealias Show = @convention(c) (Env, jclass?, jobject?, jboolean) -> Void
        typealias AttachInput = @convention(c) (Env, jclass?, jobject?, jobject?) -> Void
        typealias SetFrameInSurface = @convention(c) (Env, jclass?, jobject?, jint, jint, jint, jint) -> Void
        typealias WantsCaptions = @convention(c) (Env, jclass?) -> jboolean
        typealias SurfaceAction = @convention(c) (Env, jclass?, jobject?) -> Void
        typealias WindowID = @convention(c) (Env, jclass?, jobject?) -> jint
        typealias NextWindowEvent = @convention(c) (Env, jclass?) -> jintArray?
        typealias SetFocus = @convention(c) (Env, jclass?, jobject?) -> Void
        typealias SetDimBehind = @convention(c) (Env, jclass?, jobject?, jfloat) -> Void
        typealias SetKeepScreenOn = @convention(c) (Env, jclass?, jobject?, jboolean) -> Void

        // A window, as a SurfaceControl's native object; 0 for none.
        let create: Create = { env, _, title, kind, parent, x, y, width, height in
            guard let env, let jni = env.pointee?.pointee, let display = ARTDisplay.shared else { return 0 }
            var name = "Mead"
            if let title, let characters = jni.GetStringUTFChars(env, title, nil) {
                name = String(cString: characters)
                jni.ReleaseStringUTFChars(env, title, characters)
            }
            let parentWindow = parent.flatMap { display.window(env: env, surface: $0) }
            guard let window = display.createWindow(title: name, width: max(width, 1), height: max(height, 1),
                                                    kind: WindowKind(rawValue: kind) ?? .normal, parent: parentWindow,
                                                    x: x, y: y),
                  let surface = window.surface else { return 0 }
            return jlong(display.functions.surfaceControlCreate(surface))
        }
        let setFrame: SetFrame = { env, _, surface, x, y, width, height, popup in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
            display.setFrame(window, x: x, y: y, width: max(width, 1), height: max(height, 1), popup: popup != 0)
        }
        let show: Show = { env, _, surface, shown in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
            display.setShown(window, shown != 0)
        }
        let attachInput: AttachInput = { env, _, surface, channel in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
            display.attachInput(env: env, window: window, serverChannel: channel)
        }
        let setFrameInSurface: SetFrameInSurface = { env, _, surface, x, y, width, height in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
            display.enqueue {
                window.inputOffset = (Float(x), Float(y))
                window.frame = (x, y, max(width, 1), max(height, 1))
                display.wayland?.setWindowGeometry(window)
                // A size the compositor gave before there was a frame: the
                // window manager lays the window out at it now.
                if let size = window.unsentCompositorSize {
                    window.unsentCompositorSize = nil
                    if size.width != width || size.height != height {
                        display.postWindowEvent(kind: 1, window: window, width: size.width, height: size.height)
                    }
                }
            }
        }
        let wantsCaptions: WantsCaptions = { _, _ in
            guard let display = ARTDisplay.shared else { return 0 }
            return display.onDisplayThread { display.wayland?.decorations == nil } == true ? 1 : 0
        }
        let startMove: SurfaceAction = { env, _, surface in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
            display.enqueue { display.wayland?.startMove(window) }
        }
        let toggleMaximized: SurfaceAction = { env, _, surface in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
            display.enqueue { display.wayland?.toggleMaximized(window) }
        }
        let windowID: WindowID = { env, _, surface in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return 0 }
            return jint(bitPattern: window.id)
        }
        let nextWindowEvent: NextWindowEvent = { env, _ in
            guard let env, let jni = env.pointee?.pointee, let display = ARTDisplay.shared,
                  let array = jni.NewIntArray(env, 4) else { return nil }
            var event = display.nextWindowEvent()
            jni.SetIntArrayRegion(env, array, 0, 4, &event)
            return array
        }
        let setFocus: SetFocus = { env, _, surface in
            guard let display = ARTDisplay.shared else { return }
            let window = surface.flatMap { display.window(env: env, surface: $0) }
            display.enqueue { display.androidFocus = window }
        }
        let setDimBehind: SetDimBehind = { env, _, surface, amount in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
            display.enqueue {
                window.dimAmount = min(max(amount, 0), 1)
                if let parent = window.parent { display.wayland?.updateDim(parent) }
            }
        }
        let setKeepScreenOn: SetKeepScreenOn = { env, _, surface, on in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
            display.enqueue { display.wayland?.setKeepScreenOn(window, on != 0) }
        }
        func pointer<T>(_ function: T) -> UnsafeMutableRawPointer { unsafeBitCast(function, to: UnsafeMutableRawPointer.self) }
        return [
            ("nativeSetDimBehind", "(Landroid/view/Surface;F)V", pointer(setDimBehind)),
            ("nativeSetKeepScreenOn", "(Landroid/view/Surface;Z)V", pointer(setKeepScreenOn)),
            ("nativeSetFrameInSurface", "(Landroid/view/Surface;IIII)V", pointer(setFrameInSurface)),
            ("nativeWantsCaptions", "()Z", pointer(wantsCaptions)),
            ("nativeStartMove", "(Landroid/view/Surface;)V", pointer(startMove)),
            ("nativeToggleMaximized", "(Landroid/view/Surface;)V", pointer(toggleMaximized)),
            ("nativeWindowId", "(Landroid/view/Surface;)I", pointer(windowID)),
            ("nativeNextWindowEvent", "()[I", pointer(nextWindowEvent)),
            ("nativeSetFocus", "(Landroid/view/Surface;)V", pointer(setFocus)),
            ("nativeCreateWindow", "(Ljava/lang/String;ILandroid/view/Surface;IIII)J", pointer(create)),
            ("nativeSetWindowFrame", "(Landroid/view/Surface;IIIIZ)V", pointer(setFrame)),
            ("nativeShowWindow", "(Landroid/view/Surface;Z)V", pointer(show)),
            ("nativeAttachInput", "(Landroid/view/Surface;Landroid/view/InputChannel;)V", pointer(attachInput)),
        ]
    }
}
