import Glibc
import MeadJNI
import MeadJava

// Minecraft's Java side, as far as a trace of the game has shown it matters:
// the compat profile for one game, kept apart from Android's own classes,
// which are MeadJava's.
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

    /// Whether the game wants the pointer captured, as Android's
    /// requestPointerCapture does: hidden, and its movement reported as
    /// movement rather than as a place. Whatever runs the window applies it.
    public static var cursorLocked: Bool {
        get { cursorLockedFlag.withLock { $0 } }
        set { cursorLockedFlag.withLock { $0 = newValue } }
    }
    private static let cursorLockedFlag = LockedValue(false)

    @JavaMethod("lockCursor") public func lockCursor() { Self.cursorLocked = true }
    @JavaMethod("unlockCursor") public func unlockCursor() { Self.cursorLocked = false }

    /// The text box the game has open, through its own keyboard calls rather
    /// than GameActivity's. Whatever runs the window types into it and tells
    /// the game with nativeSetTextboxText and nativeCaretPosition.
    public static let textBox = TextBox()

    @JavaMethod("showKeyboard", signature: "(Ljava/lang/String;IZZZ)V")
    public func showKeyboard(_ text: String?, _ maxLength: Int32, _ limitInput: Bool, _ numbersOnly: Bool, _ multiline: Bool) {
        Self.textBox.open(text: text ?? "", maxLength: Int(maxLength), multiline: multiline)
    }
    @JavaMethod("hideKeyboard") public func hideKeyboard() { Self.textBox.setActive(false) }
    @JavaMethod("getCaretPosition") public func getCaretPosition() -> Int32 { Int32(Self.textBox.current.start) }
    @JavaMethod("setCaretPosition") public func setCaretPosition(_ position: Int32) { Self.textBox.setCaret(Int(position)) }

    /// An image file's pixels, as Minecraft's Java gives them: width, height,
    /// then each pixel as ARGB. Decoded by the game's own stb_image, as
    /// mcpelauncher does; nil for a file that can't be read or decoded.
    @JavaMethod("getImageData", signature: "(Ljava/lang/String;)[I")
    public func getImageData(_ path: String?) -> JavaObject? {
        guard let path else { return nil }
        JavaRuntime.shared.trace("getImageData \(path)")
        guard let data = Self.contents(of: path), !data.isEmpty, let decoder = Self.imageDecoder else { return nil }
        var width: Int32 = 0, height: Int32 = 0, channels: Int32 = 0
        let pixels = data.withUnsafeBufferPointer { bytes in
            decoder.load(bytes.baseAddress!, Int32(bytes.count), &width, &height, &channels, 4)
        }
        guard let pixels else { return nil }
        defer { decoder.free(pixels) }
        let count = Int(width) * Int(height)
        var values = [Int32](repeating: 0, count: 2 + count)
        values[0] = width
        values[1] = height
        for index in 0..<count {
            let r = UInt32(pixels[index * 4]), g = UInt32(pixels[index * 4 + 1])
            let b = UInt32(pixels[index * 4 + 2]), a = UInt32(pixels[index * 4 + 3])
            values[2 + index] = Int32(bitPattern: a << 24 | r << 16 | g << 8 | b)
        }
        return JavaRuntime.shared.newIntArray(values)
    }

    private static func contents(of path: String) -> [UInt8]? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
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

    private typealias ImageLoad = @convention(c) (UnsafePointer<UInt8>, Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                                  UnsafeMutablePointer<Int32>, Int32) -> UnsafeMutablePointer<UInt8>?
    private typealias ImageFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias LoaderSymbol = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UnsafeRawPointer?) -> UnsafeMutableRawPointer?

    /// The game's stb_image, found through Mead's loader, which the mead
    /// executable exports.
    private static let imageDecoder: (load: ImageLoad, free: ImageFree)? = {
        guard let lookup = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "mead_dlsym") else { return nil }
        let find = unsafeBitCast(lookup, to: LoaderSymbol.self)
        guard let load = find(nil, "_ZN6renoir10ThirdParty21stbi_load_from_memoryEPKhiPiS3_S3_i", nil),
              let free = find(nil, "_ZN6renoir10ThirdParty15stbi_image_freeEPv", nil) else { return nil }
        return (unsafeBitCast(load, to: ImageLoad.self), unsafeBitCast(free, to: ImageFree.self))
    }()

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
