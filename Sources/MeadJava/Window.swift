import Glibc
import MeadJNI

// Android's window, display and class-loading classes, as games reach them.

@JavaClass("java/lang/ClassLoader")
public final class JavaClassLoader: JavaObject {
    @JavaMethod("findClass", signature: "(Ljava/lang/String;)Ljava/lang/Class;")
    public func findClass(_ name: String?) -> JavaObject? {
        name.flatMap { JavaRuntime.shared.findClassPublic(named: $0) }
    }

    @JavaMethod("loadClass", signature: "(Ljava/lang/String;)Ljava/lang/Class;")
    public func loadClass(_ name: String?) -> JavaObject? {
        findClass(name)
    }

    /// Where System.loadLibrary would find lib<name>.so: the app's own native
    /// library directory, or null if it isn't there.
    @JavaMethod("findLibrary", signature: "(Ljava/lang/String;)Ljava/lang/String;")
    public func findLibrary(_ name: String?) -> String? {
        guard let name, let directory = AndroidEnvironment.nativeLibraryDirectory else { return nil }
        let path = "\(directory)/lib\(name).so"
        return access(path, R_OK) == 0 ? path : nil
    }
}

@JavaClass("android/content/res/Configuration")
public final class JavaConfiguration: JavaObject {
    @JavaField("colorMode") public var colorMode: Int32 = 0
    @JavaField("densityDpi") public var densityDpi: Int32 = 160
    @JavaField("fontScale") public var fontScale: Float = 1
    @JavaField("fontWeightAdjustment") public var fontWeightAdjustment: Int32 = 0
    @JavaField("hardKeyboardHidden") public var hardKeyboardHidden: Int32 = 1
    @JavaField("keyboard") public var keyboard: Int32 = 2
    @JavaField("keyboardHidden") public var keyboardHidden: Int32 = 1
    @JavaField("mcc") public var mcc: Int32 = 0
    @JavaField("mnc") public var mnc: Int32 = 0
    @JavaField("navigation") public var navigation: Int32 = 1
    @JavaField("navigationHidden") public var navigationHidden: Int32 = 1
    @JavaField("orientation") public var orientation: Int32 = 2
    @JavaField("screenHeightDp") public var screenHeightDp: Int32 = 720
    @JavaField("screenLayout") public var screenLayout: Int32 = 3
    @JavaField("screenWidthDp") public var screenWidthDp: Int32 = 1280
    @JavaField("smallestScreenWidthDp") public var smallestScreenWidthDp: Int32 = 720
    @JavaField("touchscreen") public var touchscreen: Int32 = 3
    @JavaField("uiMode") public var uiMode: Int32 = 17

    @JavaMethod("getLocales", signature: "()Landroid/os/LocaleList;") public func getLocales() -> JavaLocaleList? { JavaLocaleList() }
}

@JavaClass("androidx/core/graphics/Insets")
public final class JavaInsets: JavaObject {
    @JavaField("left") public var left: Int32 = 0
    @JavaField("right") public var right: Int32 = 0
    @JavaField("top") public var top: Int32 = 0
    @JavaField("bottom") public var bottom: Int32 = 0
}

@JavaClass("android/view/Display")
public final class JavaDisplay: JavaObject {
    @JavaMethod("getRefreshRate") public func getRefreshRate() -> Float { 60 }
    @JavaMethod("getAppVsyncOffsetNanos") public func getAppVsyncOffsetNanos() -> Int64 { 0 }
    @JavaMethod("getPresentationDeadlineNanos") public func getPresentationDeadlineNanos() -> Int64 { 11_000_000 }
    @JavaMethod("getDisplayId") public func getDisplayId() -> Int32 { 0 }
    @JavaMethod("getRotation") public func getRotation() -> Int32 { 0 }
    @JavaMethod("getWidth") public func getWidth() -> Int32 { DisplaySize.current.withLock { $0.width } }
    @JavaMethod("getHeight") public func getHeight() -> Int32 { DisplaySize.current.withLock { $0.height } }
    @JavaMethod("isHdr") public func isHdr() -> Bool { false }
    @JavaMethod("isWideColorGamut") public func isWideColorGamut() -> Bool { false }
    @JavaMethod("getName") public func getName() -> String? { "Built-in Screen" }

    @JavaMethod("getMetrics", signature: "(Landroid/util/DisplayMetrics;)V") public func getMetrics(_ metrics: JavaObject?) {
        guard let metrics = metrics as? JavaDisplayMetrics else { return }
        let size = DisplaySize.current.withLock { $0 }
        metrics.widthPixels = size.width
        metrics.heightPixels = size.height
    }

    @JavaMethod("getRealMetrics", signature: "(Landroid/util/DisplayMetrics;)V") public func getRealMetrics(_ metrics: JavaObject?) {
        getMetrics(metrics)
    }

    /// Android lists modes it can switch to; a window has none to offer.
    @JavaMethod("getSupportedModes", signature: "()[Landroid/view/Display$Mode;") public func getSupportedModes() -> JavaObject? {
        JavaRuntime.shared.newObjectArray(elementClass: "android/view/Display$Mode", count: 0)
    }
}

@JavaClass("android/view/WindowManager")
public final class JavaWindowManager: JavaObject {
    private let display = JavaDisplay()
    @JavaMethod("getDefaultDisplay") public func getDefaultDisplay() -> JavaDisplay? { display }
    @JavaMethod("getMaximumWindowMetrics") public func getMaximumWindowMetrics() -> JavaWindowMetrics? { JavaWindowMetrics() }
    @JavaMethod("getCurrentWindowMetrics") public func getCurrentWindowMetrics() -> JavaWindowMetrics? { JavaWindowMetrics() }
}

/// A value several threads read and write.
public final class LockedValue<Value> {
    private var value: Value
    private let mutex: UnsafeMutablePointer<pthread_mutex_t> = {
        let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
        return mutex
    }()

    public init(_ value: Value) { self.value = value }

    public func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return body(&value)
    }
}
