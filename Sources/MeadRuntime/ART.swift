internal import CSwiftJavaJNI
import Glibc
internal import SwiftJavaJNICore

/// Android's runtime, ART, hosted in Mead's process.
///
/// ART comes from the art_standalone build (MillerTechnologyPeru/art_standalone)
/// installed at `home`: `lib/art/libart.so` and its libraries, Android 10's
/// boot class path in `lib/java/dex/art` (which ART finds beside libart), its
/// own JNI libraries in `lib/java/dex/art/natives`, the ICU and time zone
/// data in `share/art/etc`, and `bin/dex2oat`, which compiles the boot class
/// path and each app ahead of time.
///
/// ART loads every native library through libdl_bio's `bionic_dlopen`.
/// MeadDLBio, loaded globally before libart, answers those calls: bionic
/// libraries (an app's NDK code) go to Mead's loader, the rest to the
/// system's linker.
public final class ART {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    /// Mead's loader, for bionic libraries: the provider interface's `dl_*`
    /// functions.
    public struct Loader {
        public typealias Open = @convention(c) (UnsafePointer<CChar>?, Int32) -> UnsafeMutableRawPointer?
        public typealias Symbol = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
        public typealias Close = @convention(c) (UnsafeMutableRawPointer?) -> Int32
        public typealias Error = @convention(c) () -> UnsafePointer<CChar>?

        public var open: Open?
        public var symbol: Symbol?
        public var close: Close?
        public var error: Error?

        public init(open: Open?, symbol: Symbol?, close: Close?, error: Error?) {
            self.open = open
            self.symbol = symbol
            self.close = close
            self.error = error
        }
    }

    /// Where ART is installed.
    public let home: String
    let virtualMachine: JavaVirtualMachine
    private let vm: JavaVMPointer

    public var libraryDirectory: String { "\(home)/lib/art" }
    public var nativesDirectory: String { "\(home)/lib/java/dex/art/natives" }

    /// The options ART starts with: the class path, where an app's native
    /// libraries are, any others given, and MEAD_ART_OPTIONS's, separated
    /// by spaces (for debugging: -Xcheck:jni -Xjnitrace:GameActivity logs
    /// a class's native calls with their arguments).
    public static func options(classPath: [String], libraryPath: [String], extra: [String] = []) -> [String] {
        var options: [String] = []
        if !classPath.isEmpty {
            options.append("-Djava.class.path=\(classPath.joined(separator: ":"))")
        }
        if !libraryPath.isEmpty {
            options.append("-Djava.library.path=\(libraryPath.joined(separator: ":"))")
        }
        let debugging = getenv("MEAD_ART_OPTIONS").map { String(cString: $0).split(separator: " ").map(String.init) } ?? []
        return options + extra + debugging
    }

    /// Starts ART. `providerDirectory` is where Mead's providers are, with
    /// libMeadDLBio.so among them.
    public init(home: String, providerDirectory: String, loader: Loader, options: [String]) throws {
        self.home = home

        // MeadDLBio first, globally, so that libart's bionic_dlopen and the
        // rest bind to it rather than to the libdl_bio libart was linked with.
        guard let dlBio = dlopen("\(providerDirectory)/libMeadDLBio.so", RTLD_NOW | RTLD_GLOBAL) else {
            throw Failure("MeadDLBio: \(String(cString: dlerror()))")
        }
        typealias Install = @convention(c) (Loader.Open?, Loader.Symbol?, Loader.Close?, Loader.Error?) -> Void
        typealias AddDirectory = @convention(c) (UnsafePointer<CChar>) -> Void
        guard let install = dlsym(dlBio, "mead_dl_bio_install_functions"),
              let addDirectory = dlsym(dlBio, "mead_dl_bio_add_search_directory") else {
            throw Failure("MeadDLBio has no mead_dl_bio_install_functions")
        }
        unsafeBitCast(install, to: Install.self)(loader.open, loader.symbol, loader.close, loader.error)
        // ART asks for its own JNI libraries by name.
        "\(home)/lib/java/dex/art/natives".withCString { unsafeBitCast(addDirectory, to: AddDirectory.self)($0) }

        // dex2oat runs as a child process, found on PATH, with its libraries
        // beside libart's.
        Self.prepend("PATH", "\(home)/bin")
        Self.prepend("LD_LIBRARY_PATH", "\(home)/lib/art:\(home)/lib/java/dex/art/natives")
        // The core library's ICU and time zone data, in etc/icu and etc/tz,
        // and Android's /system: Conscrypt's CA certificates, in
        // etc/security/cacerts, the framework's resources and build.prop.
        for variable in ["ANDROID_ROOT", "ANDROID_RUNTIME_ROOT", "ANDROID_TZDATA_ROOT"] where getenv(variable) == nil {
            setenv(variable, "\(home)/share/art", 1)
        }
        // Android 10's boot class path, in the environment as Android has it,
        // so that the runtime and the dex2oat it starts agree on it.
        // Mead's own, mead-framework.jar, after them; its backports,
        // mead-backports.jar, ahead of framework.jar, so that their classes
        // are the ones defined.
        if getenv("BOOTCLASSPATH") == nil {
            var jars = Self.bootClassPath.map { "\(home)/lib/java/dex/art/\($0).jar" }
            if let backports = Self.meadBackports(providerDirectory: providerDirectory),
               let framework = Self.bootClassPath.firstIndex(of: "framework") {
                jars.insert(backports, at: framework)
            }
            if let meadFramework = Self.meadFramework(providerDirectory: providerDirectory) {
                jars.append(meadFramework)
            }
            setenv("BOOTCLASSPATH", jars.joined(separator: ":"), 1)
        }
        if getenv("ANDROID_DATA") == nil {
            let data = "\(getenv("HOME").map { String(cString: $0) } ?? "/tmp")/.mead/art"
            Self.makeDirectories(data)
            setenv("ANDROID_DATA", data, 1)
        }

        guard let art = dlopen("\(home)/lib/art/libart.so", RTLD_NOW) else {
            throw Failure("libart: \(String(cString: dlerror()))")
        }
        typealias CreateJavaVM = @convention(c) (UnsafeMutablePointer<JavaVMPointer?>, UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeMutableRawPointer) -> jint
        guard let create = dlsym(art, "JNI_CreateJavaVM") else {
            throw Failure("libart has no JNI_CreateJavaVM")
        }

        // The options' strings live until the VM has read them.
        let strings = options.map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var vmOptions = strings.map { JavaVMOption(optionString: $0, extraInfo: nil) }
        var created: JavaVMPointer?
        var environment: UnsafeMutableRawPointer?
        let result = vmOptions.withUnsafeMutableBufferPointer { buffer -> jint in
            var arguments = JavaVMInitArgs()
            arguments.version = JNI_VERSION_1_6
            arguments.nOptions = jint(buffer.count)
            arguments.options = buffer.baseAddress
            arguments.ignoreUnrecognized = jboolean(JNI_FALSE)
            return unsafeBitCast(create, to: CreateJavaVM.self)(&created, &environment, &arguments)
        }
        guard result == JNI_OK, let created else {
            throw Failure("JNI_CreateJavaVM returned \(result)")
        }
        vm = created
        virtualMachine = JavaVirtualMachine(adoptingJVM: created)
        JavaVirtualMachine.setSharedJVM(virtualMachine)

        // The framework's JNI, which app_process registers before any Java
        // runs: libandroid_runtime registers it as it loads, for the boot
        // class loader, since no Java frame is calling. By path: the boot
        // class loader searches java.library.path, which is the app's.
        try load("\(nativesDirectory)/libandroid_runtime.so")

        // What the zygote preloads that native code relies on having run.
        try preload(Self.preloadedClasses)

        // Mead's display bridge, over the libgui libandroid_runtime loaded;
        // an install without one has no windows.
        ARTDisplay.shared = try? ARTDisplay(home: home)

        // The system services, in-process, and mead.view.MeadWindow's natives,
        // both in mead-framework.
        try startServices()
        // AudioTrack's natives, over SDL's audio.
        try registerAudioTrack()
        if let display = ARTDisplay.shared {
            display.registerNatives(env: try virtualMachine.environment())
        }
    }

    /// Android 10's boot class path, in order, as its init.environ.rc has it.
    static let bootClassPath = [
        "core-oj", "core-libart", "okhttp", "bouncycastle", "apache-xml", "conscrypt",
        "framework", "ext", "telephony-common", "voip-common", "ims-common",
        "updatable-media", "android.test.base",
    ]

    /// Boot classes the zygote initializes before any app runs, whose
    /// initializers native code depends on: Typeface's sets hwui's default
    /// typeface, which drawing text with a Paint that has none uses.
    static let preloadedClasses = ["android.graphics.Typeface"]

    /// Initializes boot classes, as the zygote's preloading does, with
    /// `Class.forName(name, true, null)`.
    private func preload(_ classNames: [String]) throws {
        let env = try virtualMachine.environment()
        guard let jni = env.pointee?.pointee else { throw Failure("no JNIEnv") }
        guard let classType = jni.FindClass(env, "java/lang/Class"),
              let forName = jni.GetStaticMethodID(env, classType, "forName",
                                                  "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;") else {
            throw Failure("no Class.forName\(describeException(env))")
        }
        for className in classNames {
            var arguments = [jvalue(), jvalue(), jvalue()]
            arguments[0].l = jni.NewStringUTF(env, className)
            arguments[1].z = jboolean(JNI_TRUE)
            arguments[2].l = nil
            let loaded = jni.CallStaticObjectMethodA(env, classType, forName, &arguments)
            jni.DeleteLocalRef(env, arguments[0].l)
            if jni.ExceptionCheck(env) != 0 {
                throw Failure("initializing \(className) threw\(describeException(env))")
            }
            jni.DeleteLocalRef(env, loaded)
        }
    }

    /// Loads a JNI library by path for the boot class loader, as
    /// `System.load` would from a boot class. `System.load` itself asks for
    /// its caller's class loader, and from here no Java frame is calling, so
    /// this goes to `Runtime.load0` with `System` as the class loading it.
    private func load(_ path: String) throws {
        let env = try virtualMachine.environment()
        guard let jni = env.pointee?.pointee else { throw Failure("no JNIEnv") }
        guard let system = jni.FindClass(env, "java/lang/System"),
              let runtimeType = jni.FindClass(env, "java/lang/Runtime"),
              let getRuntime = jni.GetStaticMethodID(env, runtimeType, "getRuntime", "()Ljava/lang/Runtime;"),
              let load0 = jni.GetMethodID(env, runtimeType, "load0", "(Ljava/lang/Class;Ljava/lang/String;)V"),
              let runtime = jni.CallStaticObjectMethodA(env, runtimeType, getRuntime, nil) else {
            throw Failure("no Runtime.load0\(describeException(env))")
        }
        var arguments = [jvalue(), jvalue()]
        arguments[0].l = system
        arguments[1].l = jni.NewStringUTF(env, path)
        jni.CallVoidMethodA(env, runtime, load0, &arguments)
        jni.DeleteLocalRef(env, arguments[1].l)
        if jni.ExceptionCheck(env) != 0 {
            throw Failure("loading \(path) threw\(describeException(env))")
        }
    }

    /// Calls `main(String[])` on the class named `className` ("com.example.Main"
    /// or "com/example/Main"), as `java` would.
    public func runMain(className: String, arguments: [String]) throws {
        let env = try virtualMachine.environment()
        guard let jni = env.pointee?.pointee else { throw Failure("no JNIEnv") }
        let name = String(className.map { $0 == "." ? "/" : $0 })
        guard let type = jni.FindClass(env, name) else {
            throw Failure("no class \(className)\(describeException(env))")
        }
        guard let main = jni.GetStaticMethodID(env, type, "main", "([Ljava/lang/String;)V") else {
            throw Failure("\(className) has no main(String[])\(describeException(env))")
        }
        guard let stringType = jni.FindClass(env, "java/lang/String"),
              let array = jni.NewObjectArray(env, jsize(arguments.count), stringType, nil) else {
            throw Failure("no String[] for main's arguments\(describeException(env))")
        }
        for (index, argument) in arguments.enumerated() {
            let string = jni.NewStringUTF(env, argument)
            jni.SetObjectArrayElement(env, array, jsize(index), string)
            jni.DeleteLocalRef(env, string)
        }
        var argument = jvalue()
        argument.l = array
        jni.CallStaticVoidMethodA(env, type, main, &argument)
        if jni.ExceptionCheck(env) != 0 {
            throw Failure("\(className).main threw\(describeException(env))")
        }
    }

    /// Waits for the Java threads that aren't daemons, then shuts ART down,
    /// as `java` does when main returns.
    public func shutDown() {
        // As `java` does: the main thread leaves the VM first.
        _ = vm.pointee?.pointee.DetachCurrentThread(vm)
        _ = vm.pointee?.pointee.DestroyJavaVM(vm)
    }

    /// Prints the pending exception, as Java does for an uncaught one, and
    /// clears it.
    func describeException(_ env: JNIEnvironment) -> String {
        guard let jni = env.pointee?.pointee, jni.ExceptionCheck(env) != 0 else { return "" }
        jni.ExceptionDescribe(env)
        jni.ExceptionClear(env)
        return " (the exception is above)"
    }

    private static func prepend(_ variable: String, _ value: String) {
        if let current = getenv(variable), current.pointee != 0 {
            setenv(variable, "\(value):\(String(cString: current))", 1)
        } else {
            setenv(variable, value, 1)
        }
    }

    private static func makeDirectories(_ path: String) {
        var partial = ""
        for component in path.split(separator: "/") {
            partial += "/\(component)"
            mkdir(partial, 0o755)
        }
    }
}
