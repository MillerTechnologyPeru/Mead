import Glibc
import MeadInterface
import MeadJNI

/// What the framework classes need to know about the world around them.
public enum AndroidEnvironment {
    /// The loader's services, once the provider has started.
    public nonisolated(unsafe) static var loader: UnsafePointer<mead_startup_info>?

    /// The directory the game was extracted to, when it was run from one:
    /// absolute, as Android's paths always are. Unity takes a path without
    /// a leading slash as one inside its own data, not a file.
    public static var gameDirectory: String? {
        guard let directory = getenv("MEAD_DATA_DIR") else { return nil }
        guard let resolved = realpath(directory, nil) else { return String(cString: directory) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The APK the game came in, kept beside what was extracted from it as
    /// base.apk: some engines (Unity's) read their data straight out of it.
    /// Without one, the game's directory stands in.
    public static var packageCodePath: String? {
        guard let directory = gameDirectory else { return nil }
        let apk = "\(directory)/base.apk"
        return access(apk, R_OK) == 0 ? apk : directory
    }

    /// The split APKs beside it, split_*.apk, in name order, as
    /// ApplicationInfo.splitSourceDirs lists them.
    public static var splitCodePaths: [String] {
        guard let directory = gameDirectory, let listing = opendir(directory) else { return [] }
        defer { closedir(listing) }
        var paths: [String] = []
        while let entry = readdir(listing) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name.hasPrefix("split_"), name.hasSuffix(".apk") { paths.append("\(directory)/\(name)") }
        }
        return paths.sorted()
    }

    /// Where the game's native libraries are.
    public static var nativeLibraryDirectory: String? {
        gameDirectory.map { "\($0)/lib/arm64-v8a" }
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

/// Brings the framework classes into being: Android's and Java's own, with
/// no game's. Safe to call again.
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
            ("iterator", "()Ljava/util/Iterator;"),
        ])
        runtime.defineInterface("java/util/List", extending: ["java/util/Collection"], methods: [
            ("get", "(I)Ljava/lang/Object;"), ("set", "(ILjava/lang/Object;)Ljava/lang/Object;"), ("remove", "(I)Ljava/lang/Object;"),
        ])
        runtime.defineInterface("java/util/Set", extending: ["java/util/Collection"], methods: [
            ("iterator", "()Ljava/util/Iterator;"),
        ])
        runtime.defineInterface("java/util/Iterator", methods: [("hasNext", "()Z"), ("next", "()Ljava/lang/Object;")])
        runtime.defineInterface("java/util/Map$Entry", methods: [
            ("getKey", "()Ljava/lang/Object;"), ("getValue", "()Ljava/lang/Object;"),
        ])
        runtime.defineInterface("java/util/Map", methods: [
            ("size", "()I"), ("isEmpty", "()Z"), ("clear", "()V"), ("get", "(Ljava/lang/Object;)Ljava/lang/Object;"),
            ("put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("remove", "(Ljava/lang/Object;)Ljava/lang/Object;"), ("containsKey", "(Ljava/lang/Object;)Z"),
            ("entrySet", "()Ljava/util/Set;"), ("keySet", "()Ljava/util/Set;"), ("values", "()Ljava/util/Collection;"),
        ])

        runtime.defineInterface("android/os/Handler$Callback", methods: [("handleMessage", "(Landroid/os/Message;)Z")])
        runtime.defineInterface("android/view/Choreographer$FrameCallback", methods: [("doFrame", "(J)V")])
        runtime.defineInterface("android/hardware/input/InputManager$InputDeviceListener", methods: [
            ("onInputDeviceAdded", "(I)V"), ("onInputDeviceRemoved", "(I)V"), ("onInputDeviceChanged", "(I)V"),
        ])

        runtime.defineInterface("java/security/Key")
        runtime.defineInterface("java/security/PublicKey", extending: ["java/security/Key"])
        runtime.defineInterface("java/security/spec/KeySpec")

        let classes: [JavaObject.Type] = [
            JavaNumber.self, JavaInteger.self, JavaLong.self, JavaFloat.self, JavaDouble.self, JavaBoolean.self,
            JavaSystem.self, JavaLangThread.self, JavaArrayList.self, JavaHashMap.self, JavaUUID.self, JavaLocale.self,
            JavaFile.self, JavaAssetManager.self, JavaContext.self, JavaContextWrapper.self, JavaActivity.self,
            JavaNativeActivity.self, JavaBuild.self, JavaBuildVersion.self, JavaSurface.self, JavaFMOD.self, JavaPairipVMRunner.self,
            JavaClassLoader.self, JavaAlertDialogBuilder.self, JavaAlertDialog.self, JavaConfiguration.self, JavaInsets.self, JavaDisplay.self, JavaWindowManager.self,
            JavaGameActivity.self, JavaTextInputConnection.self, JavaTextInputState.self, JavaBase64.self, JavaArrays.self,
            JavaX509EncodedKeySpec.self, JavaRSAPublicKey.self, JavaKeyFactory.self, JavaSignature.self,
            JavaHttpClientRequest.self, JavaMotionEvent.self, JavaKeyEvent.self,
            JavaStringBuilder.self, JavaInputStream.self, JavaFileOutputStream.self, JavaAssetInputStream.self, JavaScanner.self, JavaIntent.self,
            JavaProcess.self,
            JavaApplicationInfo.self, JavaEnvironment.self,
            JavaLooper.self, JavaMessage.self, JavaHandler.self, JavaHandlerThread.self, JavaChoreographer.self,
            JavaCollection.self, JavaIterator.self, JavaMapEntry.self,
            JavaRect.self, JavaWindowMetrics.self, JavaDisplayMetrics.self, JavaLocaleList.self, JavaResources.self,
            JavaDisplayManager.self, JavaAudioManager.self, JavaPowerManager.self, JavaInputManager.self, JavaInputDevice.self, JavaMotionRange.self,
            JavaUri.self, JavaWindow.self, JavaSharedPreferences.self, JavaSharedPreferencesEditor.self,
            JavaSensorManager.self, JavaVibrator.self,
        ]
        for type in classes {
            runtime.defineClass(for: type)
        }
        runtime.classLoaderFactory = { JavaClassLoader() }
        JavaBuild.refresh()
        JavaBuildVersion.refresh()
    }
}
