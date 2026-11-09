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
}

@JavaClass("android/view/WindowManager")
public final class JavaWindowManager: JavaObject {
    private let display = JavaDisplay()
    @JavaMethod("getDefaultDisplay") public func getDefaultDisplay() -> JavaDisplay? { display }
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
