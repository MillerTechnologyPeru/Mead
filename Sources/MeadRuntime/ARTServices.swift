internal import CSwiftJavaJNI
import Glibc
internal import SwiftJavaJNICore

/// Android's system services, in-process: mead-framework.jar's `IXxx.Stub`
/// classes (`Java/mead-framework`), whose natives are here, put in
/// ServiceManager's cache by `mead.server.MeadServices.start()`.
extension ART {
    /// mead-framework.jar, beside Mead's providers.
    static func meadFramework(providerDirectory: String) -> String? {
        let path = "\(providerDirectory)/mead-framework.jar"
        return access(path, R_OK) == 0 ? path : nil
    }

    /// libgui's `mead_gui_get_display`, which the display service answers
    /// from.
    nonisolated(unsafe) static var getDisplay: (@convention(c) (UnsafeMutableRawPointer) -> Void)?

    typealias LoadKeyCharacterMapFunction = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, Int32, UnsafePointer<CChar>) -> jobject?

    /// libandroid_runtime's `mead_input_load_key_character_map`.
    nonisolated(unsafe) static var loadKeyCharacterMap: LoadKeyCharacterMapFunction?

    /// Registers the services' natives and starts them, when mead-framework
    /// is on the boot class path.
    func startServices() throws {
        let env = try virtualMachine.environment()
        guard let jni = env.pointee?.pointee else { throw Failure("no JNIEnv") }
        guard let services = jni.FindClass(env, "mead/server/MeadServices") else {
            jni.ExceptionClear(env)
            return
        }
        if let gui = dlopen("\(libraryDirectory)/libgui.so", RTLD_NOW | RTLD_NOLOAD),
           let symbol = dlsym(gui, "mead_gui_get_display") {
            Self.getDisplay = unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        }

        // DisplayManagerService.nativeGetDisplay: width, height, xdpi, ydpi,
        // refresh rate and density, from MeadDisplay.
        typealias GetDisplay = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?) -> jfloatArray?
        let getDisplay: GetDisplay = { env, _ in
            guard let env, let jni = env.pointee?.pointee, let array = jni.NewFloatArray(env, 6) else { return nil }
            // MeadDisplay: two uint32_t, then four floats.
            var described = [UInt32](repeating: 0, count: 6)
            described.withUnsafeMutableBytes { ART.getDisplay?($0.baseAddress!) }
            var values: [jfloat] = [Float(described[0]), Float(described[1])]
            values += described[2...].map { Float(bitPattern: $0) }
            if ART.getDisplay == nil {
                values = [1280, 720, 160, 160, 60, 1]
            }
            jni.SetFloatArrayRegion(env, array, 0, 6, values)
            return array
        }
        try register(env: env, className: "mead/server/DisplayManagerService",
                     natives: [("nativeGetDisplay", "()[F", unsafeBitCast(getDisplay, to: UnsafeMutableRawPointer.self))])

        // WindowManagerService.nativeOpenInput: a window's input channel,
        // from the display bridge.
        typealias OpenInput = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?, jobject?) -> jobject?
        let openInput: OpenInput = { env, _, surface in
            ARTDisplay.shared?.openInput(env: env, surface: surface)
        }
        try register(env: env, className: "mead/server/WindowManagerService",
                     natives: [("nativeOpenInput", "(Landroid/view/Surface;)Landroid/view/InputChannel;",
                                unsafeBitCast(openInput, to: UnsafeMutableRawPointer.self))])

        // InputManagerService's: key character maps, through libinput, and
        // the gamepads SDL has open.
        typealias LoadKeyCharacterMap = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?, jint, jstring?) -> jobject?
        typealias Gamepads = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?) -> jintArray?
        if let runtime = dlopen("\(nativesDirectory)/libandroid_runtime.so", RTLD_NOW | RTLD_NOLOAD),
           let symbol = dlsym(runtime, "mead_input_load_key_character_map") {
            Self.loadKeyCharacterMap = unsafeBitCast(symbol, to: LoadKeyCharacterMapFunction.self)
        }
        let loadKeyCharacterMap: LoadKeyCharacterMap = { env, _, deviceId, path in
            guard let env, let jni = env.pointee?.pointee, let path,
                  let characters = jni.GetStringUTFChars(env, path, nil) else { return nil }
            defer { jni.ReleaseStringUTFChars(env, path, characters) }
            return ART.loadKeyCharacterMap?(env, deviceId, characters)
        }
        let gamepads: Gamepads = { env, _ in
            guard let env, let jni = env.pointee?.pointee else { return nil }
            let ids = ARTDisplay.shared?.openGamepads() ?? []
            guard let array = jni.NewIntArray(env, jsize(ids.count)) else { return nil }
            jni.SetIntArrayRegion(env, array, 0, jsize(ids.count), ids.map { jint(bitPattern: $0) })
            return array
        }
        try register(env: env, className: "mead/server/InputManagerService", natives: [
            ("nativeLoadKeyCharacterMap", "(ILjava/lang/String;)Landroid/view/KeyCharacterMap;",
             unsafeBitCast(loadKeyCharacterMap, to: UnsafeMutableRawPointer.self)),
            ("nativeGamepads", "()[I", unsafeBitCast(gamepads, to: UnsafeMutableRawPointer.self)),
        ])

        guard let start = jni.GetStaticMethodID(env, services, "start", "()V") else {
            throw Failure("mead.server.MeadServices has no start()\(describeException(env))")
        }
        jni.CallStaticVoidMethodA(env, services, start, nil)
        jni.DeleteLocalRef(env, services)
        if jni.ExceptionCheck(env) != 0 {
            throw Failure("starting Mead's services threw\(describeException(env))")
        }
    }

    private func register(env: JNIEnvironment, className: String, natives: [(String, String, UnsafeMutableRawPointer)]) throws {
        guard let jni = env.pointee?.pointee else { throw Failure("no JNIEnv") }
        guard let type = jni.FindClass(env, className) else {
            throw Failure("no \(className)\(describeException(env))")
        }
        let names = natives.map { strdup($0.0)! }, signatures = natives.map { strdup($0.1)! }
        defer {
            names.forEach { free($0) }
            signatures.forEach { free($0) }
        }
        var methods = natives.indices.map { JNINativeMethod(name: names[$0], signature: signatures[$0], fnPtr: natives[$0].2) }
        let result = jni.RegisterNatives(env, type, &methods, jint(methods.count))
        jni.DeleteLocalRef(env, type)
        if result != JNI_OK {
            throw Failure("\(className)'s natives didn't register\(describeException(env))")
        }
    }
}
