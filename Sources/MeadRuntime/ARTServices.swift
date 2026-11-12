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
            // The bridge describes the display when it starts: start it, so
            // what's asked before the first window is the real display.
            _ = ARTDisplay.shared?.onDisplayThread {}
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

        // WindowManagerService's: its windows, from the display bridge.
        if let display = ARTDisplay.shared {
            try register(env: env, className: "mead/server/WindowManagerService",
                         natives: display.windowManagerNatives())
        }

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
        // PointerIcon's types as the cursor theme's CSS names.
        typealias SetPointerIcon = @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?, jint) -> Void
        let setPointerIcon: SetPointerIcon = { _, _, type in
            let names: [Int32: String] = [
                0: "none", 1000: "default", 1001: "context-menu", 1002: "pointer", 1003: "help", 1004: "wait",
                1006: "cell", 1007: "crosshair", 1008: "text", 1009: "vertical-text", 1010: "alias", 1011: "copy",
                1012: "no-drop", 1013: "all-scroll", 1014: "ew-resize", 1015: "ns-resize", 1016: "nesw-resize",
                1017: "nwse-resize", 1018: "zoom-in", 1019: "zoom-out", 1020: "grab", 1021: "grabbing",
            ]
            let name = names[type] ?? "default"
            guard let display = ARTDisplay.shared else { return }
            display.enqueue {
                display.wayland?.appCursor = name
                display.wayland?.updateCursor()
            }
        }
        try register(env: env, className: "mead/server/InputManagerService", natives: [
            ("nativeSetPointerIcon", "(I)V", unsafeBitCast(setPointerIcon, to: UnsafeMutableRawPointer.self)),
            ("nativeLoadKeyCharacterMap", "(ILjava/lang/String;)Landroid/view/KeyCharacterMap;",
             unsafeBitCast(loadKeyCharacterMap, to: UnsafeMutableRawPointer.self)),
            ("nativeGamepads", "()[I", unsafeBitCast(gamepads, to: UnsafeMutableRawPointer.self)),
        ])

        try registerNativeStubs(env: env)
        try registerLicensing(env: env)

        guard let start = jni.GetStaticMethodID(env, services, "start", "()V") else {
            throw Failure("mead.server.MeadServices has no start()\(describeException(env))")
        }
        jni.CallStaticVoidMethodA(env, services, start, nil)
        jni.DeleteLocalRef(env, services)
        if jni.ExceptionCheck(env) != 0 {
            throw Failure("starting Mead's services threw\(describeException(env))")
        }
    }

    func register(env: JNIEnvironment, className: String, natives: [(String, String, UnsafeMutableRawPointer)]) throws {
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

    /// A native for NativeStubs' classes: nothing done, zero returned. It
    /// takes the arguments each method's descriptor says, and never reads
    /// them.
    private static let nativeStub: @convention(c) (UnsafeMutablePointer<JNIEnv?>?, jclass?) -> jlong = { _, _ in 0 }

    /// Registers mead.server.NativeStubs' classes' natives as doing nothing.
    private func registerNativeStubs(env: JNIEnvironment) throws {
        guard let jni = env.pointee?.pointee else { throw Failure("no JNIEnv") }
        guard let stubs = jni.FindClass(env, "mead/server/NativeStubs"),
              let classesField = jni.GetStaticFieldID(env, stubs, "CLASSES", "[Ljava/lang/String;"),
              let signaturesMethod = jni.GetStaticMethodID(env, stubs, "signatures", "(Ljava/lang/String;)[Ljava/lang/String;"),
              let classes = jni.GetStaticObjectField(env, stubs, classesField) else {
            jni.ExceptionClear(env)
            return
        }
        func string(_ array: jobject, _ index: jsize) -> String {
            guard let element = jni.GetObjectArrayElement(env, array, index),
                  let characters = jni.GetStringUTFChars(env, element, nil) else { return "" }
            defer {
                jni.ReleaseStringUTFChars(env, element, characters)
                jni.DeleteLocalRef(env, element)
            }
            return String(cString: characters)
        }
        let stub = unsafeBitCast(Self.nativeStub, to: UnsafeMutableRawPointer.self)
        for index in 0..<jni.GetArrayLength(env, classes) {
            let name = string(classes, index)
            var argument = jvalue()
            argument.l = jni.NewStringUTF(env, name)
            let signatures = jni.CallStaticObjectMethodA(env, stubs, signaturesMethod, &argument)
            jni.DeleteLocalRef(env, argument.l)
            guard let signatures, jni.ExceptionCheck(env) == 0 else {
                throw Failure("listing \(name)'s natives threw\(describeException(env))")
            }
            var natives: [(String, String, UnsafeMutableRawPointer)] = []
            var item: jsize = 0
            while item + 1 < jni.GetArrayLength(env, signatures) {
                natives.append((string(signatures, item), string(signatures, item + 1), stub))
                item += 2
            }
            jni.DeleteLocalRef(env, signatures)
            try register(env: env, className: String(name.map { $0 == "." ? "/" : $0 }), natives: natives)
        }
    }
}
