import Glibc
import MeadInterface
import MeadJNI

/// What the framework classes need to know about the world around them.
public enum AndroidEnvironment {
    /// The loader's services, once the provider has started.
    public nonisolated(unsafe) static var loader: UnsafePointer<mead_startup_info>?

    /// The directory the game was extracted to, when it was run from one.
    public static var gameDirectory: String? {
        getenv("MEAD_DATA_DIR").map { String(cString: $0) }
    }

    /// The app's package. The manifest will say, once something reads it.
    public static var packageName: String {
        getenv("MEAD_PACKAGE").map { String(cString: $0) } ?? "com.mead.app"
    }

    /// What __system_property_get says, through whichever provider answers.
    public static func property(_ name: String, default fallback: String) -> String {
        typealias Getter = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
        guard let lookup = loader?.pointee.lookup_symbol,
              let symbol = lookup(nil, "__system_property_get") else { return fallback }
        var value = [CChar](repeating: 0, count: 92)
        let length = name.withCString { unsafeBitCast(symbol, to: Getter.self)($0, &value) }
        return length > 0 ? String(cString: value) : fallback
    }

    /// The app's private directory, made if it isn't there: ~/.mead/games/<package>.
    public static var dataDirectory: String {
        let home = getenv("HOME").map { String(cString: $0) } ?? "/tmp"
        return "\(home)/.mead/games/\(packageName)"
    }

    /// Where the game keeps what a player would copy around.
    public static var externalDirectory: String {
        makeDirectories(dataDirectory)
        return dataDirectory
    }

    public static var filesDirectory: String {
        let path = "\(dataDirectory)/files"
        makeDirectories(path)
        return path
    }

    public static var cacheDirectory: String {
        let path = "\(dataDirectory)/cache"
        makeDirectories(path)
        return path
    }

    @discardableResult
    public static func makeDirectories(_ path: String) -> Bool {
        var partial = path.hasPrefix("/") ? "" : "."
        for component in path.split(separator: "/") {
            partial += "/\(component)"
            if mkdir(partial, 0o755) != 0, errno != EEXIST {
                return false
            }
        }
        return true
    }
}

/// Brings the framework classes into being. Safe to call again.
public enum JavaFramework {
    public static func register() {
        let runtime = JavaRuntime.shared
        runtime.start()
        runtime.defineInterface("java/lang/Runnable", methods: [("run", "()V")])
        runtime.defineInterface("java/lang/Comparable", methods: [("compareTo", "(Ljava/lang/Object;)I")])
        runtime.defineInterface("java/lang/CharSequence", methods: [("length", "()I"), ("toString", "()Ljava/lang/String;")])
        runtime.defineInterface("java/lang/Iterable")
        runtime.defineInterface("java/util/Collection", extending: ["java/lang/Iterable"], methods: [
            ("size", "()I"), ("isEmpty", "()Z"), ("add", "(Ljava/lang/Object;)Z"), ("clear", "()V"),
        ])
        runtime.defineInterface("java/util/List", extending: ["java/util/Collection"], methods: [
            ("get", "(I)Ljava/lang/Object;"), ("set", "(ILjava/lang/Object;)Ljava/lang/Object;"), ("remove", "(I)Ljava/lang/Object;"),
        ])
        runtime.defineInterface("java/util/Map", methods: [
            ("size", "()I"), ("isEmpty", "()Z"), ("clear", "()V"), ("get", "(Ljava/lang/Object;)Ljava/lang/Object;"),
            ("put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("remove", "(Ljava/lang/Object;)Ljava/lang/Object;"), ("containsKey", "(Ljava/lang/Object;)Z"),
        ])

        runtime.defineInterface("com/mojang/minecraftpe/store/StoreListener")
        runtime.defineInterface("java/security/Key")
        runtime.defineInterface("java/security/PublicKey", extending: ["java/security/Key"])
        runtime.defineInterface("java/security/spec/KeySpec")

        let classes: [JavaObject.Type] = [
            JavaNumber.self, JavaInteger.self, JavaLong.self, JavaFloat.self, JavaDouble.self, JavaBoolean.self,
            JavaSystem.self, JavaLangThread.self, JavaArrayList.self, JavaHashMap.self, JavaUUID.self, JavaLocale.self,
            JavaFile.self, JavaAssetManager.self, JavaContext.self, JavaContextWrapper.self, JavaActivity.self,
            JavaNativeActivity.self, JavaBuild.self, JavaBuildVersion.self, JavaSurface.self, JavaFMOD.self, JavaPairipVMRunner.self,
            JavaClassLoader.self, JavaConfiguration.self, JavaInsets.self, JavaDisplay.self, JavaWindowManager.self,
            JavaGameActivity.self, JavaMinecraftActivity.self, JavaCrashManager.self, JavaAppExitInfoHelper.self,
            JavaHardwareInformation.self, JavaBatteryMonitor.self, JavaThermalMonitor.self, JavaDateTimeHelper.self,
            JavaTextInputConnection.self, JavaTextInputState.self, JavaNetworkMonitor.self, JavaBase64.self, JavaArrays.self,
            JavaX509EncodedKeySpec.self, JavaRSAPublicKey.self, JavaKeyFactory.self, JavaSignature.self, JavaNativeStoreListener.self, JavaExtraLicenseResponseData.self, JavaStore.self, JavaStoreFactory.self,
            JavaHttpClientRequest.self, JavaMotionEvent.self, JavaKeyEvent.self,
        ]
        for type in classes {
            runtime.defineClass(for: type)
        }
        runtime.classLoaderFactory = { JavaClassLoader() }
        JavaBuild.refresh()
        JavaBuildVersion.refresh()
    }
}
