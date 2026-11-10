internal import CSwiftJavaJNI
import Glibc
import MeadWindow
internal import SwiftJavaJNICore

/// `mead.view.MeadWindow`'s natives: the Java face of the display bridge for
/// checks, until the window manager hands out surfaces and input channels.
extension ARTDisplay {
    typealias Env = UnsafeMutablePointer<JNIEnv?>

    /// Registers `mead.view.MeadWindow`'s natives, when the app has the class.
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
        // A key as SDL would report it for the window: through the same
        // translation as the keyboard's.
        let injectKey: InjectKey = { env, _, surface, scancode, down in
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
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
            guard let display = ARTDisplay.shared, let window = display.window(env: env, surface: surface) else { return }
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

        let natives: [(String, String, UnsafeMutableRawPointer)] = [
            ("create", "(Ljava/lang/String;II)Landroid/view/Surface;", unsafeBitCast(create, to: UnsafeMutableRawPointer.self)),
            ("openInput", "(Landroid/view/Surface;)Landroid/view/InputChannel;", unsafeBitCast(openInput, to: UnsafeMutableRawPointer.self)),
            ("injectKey", "(Landroid/view/Surface;IZ)V", unsafeBitCast(injectKey, to: UnsafeMutableRawPointer.self)),
            ("injectTouch", "(Landroid/view/Surface;IFF)V", unsafeBitCast(injectTouch, to: UnsafeMutableRawPointer.self)),
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
