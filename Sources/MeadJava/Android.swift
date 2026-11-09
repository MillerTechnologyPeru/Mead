import Glibc
import MeadJNI

@JavaClass("android/content/res/AssetManager")
public final class JavaAssetManager: JavaObject {
    /// An asset, from the assets/ directory the game was extracted with.
    @JavaMethod("open", signature: "(Ljava/lang/String;)Ljava/io/InputStream;")
    public func open(_ name: String?) throws -> JavaAssetInputStream? {
        try open(name, 2)  // ACCESS_STREAMING
    }

    @JavaMethod("open", signature: "(Ljava/lang/String;I)Ljava/io/InputStream;")
    public func open(_ name: String?, _ mode: Int32) throws -> JavaAssetInputStream? {
        guard let name else {
            throw JavaException("java/lang/NullPointerException", "open(null)")
        }
        JavaRuntime.shared.trace("AssetManager.open \(name)")
        guard let directory = AndroidEnvironment.gameDirectory, let bytes = readWholeFile("\(directory)/assets/\(name)") else {
            throw JavaException("java/io/FileNotFoundException", name)
        }
        return JavaAssetInputStream(bytes: bytes)
    }
}

/// A file's bytes, or nil if it can't be read.
func readWholeFile(_ path: String) -> [UInt8]? {
    let descriptor = Glibc.open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 { return nil }
        if count == 0 { return bytes }
        bytes += chunk[0..<count]
    }
}

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

    @JavaMethod("getPackageCodePath") public func getPackageCodePath() -> String? { AndroidEnvironment.packageCodePath }
    @JavaMethod("getPackageResourcePath") public func getPackageResourcePath() -> String? { AndroidEnvironment.packageCodePath }
    @JavaMethod("getApplicationInfo") public func getApplicationInfo() -> JavaApplicationInfo? { JavaApplicationInfo() }

    @JavaField("MODE_PRIVATE") public static var modePrivate: Int32 = 0
    @JavaField("AUDIO_SERVICE", signature: "Ljava/lang/String;") public static var audioService: String? = "audio"
    @JavaField("POWER_SERVICE", signature: "Ljava/lang/String;") public static var powerService: String? = "power"
    @JavaField("WINDOW_SERVICE", signature: "Ljava/lang/String;") public static var windowService: String? = "window"
    @JavaField("DISPLAY_SERVICE", signature: "Ljava/lang/String;") public static var displayService: String? = "display"
    @JavaField("INPUT_SERVICE", signature: "Ljava/lang/String;") public static var inputService: String? = "input"
    @JavaField("VIBRATOR_SERVICE", signature: "Ljava/lang/String;") public static var vibratorService: String? = "vibrator"
    @JavaField("CONNECTIVITY_SERVICE", signature: "Ljava/lang/String;") public static var connectivityService: String? = "connectivity"
    @JavaField("SENSOR_SERVICE", signature: "Ljava/lang/String;") public static var sensorService: String? = "sensor"

    private let resources = JavaResources()
    @JavaMethod("getResources") public func getResources() -> JavaResources? { resources }

    @JavaMethod("getExternalCacheDir") public func getExternalCacheDir() -> JavaFile? { JavaFile(path: AndroidEnvironment.cacheDirectory) }

    /// Where expansion files would be; there are none, but the directory is.
    @JavaMethod("getObbDir") public func getObbDir() -> JavaFile? {
        let path = "\(AndroidEnvironment.dataDirectory)/obb"
        AndroidEnvironment.makeDirectories(path)
        return JavaFile(path: path)
    }

    @JavaMethod("getObbDirs", signature: "()[Ljava/io/File;") public func getObbDirs() -> JavaObject? {
        let array = JavaRuntime.shared.newObjectArray(elementClass: "java/io/File", count: 0) as? JavaObjectArray
        array?.elements = [getObbDir()]
        return array
    }

    @JavaMethod("getSharedPreferences", signature: "(Ljava/lang/String;I)Landroid/content/SharedPreferences;")
    public func getSharedPreferences(_ name: String?, _ mode: Int32) -> JavaSharedPreferences? {
        JavaSharedPreferences.named(name ?? "\(AndroidEnvironment.packageName)_preferences")
    }

    /// The services a desktop has an answer for; anything else is each
    /// game's compatibility classes' to add.
    public func standardService(_ name: String?) -> JavaObject? {
        switch name {
        case "window": return JavaWindowManager()
        case "display": return JavaDisplayManager()
        case "audio": return JavaAudioManager()
        case "power": return JavaPowerManager()
        case "input": return JavaInputManager()
        case "sensor": return JavaSensorManager()
        case "vibrator": return JavaVibrator()
        default: return nil
        }
    }

    /// Which services exist is up to each game's compatibility classes.
    @JavaMethod("getSystemService", signature: "(Ljava/lang/String;)Ljava/lang/Object;")
    open func getSystemService(_ name: String?) -> JavaObject? {
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

    private let intent = JavaIntent()
    @JavaMethod("getIntent") public func getIntent() -> JavaIntent? { intent }

    private let window = JavaWindow()
    @JavaMethod("getWindow") public func getWindow() -> JavaWindow? { window }
    @JavaMethod("setRequestedOrientation") public func setRequestedOrientation(_ orientation: Int32) {}

    /// The process's main thread is the UI thread here: called there, the
    /// runnable runs now; from another thread, at the main loop's next turn.
    @JavaMethod("runOnUiThread", signature: "(Ljava/lang/Runnable;)V")
    public func runOnUiThread(_ runnable: JavaObject?) {
        guard let runnable else { return }
        let run = { _ = JavaRuntime.shared.attachCurrentThread().call("java/lang/Runnable", "run", "()V", on: runnable) }
        if JavaLooper.current === JavaLooper.main { run() } else { JavaLooper.main.post(run) }
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
    @JavaField("SOC_MANUFACTURER") public static var socManufacturer: String? = "unknown"
    @JavaField("SOC_MODEL") public static var socModel: String? = "unknown"
    @JavaField("BOOTLOADER") public static var bootloader: String? = "unknown"
    @JavaField("DISPLAY") public static var display: String? = ""
    @JavaField("HOST") public static var host: String? = "mead"
    @JavaField("USER") public static var user: String? = "mead"
    @JavaField("SERIAL") public static var serial: String? = "unknown"
    @JavaField("RADIO") public static var radio: String? = "unknown"
    @JavaField("TIME") public static var time: Int64 = 0
    @JavaField("SUPPORTED_ABIS", signature: "[Ljava/lang/String;")
    public static var supportedABIs: JavaObject? = JavaRuntime.shared.newStringArray(["arm64-v8a"])
    @JavaField("SUPPORTED_64_BIT_ABIS", signature: "[Ljava/lang/String;")
    public static var supported64BitABIs: JavaObject? = JavaRuntime.shared.newStringArray(["arm64-v8a"])
    @JavaField("SUPPORTED_32_BIT_ABIS", signature: "[Ljava/lang/String;")
    public static var supported32BitABIs: JavaObject? = JavaRuntime.shared.newStringArray([])

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
        socManufacturer = AndroidEnvironment.property("ro.soc.manufacturer", default: "unknown")
        socModel = AndroidEnvironment.property("ro.soc.model", default: "unknown")
        display = AndroidEnvironment.property("ro.build.display.id", default: id ?? "")
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

/// Where the app is installed, as its package manager would say.
@JavaClass("android/content/pm/ApplicationInfo")
public final class JavaApplicationInfo: JavaObject {
    @JavaField("packageName") public var packageName: String? = AndroidEnvironment.packageName
    @JavaField("sourceDir") public var sourceDir: String? = AndroidEnvironment.packageCodePath
    @JavaField("publicSourceDir") public var publicSourceDir: String? = AndroidEnvironment.packageCodePath
    @JavaField("splitSourceDirs", signature: "[Ljava/lang/String;")
    public var splitSourceDirs: JavaObject? = {
        let splits = AndroidEnvironment.splitCodePaths
        return splits.isEmpty ? nil : JavaRuntime.shared.newStringArray(splits)
    }()
    @JavaField("splitPublicSourceDirs", signature: "[Ljava/lang/String;")
    public var splitPublicSourceDirs: JavaObject? = {
        let splits = AndroidEnvironment.splitCodePaths
        return splits.isEmpty ? nil : JavaRuntime.shared.newStringArray(splits)
    }()
    @JavaField("nativeLibraryDir") public var nativeLibraryDir: String? = AndroidEnvironment.nativeLibraryDirectory
    @JavaField("dataDir") public var dataDir: String? = AndroidEnvironment.dataDirectory
    @JavaField("targetSdkVersion") public var targetSdkVersion: Int32 = 35
    @JavaField("minSdkVersion") public var minSdkVersion: Int32 = 24
    @JavaField("flags") public var flags: Int32 = 0
}

/// android.os.Environment: external storage is there, and is the app's
/// own directory.
@JavaClass("android/os/Environment")
public final class JavaEnvironment: JavaObject {
    @JavaField("MEDIA_MOUNTED") public static var mediaMounted: String? = "mounted"
    @JavaMethod("getExternalStorageState") public static func getExternalStorageState() -> String? { "mounted" }
    @JavaMethod("getExternalStorageDirectory") public static func getExternalStorageDirectory() -> JavaFile? {
        JavaFile(path: AndroidEnvironment.externalDirectory)
    }
    @JavaMethod("getDataDirectory") public static func getDataDirectory() -> JavaFile? { JavaFile(path: AndroidEnvironment.dataDirectory) }
}
