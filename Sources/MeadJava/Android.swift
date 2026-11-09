import MeadJNI

@JavaClass("android/content/res/AssetManager")
public final class JavaAssetManager: JavaObject {}

@JavaClass("android/content/Context")
open class JavaContext: JavaObject {
    private let assets = JavaAssetManager()

    @JavaMethod("getAssets") public func getAssets() -> JavaAssetManager? { assets }
    @JavaMethod("getClassLoader") public func getClassLoader() -> JavaClassLoader? { JavaClassLoader() }
    @JavaMethod("getPackageName") public func getPackageName() -> String? { AndroidEnvironment.packageName }
    @JavaMethod("getApplicationContext") public func getApplicationContext() -> JavaContext? { self }
    @JavaMethod("getFilesDir") public func getFilesDir() -> JavaFile? { JavaFile(path: AndroidEnvironment.filesDirectory) }
    @JavaMethod("getCacheDir") public func getCacheDir() -> JavaFile? { JavaFile(path: AndroidEnvironment.cacheDirectory) }

    @JavaMethod("getExternalFilesDir", signature: "(Ljava/lang/String;)Ljava/io/File;")
    public func getExternalFilesDir(_ type: String?) -> JavaFile? {
        JavaFile(path: AndroidEnvironment.filesDirectory)
    }

    /// Which services exist is up to each game's compatibility classes.
    @JavaMethod("getSystemService", signature: "(Ljava/lang/String;)Ljava/lang/Object;")
    public func getSystemService(_ name: String?) -> JavaObject? {
        JavaRuntime.shared.problemOnceForFramework("Context.getSystemService(\(name ?? "null")) is not implemented")
        return nil
    }
}

@JavaClass("android/content/ContextWrapper")
open class JavaContextWrapper: JavaContext {}

@JavaClass("android/app/Activity")
open class JavaActivity: JavaContextWrapper {
    /// What happens when native code asks to finish; set by the runner.
    public var onFinish: (() -> Void)?

    @JavaMethod("finish") public func finish() {
        onFinish?()
    }
}

@JavaClass("com/google/androidgamesdk/GameActivity")
open class JavaGameActivity: JavaActivity {
    private let noInsets = JavaInsets()

    @JavaMethod("setWindowFlags") public func setWindowFlags(_ add: Int32, _ remove: Int32) {}
    @JavaMethod("setImeEditorInfoFields") public func setImeEditorInfoFields(_ type: Int32, _ action: Int32, _ options: Int32) {}
    @JavaMethod("getWindowInsets") public func getWindowInsets(_ type: Int32) -> JavaInsets? { noInsets }
    @JavaMethod("getWaterfallInsets") public func getWaterfallInsets() -> JavaInsets? { noInsets }
}

@JavaClass("android/app/NativeActivity")
public final class JavaNativeActivity: JavaActivity {}

@JavaClass("android/view/Surface")
public final class JavaSurface: JavaObject {
    /// The ANativeWindow behind it, held for as long as the surface is.
    public var nativeWindow: UnsafeMutableRawPointer?

    public init(nativeWindow: UnsafeMutableRawPointer?) {
        self.nativeWindow = nativeWindow
        super.init()
    }
}

/// FMOD's Java half, which its native half asks what the device can do. The
/// answers send it down its native AAudio path; a stand-in's zeros would send
/// it to android.media.AudioTrack, which nothing here implements.
@JavaClass("org/fmod/FMOD")
public final class JavaFMOD: JavaObject {
    @JavaMethod("checkInit") public static func checkInit() -> Bool { true }
    @JavaMethod("supportsLowLatency") public static func supportsLowLatency() -> Bool { true }
    @JavaMethod("supportsAAudio") public static func supportsAAudio() -> Bool { true }
    @JavaMethod("getOutputSampleRate") public static func getOutputSampleRate() -> Int32 { 48000 }
    @JavaMethod("getOutputBlockSize") public static func getOutputBlockSize() -> Int32 { 240 }
    @JavaMethod("getAssetManager") public static func getAssetManager() -> JavaAssetManager? { JavaAssetManager() }
}

/// The Java half of Google Play's pairip, whose native half is the game's own
/// libpairipcore.so. The bytecode invoke would run is in the APK's DEX, which
/// Mead cannot run, so it does nothing and returns null, as mcpelauncher's
/// does. It claims no license or integrity result.
@JavaClass("com/pairip/VMRunner")
public final class JavaPairipVMRunner: JavaObject {
    @JavaMethod("invoke", signature: "(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/Object;")
    public static func invoke(_ name: String?, _ arguments: JavaObject?) -> JavaObject? {
        JavaRuntime.shared.trace("com/pairip/VMRunner.invoke(\(name ?? "null")) is a no-op")
        return nil
    }
}

@JavaClass("android/os/Build")
public final class JavaBuild: JavaObject {
    @JavaField("BOARD") public static var board: String? = "mead"
    @JavaField("BRAND") public static var brand: String? = "mead"
    @JavaField("CPU_ABI") public static var cpuABI: String? = "arm64-v8a"
    @JavaField("DEVICE") public static var device: String? = "mead"
    @JavaField("FINGERPRINT") public static var fingerprint: String? = ""
    @JavaField("HARDWARE") public static var hardware: String? = "mead"
    @JavaField("ID") public static var id: String? = ""
    @JavaField("MANUFACTURER") public static var manufacturer: String? = "mead"
    @JavaField("MODEL") public static var model: String? = "Mead"
    @JavaField("PRODUCT") public static var product: String? = "mead"
    @JavaField("TAGS") public static var tags: String? = "release-keys"
    @JavaField("TYPE") public static var type: String? = "user"

    /// Takes what system properties say, so that the two views of the
    /// device agree.
    static func refresh() {
        board = AndroidEnvironment.property("ro.product.board", default: "mead")
        brand = AndroidEnvironment.property("ro.product.brand", default: "mead")
        cpuABI = AndroidEnvironment.property("ro.product.cpu.abi", default: "arm64-v8a")
        device = AndroidEnvironment.property("ro.product.device", default: "mead")
        fingerprint = AndroidEnvironment.property("ro.build.fingerprint", default: "")
        hardware = AndroidEnvironment.property("ro.hardware", default: "mead")
        id = AndroidEnvironment.property("ro.build.id", default: "")
        manufacturer = AndroidEnvironment.property("ro.product.manufacturer", default: "mead")
        model = AndroidEnvironment.property("ro.product.model", default: "Mead")
        product = AndroidEnvironment.property("ro.product.name", default: "mead")
        tags = AndroidEnvironment.property("ro.build.tags", default: "release-keys")
        type = AndroidEnvironment.property("ro.build.type", default: "user")
    }
}

@JavaClass("android/os/Build$VERSION")
public final class JavaBuildVersion: JavaObject {
    @JavaField("SDK_INT") public static var sdkInt: Int32 = 33
    @JavaField("SDK") public static var sdk: String? = "33"
    @JavaField("RELEASE") public static var release: String? = "13"
    @JavaField("CODENAME") public static var codename: String? = "REL"
    @JavaField("INCREMENTAL") public static var incremental: String? = "1"

    static func refresh() {
        let level = AndroidEnvironment.property("ro.build.version.sdk", default: "33")
        sdk = level
        sdkInt = Int32(level) ?? 33
        release = AndroidEnvironment.property("ro.build.version.release", default: "13")
        codename = AndroidEnvironment.property("ro.build.version.codename", default: "REL")
        incremental = AndroidEnvironment.property("ro.build.version.incremental", default: "1")
    }
}
