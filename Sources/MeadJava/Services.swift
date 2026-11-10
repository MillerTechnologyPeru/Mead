import Glibc
import MeadJNI

// Android's system services and resources, as engines read them at start:
// the display's size, the locale, audio's properties, power and input. Each
// answers as a plain desktop would: one display the size of the window, an
// English locale, no input devices of Android's own.

/// The size the game's window is: what the display reports. The runner
/// keeps it current.
public enum DisplaySize {
    public static let current = LockedValue((width: Int32(1280), height: Int32(720)))
}

@JavaClass("android/graphics/Rect")
public final class JavaRect: JavaObject {
    @JavaField("left") public var left: Int32 = 0
    @JavaField("top") public var top: Int32 = 0
    @JavaField("right") public var right: Int32 = 0
    @JavaField("bottom") public var bottom: Int32 = 0

    public init(left: Int32, top: Int32, right: Int32, bottom: Int32) {
        super.init()
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    @JavaMethod public override convenience init() {
        self.init(left: 0, top: 0, right: 0, bottom: 0)
    }

    @JavaMethod("width") public func width() -> Int32 { right - left }
    @JavaMethod("height") public func height() -> Int32 { bottom - top }
}

@JavaClass("android/view/WindowMetrics")
public final class JavaWindowMetrics: JavaObject {
    @JavaMethod("getBounds") public func getBounds() -> JavaRect? {
        let size = DisplaySize.current.withLock { $0 }
        return JavaRect(left: 0, top: 0, right: size.width, bottom: size.height)
    }
}

@JavaClass("android/util/DisplayMetrics")
public final class JavaDisplayMetrics: JavaObject {
    @JavaField("widthPixels") public var widthPixels: Int32 = 0
    @JavaField("heightPixels") public var heightPixels: Int32 = 0
    @JavaField("density") public var density: Float = 1
    @JavaField("densityDpi") public var densityDpi: Int32 = 160
    @JavaField("scaledDensity") public var scaledDensity: Float = 1
    @JavaField("xdpi") public var xdpi: Float = 160
    @JavaField("ydpi") public var ydpi: Float = 160

    @JavaMethod public override init() {
        super.init()
        let size = DisplaySize.current.withLock { $0 }
        widthPixels = size.width
        heightPixels = size.height
    }
}

@JavaClass("android/os/LocaleList")
public final class JavaLocaleList: JavaObject {
    @JavaMethod("get", signature: "(I)Ljava/util/Locale;") public func get(_ index: Int32) -> JavaLocale? {
        index == 0 ? JavaLocale() : nil
    }

    @JavaMethod("size") public func size() -> Int32 { 1 }
    @JavaMethod("isEmpty") public func isEmpty() -> Bool { false }
    @JavaMethod("getDefault") public static func getDefault() -> JavaLocaleList? { JavaLocaleList() }
    @JavaMethod("toLanguageTags") public func toLanguageTags() -> String? { "en-US" }
}

@JavaClass("android/content/res/Resources")
public final class JavaResources: JavaObject {
    @JavaMethod("getConfiguration") public func getConfiguration() -> JavaConfiguration? { JavaConfiguration() }
    @JavaMethod("getDisplayMetrics") public func getDisplayMetrics() -> JavaDisplayMetrics? { JavaDisplayMetrics() }

    /// Resource IDs are the APK's compiled table's, which isn't read: none.
    @JavaMethod("getIdentifier") public func getIdentifier(_ name: String?, _ type: String?, _ package: String?) -> Int32 { 0 }
}

@JavaClass("android/hardware/display/DisplayManager")
public final class JavaDisplayManager: JavaObject {
    @JavaField("DISPLAY_CATEGORY_PRESENTATION", signature: "Ljava/lang/String;")
    public static var presentationCategory: String? = "android.hardware.display.category.PRESENTATION"

    @JavaMethod("getDisplay", signature: "(I)Landroid/view/Display;") public func getDisplay(_ id: Int32) -> JavaDisplay? {
        id == 0 ? JavaDisplay() : nil
    }

    @JavaMethod("getDisplays", signature: "()[Landroid/view/Display;") public func getDisplays() -> JavaObject? {
        let array = JavaRuntime.shared.newObjectArray(elementClass: "android/view/Display", count: 0) as? JavaObjectArray
        array?.elements = [JavaDisplay()]
        return array
    }

    @JavaMethod("registerDisplayListener", signature: "(Landroid/hardware/display/DisplayManager$DisplayListener;Landroid/os/Handler;)V")
    public func registerDisplayListener(_ listener: JavaObject?, _ handler: JavaObject?) {}

    @JavaMethod("unregisterDisplayListener", signature: "(Landroid/hardware/display/DisplayManager$DisplayListener;)V")
    public func unregisterDisplayListener(_ listener: JavaObject?) {}
}

/// Audio as Android reports a typical device's: 48 kHz, 256-frame buffers,
/// focus always granted.
@JavaClass("android/media/AudioManager")
public final class JavaAudioManager: JavaObject {
    @JavaField("STREAM_MUSIC") public static var streamMusic: Int32 = 3
    @JavaField("GET_DEVICES_OUTPUTS") public static var getDevicesOutputs: Int32 = 2
    @JavaField("GET_DEVICES_INPUTS") public static var getDevicesInputs: Int32 = 1
    @JavaField("AUDIOFOCUS_GAIN") public static var audiofocusGain: Int32 = 1
    @JavaField("AUDIOFOCUS_REQUEST_GRANTED") public static var audiofocusRequestGranted: Int32 = 1
    @JavaField("PROPERTY_OUTPUT_SAMPLE_RATE", signature: "Ljava/lang/String;")
    public static var outputSampleRate: String? = "android.media.property.OUTPUT_SAMPLE_RATE"
    @JavaField("PROPERTY_OUTPUT_FRAMES_PER_BUFFER", signature: "Ljava/lang/String;")
    public static var outputFramesPerBuffer: String? = "android.media.property.OUTPUT_FRAMES_PER_BUFFER"

    @JavaMethod("getProperty") public func getProperty(_ name: String?) -> String? {
        switch name {
        case "android.media.property.OUTPUT_SAMPLE_RATE": return "48000"
        case "android.media.property.OUTPUT_FRAMES_PER_BUFFER": return "256"
        default: return nil
        }
    }

    @JavaMethod("getStreamVolume") public func getStreamVolume(_ stream: Int32) -> Int32 { 15 }
    @JavaMethod("getStreamMaxVolume") public func getStreamMaxVolume(_ stream: Int32) -> Int32 { 15 }
    @JavaMethod("getRingerMode") public func getRingerMode() -> Int32 { 2 }  // normal
    @JavaMethod("isMusicActive") public func isMusicActive() -> Bool { false }
    @JavaMethod("isWiredHeadsetOn") public func isWiredHeadsetOn() -> Bool { false }
    @JavaMethod("isBluetoothA2dpOn") public func isBluetoothA2dpOn() -> Bool { false }

    @JavaMethod("getDevices", signature: "(I)[Landroid/media/AudioDeviceInfo;") public func getDevices(_ flags: Int32) -> JavaObject? {
        JavaRuntime.shared.newObjectArray(elementClass: "android/media/AudioDeviceInfo", count: 0)
    }

    @JavaMethod("requestAudioFocus", signature: "(Landroid/media/AudioManager$OnAudioFocusChangeListener;II)I")
    public func requestAudioFocus(_ listener: JavaObject?, _ stream: Int32, _ kind: Int32) -> Int32 { 1 }

    @JavaMethod("abandonAudioFocus", signature: "(Landroid/media/AudioManager$OnAudioFocusChangeListener;)I")
    public func abandonAudioFocus(_ listener: JavaObject?) -> Int32 { 1 }
}

@JavaClass("android/os/PowerManager")
public final class JavaPowerManager: JavaObject {
    @JavaMethod("isSustainedPerformanceModeSupported") public func isSustainedPerformanceModeSupported() -> Bool { false }
    @JavaMethod("isPowerSaveMode") public func isPowerSaveMode() -> Bool { false }
    @JavaMethod("isInteractive") public func isInteractive() -> Bool { true }
    @JavaMethod("getCurrentThermalStatus") public func getCurrentThermalStatus() -> Int32 { 0 }
}

@JavaClass("android/hardware/input/InputManager")
public final class JavaInputManager: JavaObject {
    private static let listenerInterface = "android/hardware/input/InputManager$InputDeviceListener"
    private static let listeners = LockedValue([JavaObject]())

    @JavaMethod("getInputDeviceIds", signature: "()[I") public func getInputDeviceIds() -> JavaObject? {
        JavaInputDevice.getDeviceIds()
    }

    @JavaMethod("getInputDevice", signature: "(I)Landroid/view/InputDevice;") public func getInputDevice(_ id: Int32) -> JavaInputDevice? {
        JavaInputDevice.getDevice(id)
    }

    @JavaMethod("registerInputDeviceListener", signature: "(Landroid/hardware/input/InputManager$InputDeviceListener;Landroid/os/Handler;)V")
    public func registerInputDeviceListener(_ listener: JavaObject?, _ handler: JavaObject?) {
        guard let listener else { return }
        Self.listeners.withLock { $0.append(listener) }
    }

    @JavaMethod("unregisterInputDeviceListener", signature: "(Landroid/hardware/input/InputManager$InputDeviceListener;)V")
    public func unregisterInputDeviceListener(_ listener: JavaObject?) {
        Self.listeners.withLock { $0.removeAll { $0 === listener } }
    }

    /// Tells the listeners, on the main thread, as Android's handler would.
    static func announce(_ method: String, _ id: Int32) {
        let listeners = Self.listeners.withLock { $0 }
        guard !listeners.isEmpty else { return }
        JavaLooper.main.post {
            let thread = JavaRuntime.shared.attachCurrentThread()
            var value = jvalue()
            value.i = id
            for listener in listeners {
                thread.call(listenerInterface, method, "(I)V", on: listener, [value])
            }
        }
    }
}

/// android.view.InputDevice$MotionRange: one axis of a device, and its range.
@JavaClass("android/view/InputDevice$MotionRange")
public final class JavaMotionRange: JavaObject {
    public let axis: Int32
    public let source: Int32
    public let min: Float
    public let max: Float
    public let flat: Float

    public init(axis: Int32, source: Int32, min: Float, max: Float, flat: Float) {
        self.axis = axis
        self.source = source
        self.min = min
        self.max = max
        self.flat = flat
        super.init()
    }

    @JavaMethod("getAxis") public func getAxis() -> Int32 { axis }
    @JavaMethod("getSource") public func getSource() -> Int32 { source }
    @JavaMethod("isFromSource") public func isFromSource(_ source: Int32) -> Bool { self.source & source == source }
    @JavaMethod("getMin") public func getMin() -> Float { min }
    @JavaMethod("getMax") public func getMax() -> Float { max }
    @JavaMethod("getRange") public func getRange() -> Float { max - min }
    @JavaMethod("getFlat") public func getFlat() -> Float { flat }
    @JavaMethod("getFuzz") public func getFuzz() -> Float { 0 }
    @JavaMethod("getResolution") public func getResolution() -> Float { 0 }
}

/// android.view.InputDevice: the host's gamepads, as Android lists them.
/// The keyboard, mouse and touchscreen reach games as events alone.
@JavaClass("android/view/InputDevice")
public final class JavaInputDevice: JavaObject {
    public static let sourceGamepad: Int32 = 0x401
    public static let sourceJoystick: Int32 = 0x0100_0010

    public let id: Int32
    public let name: String
    public let vendorId: Int32
    public let productId: Int32
    public let controllerNumber: Int32
    public let sources: Int32
    public let ranges: [JavaMotionRange]

    /// A gamepad: two sticks and two triggers, under Android's axis numbers.
    public init(gamepadID id: Int32, name: String, vendorId: Int32, productId: Int32, controllerNumber: Int32) {
        self.id = id
        self.name = name
        self.vendorId = vendorId
        self.productId = productId
        self.controllerNumber = controllerNumber
        sources = Self.sourceGamepad | Self.sourceJoystick
        let stick: [Int32] = [0, 1, 11, 14]          // X, Y, Z, RZ
        let trigger: [Int32] = [17, 18, 22, 23]       // LTRIGGER, RTRIGGER, GAS, BRAKE
        ranges = stick.map { JavaMotionRange(axis: $0, source: Self.sourceJoystick, min: -1, max: 1, flat: 0.1) }
            + trigger.map { JavaMotionRange(axis: $0, source: Self.sourceJoystick, min: 0, max: 1, flat: 0) }
        super.init()
    }

    private static let connected = LockedValue([Int32: JavaInputDevice]())

    /// A device plugged in: listed from now on, and announced.
    public static func add(_ device: JavaInputDevice) {
        connected.withLock { $0[device.id] = device }
        JavaInputManager.announce("onInputDeviceAdded", device.id)
    }

    public static func remove(id: Int32) {
        guard connected.withLock({ $0.removeValue(forKey: id) }) != nil else { return }
        JavaInputManager.announce("onInputDeviceRemoved", id)
    }

    @JavaMethod("getDeviceIds", signature: "()[I") public static func getDeviceIds() -> JavaObject? {
        JavaRuntime.shared.newIntArray(connected.withLock { $0.keys.sorted() })
    }

    @JavaMethod("getDevice", signature: "(I)Landroid/view/InputDevice;") public static func getDevice(_ id: Int32) -> JavaInputDevice? {
        connected.withLock { $0[id] }
    }

    @JavaMethod("getId") public func getId() -> Int32 { id }
    @JavaMethod("getName") public func getName() -> String? { name }
    @JavaMethod("getDescriptor") public func getDescriptor() -> String? { "mead-gamepad-\(vendorId)-\(productId)-\(controllerNumber)" }
    @JavaMethod("getVendorId") public func getVendorId() -> Int32 { vendorId }
    @JavaMethod("getProductId") public func getProductId() -> Int32 { productId }
    @JavaMethod("getControllerNumber") public func getControllerNumber() -> Int32 { controllerNumber }
    @JavaMethod("getSources") public func getSources() -> Int32 { sources }
    @JavaMethod("supportsSource") public func supportsSource(_ source: Int32) -> Bool { sources & source == source }
    @JavaMethod("isVirtual") public func isVirtual() -> Bool { false }
    @JavaMethod("isExternal") public func isExternal() -> Bool { true }
    @JavaMethod("isEnabled") public func isEnabled() -> Bool { true }
    @JavaMethod("getKeyboardType") public func getKeyboardType() -> Int32 { 1 }  // non-alphabetic

    @JavaMethod("getMotionRanges", signature: "()Ljava/util/List;") public func getMotionRanges() -> JavaArrayList? {
        let list = JavaArrayList()
        list.elements = ranges
        return list
    }

    @JavaMethod("getMotionRange", signature: "(I)Landroid/view/InputDevice$MotionRange;")
    public func getMotionRange(_ axis: Int32) -> JavaMotionRange? { ranges.first { $0.axis == axis } }

    @JavaMethod("getMotionRange", signature: "(II)Landroid/view/InputDevice$MotionRange;")
    public func getMotionRange(_ axis: Int32, _ source: Int32) -> JavaMotionRange? {
        ranges.first { $0.axis == axis && $0.isFromSource(source) }
    }
}

@JavaClass("android/net/Uri")
public final class JavaUri: JavaObject {
    /// Android's: letters, digits and _-!.~'()* are kept, the rest is
    /// %XX of its UTF-8.
    @JavaMethod("encode", signature: "(Ljava/lang/String;)Ljava/lang/String;") public static func encode(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-!.~'()*".utf8)
        var encoded = ""
        for byte in text.utf8 {
            if kept.contains(byte) {
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                let hex = String(byte, radix: 16, uppercase: true)
                encoded += "%" + (hex.count == 1 ? "0" + hex : hex)
            }
        }
        return encoded
    }
}

/// The activity's window: its flags are the compositor's business here.
@JavaClass("android/view/Window")
public final class JavaWindow: JavaObject {
    @JavaMethod("setFlags") public func setFlags(_ flags: Int32, _ mask: Int32) {}
    @JavaMethod("addFlags") public func addFlags(_ flags: Int32) {}
    @JavaMethod("clearFlags") public func clearFlags(_ flags: Int32) {}
    @JavaMethod("getDecorView", signature: "()Landroid/view/View;") public func getDecorView() -> JavaObject? { nil }
}

/// android.content.SharedPreferences, kept in a file per name under the
/// app's data directory, so what a game saves outlasts the run.
@JavaClass("android/content/SharedPreferences")
public final class JavaSharedPreferences: JavaObject {
    enum Value: Equatable {
        case string(String), int(Int32), long(Int64), float(Float), boolean(Bool)
    }

    let path: String
    private let values: LockedValue<[String: Value]>

    private static let open = LockedValue([String: JavaSharedPreferences]())

    /// The one instance for `name`, as Android hands out.
    public static func named(_ name: String) -> JavaSharedPreferences {
        open.withLock { table in
            if let existing = table[name] { return existing }
            let directory = "\(AndroidEnvironment.dataDirectory)/shared_prefs"
            AndroidEnvironment.makeDirectories(directory)
            let made = JavaSharedPreferences(path: "\(directory)/\(name).prefs")
            table[name] = made
            return made
        }
    }

    init(path: String) {
        self.path = path
        values = LockedValue(Self.read(path))
        super.init()
    }

    // The file: a line per value, "type key value", key and value with
    // \, newline and space escaped.
    private static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case " ": result += "\\s"
            default: result.append(character)
            }
        }
        return result
    }

    private static func unescape(_ text: Substring) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character == "n" ? "\n" : character == "s" ? " " : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func read(_ path: String) -> [String: Value] {
        guard let file = fopen(path, "r") else { return [:] }
        defer { fclose(file) }
        var text = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = fread(&buffer, 1, buffer.count, file)
            if count <= 0 { break }
            text += buffer[0..<count]
        }
        var values: [String: Value] = [:]
        for line in String(decoding: text, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let key = unescape(parts[1])
            let raw = unescape(parts[2])
            switch parts[0] {
            case "s": values[key] = .string(raw)
            case "i": Int32(raw).map { values[key] = .int($0) }
            case "l": Int64(raw).map { values[key] = .long($0) }
            case "f": Float(raw).map { values[key] = .float($0) }
            case "b": values[key] = .boolean(raw == "true")
            default: break
            }
        }
        return values
    }

    func write(_ values: [String: Value]) {
        var text = ""
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let (kind, raw): (String, String)
            switch value {
            case let .string(string): (kind, raw) = ("s", string)
            case let .int(number): (kind, raw) = ("i", String(number))
            case let .long(number): (kind, raw) = ("l", String(number))
            case let .float(number): (kind, raw) = ("f", String(number))
            case let .boolean(flag): (kind, raw) = ("b", flag ? "true" : "false")
            }
            text += "\(kind) \(Self.escape(key)) \(Self.escape(raw))\n"
        }
        let temporary = path + ".new"
        guard let file = fopen(temporary, "w") else { return }
        text.withCString { _ = fputs($0, file) }
        fclose(file)
        rename(temporary, path)
    }

    func apply(_ changes: [String: Value?], clearing: Bool) {
        let updated = values.withLock { current -> [String: Value] in
            if clearing { current.removeAll() }
            for (key, value) in changes { current[key] = value }
            return current
        }
        write(updated)
    }

    private func value(_ key: String?) -> Value? {
        guard let key else { return nil }
        return values.withLock { $0[key] }
    }

    @JavaMethod("contains") public func contains(_ key: String?) -> Bool { value(key) != nil }

    @JavaMethod("getString", signature: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")
    public func getString(_ key: String?, _ fallback: String?) -> String? {
        if case let .string(string)? = value(key) { return string }
        return fallback
    }

    @JavaMethod("getInt") public func getInt(_ key: String?, _ fallback: Int32) -> Int32 {
        if case let .int(number)? = value(key) { return number }
        return fallback
    }

    @JavaMethod("getLong") public func getLong(_ key: String?, _ fallback: Int64) -> Int64 {
        if case let .long(number)? = value(key) { return number }
        return fallback
    }

    @JavaMethod("getFloat") public func getFloat(_ key: String?, _ fallback: Float) -> Float {
        if case let .float(number)? = value(key) { return number }
        return fallback
    }

    @JavaMethod("getBoolean") public func getBoolean(_ key: String?, _ fallback: Bool) -> Bool {
        if case let .boolean(flag)? = value(key) { return flag }
        return fallback
    }

    @JavaMethod("getAll", signature: "()Ljava/util/Map;") public func getAll() -> JavaHashMap? {
        let map = JavaHashMap()
        for (key, value) in values.withLock({ $0 }) {
            let boxed: JavaObject
            switch value {
            case let .string(string): boxed = JavaString(string)
            case let .int(number): boxed = JavaInteger(value: number)
            case let .long(number): boxed = JavaLong(value: number)
            case let .float(number): boxed = JavaFloat(value: number)
            case let .boolean(flag): boxed = JavaBoolean(value: flag)
            }
            _ = map.put(JavaString(key), boxed)
        }
        return map
    }

    @JavaMethod("edit", signature: "()Landroid/content/SharedPreferences$Editor;")
    public func edit() -> JavaSharedPreferencesEditor? { JavaSharedPreferencesEditor(preferences: self) }
}

@JavaClass("android/content/SharedPreferences$Editor")
public final class JavaSharedPreferencesEditor: JavaObject {
    let preferences: JavaSharedPreferences
    private var changes: [String: JavaSharedPreferences.Value?] = [:]
    private var clearing = false

    init(preferences: JavaSharedPreferences) {
        self.preferences = preferences
        super.init()
    }

    private func put(_ key: String?, _ value: JavaSharedPreferences.Value?) -> JavaSharedPreferencesEditor? {
        if let key { changes[key] = .some(value) }
        return self
    }

    @JavaMethod("putString", signature: "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;")
    public func putString(_ key: String?, _ value: String?) -> JavaSharedPreferencesEditor? { put(key, value.map { .string($0) }) }

    @JavaMethod("putInt", signature: "(Ljava/lang/String;I)Landroid/content/SharedPreferences$Editor;")
    public func putInt(_ key: String?, _ value: Int32) -> JavaSharedPreferencesEditor? { put(key, .int(value)) }

    @JavaMethod("putLong", signature: "(Ljava/lang/String;J)Landroid/content/SharedPreferences$Editor;")
    public func putLong(_ key: String?, _ value: Int64) -> JavaSharedPreferencesEditor? { put(key, .long(value)) }

    @JavaMethod("putFloat", signature: "(Ljava/lang/String;F)Landroid/content/SharedPreferences$Editor;")
    public func putFloat(_ key: String?, _ value: Float) -> JavaSharedPreferencesEditor? { put(key, .float(value)) }

    @JavaMethod("putBoolean", signature: "(Ljava/lang/String;Z)Landroid/content/SharedPreferences$Editor;")
    public func putBoolean(_ key: String?, _ value: Bool) -> JavaSharedPreferencesEditor? { put(key, .boolean(value)) }

    @JavaMethod("remove", signature: "(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;")
    public func remove(_ key: String?) -> JavaSharedPreferencesEditor? { put(key, nil) }

    @JavaMethod("clear", signature: "()Landroid/content/SharedPreferences$Editor;")
    public func clear() -> JavaSharedPreferencesEditor? {
        clearing = true
        changes.removeAll()
        return self
    }

    @JavaMethod("apply") public func apply() {
        preferences.apply(changes, clearing: clearing)
        changes.removeAll()
        clearing = false
    }

    @JavaMethod("commit") public func commit() -> Bool {
        apply()
        return true
    }
}

/// Sensors are the native ASensorManager's here; Java's has none to give.
@JavaClass("android/hardware/SensorManager")
public final class JavaSensorManager: JavaObject {
    @JavaMethod("getDefaultSensor", signature: "(I)Landroid/hardware/Sensor;") public func getDefaultSensor(_ type: Int32) -> JavaObject? { nil }

    @JavaMethod("getSensorList", signature: "(I)Ljava/util/List;") public func getSensorList(_ type: Int32) -> JavaArrayList? { JavaArrayList() }
}

@JavaClass("android/os/Vibrator")
public final class JavaVibrator: JavaObject {
    @JavaMethod("hasVibrator") public func hasVibrator() -> Bool { false }
    @JavaMethod("hasAmplitudeControl") public func hasAmplitudeControl() -> Bool { false }
    @JavaMethod("vibrate", signature: "(J)V") public func vibrate(_ milliseconds: Int64) {}
    @JavaMethod("cancel") public func cancel() {}
}
