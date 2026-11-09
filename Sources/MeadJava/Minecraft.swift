import Glibc
import MeadJNI

// Minecraft's Java side, as far as a trace of the game has shown it matters:
// the compat profile for one game, kept apart from Android's own classes.
//
// Nothing here answers for a license or an integrity check. Those calls are
// left to fall through to the stand-ins' zeros and falses.

private func memoryBytes(_ name: Int32) -> Int64 {
    Int64(sysconf(name)) * Int64(sysconf(Int32(_SC_PAGESIZE)))
}

/// The host's IPv4 addresses, and where each interface broadcasts.
private func ipv4Interfaces() -> (addresses: [String], broadcasts: [String]) {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return ([], []) }
    defer { freeifaddrs(head) }

    func text(_ address: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let address, Int32(address.pointee.sa_family) == AF_INET else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
            var value = inet.pointee.sin_addr
            return inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
        }
    }

    var addresses: [String] = [], broadcasts: [String] = []
    var at = head
    while let current = at {
        at = current.pointee.ifa_next
        let flags = current.pointee.ifa_flags
        guard flags & 0x8 == 0, flags & 0x1 != 0, let address = text(current.pointee.ifa_addr) else { continue } // up, not loopback
        addresses.append(address)
        if flags & 0x2 != 0, let broadcast = text(current.pointee.ifa_ifu.ifu_broadaddr) {
            broadcasts.append(broadcast)
        }
    }
    return (addresses, broadcasts)
}

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

@JavaClass("com/google/androidgamesdk/gametextinput/InputConnection")
public final class JavaTextInputConnection: JavaObject {
    @JavaMethod("setSoftKeyboardActive") public func setSoftKeyboardActive(_ active: Bool, _ flags: Int32) {}
    @JavaMethod("restartInput") public func restartInput() {}
}

@JavaClass("com/mojang/minecraftpe/NetworkMonitor")
public final class JavaNetworkMonitor: JavaObject {}

@JavaClass("com/mojang/minecraftpe/CrashManager")
public final class JavaCrashManager: JavaObject {}

@JavaClass("com/mojang/minecraftpe/AppExitInfoHelper")
public final class JavaAppExitInfoHelper: JavaObject {
    @JavaMethod("readyForAppExitInfo") public func readyForAppExitInfo() {}
}

@JavaClass("com/mojang/minecraftpe/HardwareInformation")
public final class JavaHardwareInformation: JavaObject {
    @JavaMethod("getDeviceModelName") public func getDeviceModelName() -> String? { JavaBuild.model }
    @JavaMethod("getAndroidVersion") public func getAndroidVersion() -> String? { JavaBuildVersion.release }
    @JavaMethod("getCPUType") public func getCPUType() -> String? { "arm64-v8a" }
    @JavaMethod("getCPUName") public func getCPUName() -> String? { "aarch64" }
    @JavaMethod("getSoCName") public func getSoCName() -> String? { "" }
    @JavaMethod("getCPUFeatures") public func getCPUFeatures() -> String? { "" }
    @JavaMethod("getNumCores") public func getNumCores() -> Int32 { Int32(sysconf(Int32(_SC_NPROCESSORS_ONLN))) }
    @JavaMethod("getPerformanceCoreCount") public func getPerformanceCoreCount() -> Int32 { Int32(sysconf(Int32(_SC_NPROCESSORS_ONLN))) }
    @JavaMethod("getNumClusters") public func getNumClusters() -> Int32 { 1 }
    @JavaMethod("getSerialNumber") public func getSerialNumber() -> String? { "" }
    @JavaMethod("getBoard") public func getBoard() -> String? { JavaBuild.board }
    @JavaMethod("getInstallerPackageName") public func getInstallerPackageName() -> String? { "" }
    @JavaMethod("getSecureId") public func getSecureId() -> String? { "" }
}

@JavaClass("com/mojang/minecraftpe/BatteryMonitor")
public final class JavaBatteryMonitor: JavaObject {
    @JavaMethod("getBatteryLevel") public func getBatteryLevel() -> Int32 { 100 }
    @JavaMethod("getBatteryScale") public func getBatteryScale() -> Int32 { 100 }
    @JavaMethod("getBatteryStatus") public func getBatteryStatus() -> Int32 { 5 } // full
    @JavaMethod("getBatteryTemperature") public func getBatteryTemperature() -> Int32 { 250 }
}

@JavaClass("com/mojang/minecraftpe/ThermalMonitor")
public final class JavaThermalMonitor: JavaObject {
    @JavaMethod("getLowPowerModeEnabled") public func getLowPowerModeEnabled() -> Bool { false }
}

@JavaClass("com/mojang/minecraftpe/DateTimeHelper")
public final class JavaDateTimeHelper: JavaObject {
    @JavaMethod("Is24HourTimeFormat") public static func is24HourTimeFormat() -> Bool { true }
}

extension JavaGameActivity {
    static let inputMethodNone: Int32 = 0
}

@JavaClass("com/mojang/minecraftpe/MainActivity")
public final class JavaMinecraftActivity: JavaGameActivity {
    /// The window's size, set by whatever runs the activity.
    public static var screenWidth: Int32 = 1280
    public static var screenHeight: Int32 = 720

    private let windowManager = JavaWindowManager()
    private let crashManager = JavaCrashManager()
    private let appExitInfo = JavaAppExitInfoHelper()
    private let hardware = JavaHardwareInformation()
    private let battery = JavaBatteryMonitor()
    private let thermal = JavaThermalMonitor()
    private let started = JavaSystem.nanoTime()

    // Natives the game wants run on its main thread. The game passes a closure
    // on its own stack and reads what it wrote as soon as this returns, so the
    // caller has to wait for it, as it would on Android.
    private final class UiCallback {
        let callback: Int64
        var finished = false
        init(_ callback: Int64) { self.callback = callback }
    }

    private let uiLock: UnsafeMutablePointer<pthread_mutex_t> = {
        let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(lock, nil)
        return lock
    }()
    private let uiFinished: UnsafeMutablePointer<pthread_cond_t> = {
        let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
        pthread_cond_init(condition, nil)
        return condition
    }()
    private var uiCallbacks: [UiCallback] = []
    private var uiThread: pthread_t?

    @JavaMethod("runNativeCallbackOnUiThread") public func runNativeCallbackOnUiThread(_ callback: Int64) {
        pthread_mutex_lock(uiLock)
        // With no main thread turning, waiting for one would never end: that
        // thread may itself be waiting for this one, in a lifecycle call.
        guard let uiThread, pthread_equal(uiThread, pthread_self()) == 0 else {
            pthread_mutex_unlock(uiLock)
            runNativeCallback(callback)
            return
        }
        let entry = UiCallback(callback)
        uiCallbacks.append(entry)
        while !entry.finished {
            pthread_cond_wait(uiFinished, uiLock)
        }
        pthread_mutex_unlock(uiLock)
    }

    private func runNativeCallback(_ callback: Int64) {
        var value = jvalue()
        value.j = callback
        JavaRuntime.shared.attachCurrentThread().call("com/mojang/minecraftpe/MainActivity", "nativeRunNativeCallbackOnUiThread", "(J)V", on: self, [value])
    }

    /// The calling thread starts answering callbacks, through `runUiCallbacks`.
    public func beginUiCallbacks() {
        pthread_mutex_lock(uiLock)
        uiThread = pthread_self()
        pthread_mutex_unlock(uiLock)
    }

    /// Runs the callbacks waiting for the main thread, and lets their callers go.
    public func runUiCallbacks() {
        pthread_mutex_lock(uiLock)
        let taken = uiCallbacks
        uiCallbacks.removeAll()
        pthread_mutex_unlock(uiLock)
        guard !taken.isEmpty else { return }
        for entry in taken {
            runNativeCallback(entry.callback)
        }
        pthread_mutex_lock(uiLock)
        for entry in taken {
            entry.finished = true
        }
        pthread_cond_broadcast(uiFinished)
        pthread_mutex_unlock(uiLock)
    }

    /// The main thread stops answering; later callbacks run where they're made.
    public func endUiCallbacks() {
        pthread_mutex_lock(uiLock)
        uiThread = nil
        pthread_mutex_unlock(uiLock)
        runUiCallbacks()
    }

    @JavaMethod("getInternalStoragePath") public func getInternalStoragePath() -> String? { AndroidEnvironment.filesDirectory }
    @JavaMethod("getExternalStoragePath") public func getExternalStoragePath() -> String? { AndroidEnvironment.externalDirectory }
    // There was never an older install: empty is how to say so. Given a path,
    // even one that doesn't exist, the game offers to move its files from it.
    @JavaMethod("getLegacyExternalStoragePath") public func getLegacyExternalStoragePath(_ name: String?) -> String? { "" }
    @JavaMethod("getLegacyDeviceID") public func getLegacyDeviceID() -> String? { "" }
    @JavaMethod("createUUID") public func createUUID() -> String? { JavaUUID.randomUUID()?.javaToString() }
    @JavaMethod("setCachedDeviceId") public func setCachedDeviceId(_ id: String?) {}
    @JavaMethod("initializeCrashManager") public func initializeCrashManager(_ path: String?, _ id: String?) -> JavaCrashManager? { crashManager }
    @JavaMethod("initializeAppExitInfoHelper") public func initializeAppExitInfoHelper() -> JavaAppExitInfoHelper? { appExitInfo }
    @JavaMethod("getScreenWidth") public func getScreenWidth() -> Int32 { Self.screenWidth }
    @JavaMethod("getScreenHeight") public func getScreenHeight() -> Int32 { Self.screenHeight }
    @JavaMethod("getDisplayWidth") public func getDisplayWidth() -> Int32 { Self.screenWidth }
    @JavaMethod("getDisplayHeight") public func getDisplayHeight() -> Int32 { Self.screenHeight }
    @JavaMethod("getAndroidVersion") public func getAndroidVersion() -> Int32 { JavaBuildVersion.sdkInt }
    @JavaMethod("getDeviceModel") public func getDeviceModel() -> String? { JavaBuild.model }
    @JavaMethod("getLocale") public func getLocale() -> String? { "en_US" }
    @JavaMethod("isTablet") public func isTablet() -> Bool { true }
    // A Linux machine with a keyboard and mouse is what Android calls a
    // Chromebook, and the game only takes a mouse from one.
    @JavaMethod("isChromebook") public func isChromebook() -> Bool { true }
    @JavaMethod("hasWriteExternalStoragePermission") public func hasWriteExternalStoragePermission() -> Bool { true }
    @JavaMethod("hasReadMediaImagesPermission") public func hasReadMediaImagesPermission() -> Bool { true }
    @JavaMethod("hasHardwareKeyboard") public func hasHardwareKeyboard() -> Bool { true }
    @JavaMethod("getPlatformDpi") public func getPlatformDpi() -> Int32 { 160 }
    @JavaMethod("getKeyboardHeight") public func getKeyboardHeight() -> Float { 0 }
    @JavaMethod("getTotalMemory") public func getTotalMemory() -> Int64 { memoryBytes(Int32(_SC_PHYS_PAGES)) }
    @JavaMethod("getMemoryLimit") public func getMemoryLimit() -> Int64 { memoryBytes(Int32(_SC_PHYS_PAGES)) }
    @JavaMethod("getFreeMemory") public func getFreeMemory() -> Int64 { memoryBytes(Int32(_SC_AVPHYS_PAGES)) }
    @JavaMethod("getUsedMemory") public func getUsedMemory() -> Int64 { memoryBytes(Int32(_SC_PHYS_PAGES)) - memoryBytes(Int32(_SC_AVPHYS_PAGES)) }
    @JavaMethod("getLowMemoryThreshold") public func getLowMemoryThreshold() -> Int64 { 256 * 1024 * 1024 }
    @JavaMethod("getTimeFromProcessStart") public func getTimeFromProcessStart() -> Int64 { (JavaSystem.nanoTime() - started) / 1_000_000 }
    @JavaMethod("getHardwareInfo") public func getHardwareInfo() -> JavaHardwareInformation? { hardware }
    @JavaMethod("getBatteryMonitor") public func getBatteryMonitor() -> JavaBatteryMonitor? { battery }
    @JavaMethod("getThermalMonitor") public func getThermalMonitor() -> JavaThermalMonitor? { thermal }
    @JavaMethod("getWindowManager") public func getWindowManager() -> JavaWindowManager? { windowManager }
    @JavaMethod("setKeepScreenOnFlag") public func setKeepScreenOnFlag(_ on: Bool) {}
    @JavaMethod("setIsPowerVR") public func setIsPowerVR(_ isPowerVR: Bool) {}
    @JavaMethod("tick") public func tick() {}
    @JavaMethod("vibrate") public func vibrate(_ milliseconds: Int32) {}
    @JavaMethod("quit") public func quit() { exit(0) }
    @JavaMethod("getBroadcastAddresses", signature: "()[Ljava/lang/String;") public func getBroadcastAddresses() -> JavaObject? { JavaRuntime.shared.newStringArray(ipv4Interfaces().broadcasts) }
    @JavaMethod("getIPAddresses", signature: "()[Ljava/lang/String;") public func getIPAddresses() -> JavaObject? { JavaRuntime.shared.newStringArray(ipv4Interfaces().addresses) }
    @JavaMethod("calculateAvailableDiskFreeSpace") public func calculateAvailableDiskFreeSpace(_ path: String?) -> Int64 { 1 << 34 }
}
