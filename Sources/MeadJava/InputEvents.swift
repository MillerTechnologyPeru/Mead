import MeadJNI

// android.view.MotionEvent and KeyEvent: what GameActivity reads an input
// event from. Android's own objects are filled in by its input system; these
// are filled in by whatever turns the host's events into Android's.

@JavaClass("android/view/MotionEvent")
public final class JavaMotionEvent: JavaObject {
    public static let actionDown: Int32 = 0
    public static let actionUp: Int32 = 1
    public static let actionMove: Int32 = 2
    public static let actionCancel: Int32 = 3
    public static let actionPointerDown: Int32 = 5
    public static let actionPointerUp: Int32 = 6
    public static let actionHoverMove: Int32 = 7
    public static let actionScroll: Int32 = 8
    public static let actionButtonPress: Int32 = 11
    public static let actionButtonRelease: Int32 = 12
    public static let buttonPrimary: Int32 = 1
    public static let buttonSecondary: Int32 = 2
    public static let buttonTertiary: Int32 = 4
    public static let axisX: Int32 = 0
    public static let axisY: Int32 = 1
    public static let axisPressure: Int32 = 2
    public static let axisVerticalScroll: Int32 = 9
    public static let axisHorizontalScroll: Int32 = 10
    public static let toolTypeFinger: Int32 = 1
    public static let toolTypeMouse: Int32 = 3
    public static let sourceTouchscreen: Int32 = 0x1002
    public static let sourceMouse: Int32 = 0x2002

    public struct Pointer {
        public let id: Int32
        public let toolType: Int32
        public let x: Float
        public let y: Float
        /// Axes other than x and y, by Android's numbers.
        public let axes: [Int32: Float]

        public init(id: Int32, toolType: Int32, x: Float, y: Float, axes: [Int32: Float] = [:]) {
            self.id = id
            self.toolType = toolType
            self.x = x
            self.y = y
            self.axes = axes
        }
    }

    public let action: Int32
    public let source: Int32
    public let deviceId: Int32
    public let eventTime: Int64
    public let downTime: Int64
    public let metaState: Int32
    public let buttonState: Int32
    public let actionButton: Int32
    public let pointers: [Pointer]

    public init(action: Int32, source: Int32, deviceId: Int32 = 1, eventTime: Int64, downTime: Int64,
                metaState: Int32 = 0, buttonState: Int32 = 0, actionButton: Int32 = 0, pointers: [Pointer]) {
        self.action = action
        self.source = source
        self.deviceId = deviceId
        self.eventTime = eventTime
        self.downTime = downTime
        self.metaState = metaState
        self.buttonState = buttonState
        self.actionButton = actionButton
        self.pointers = pointers
        super.init()
    }

    private func pointer(_ index: Int32) -> Pointer? {
        index >= 0 && Int(index) < pointers.count ? pointers[Int(index)] : nil
    }

    @JavaMethod("getAction") public func getAction() -> Int32 { action }
    @JavaMethod("getActionButton") public func getActionButton() -> Int32 { actionButton }
    @JavaMethod("getButtonState") public func getButtonState() -> Int32 { buttonState }
    @JavaMethod("getClassification") public func getClassification() -> Int32 { 0 }
    @JavaMethod("getDeviceId") public func getDeviceId() -> Int32 { deviceId }
    @JavaMethod("getSource") public func getSource() -> Int32 { source }
    @JavaMethod("getDownTime") public func getDownTime() -> Int64 { downTime }
    @JavaMethod("getEventTime") public func getEventTime() -> Int64 { eventTime }
    @JavaMethod("getEdgeFlags") public func getEdgeFlags() -> Int32 { 0 }
    @JavaMethod("getFlags") public func getFlags() -> Int32 { 0 }
    @JavaMethod("getMetaState") public func getMetaState() -> Int32 { metaState }
    @JavaMethod("getPointerCount") public func getPointerCount() -> Int32 { Int32(pointers.count) }
    @JavaMethod("getHistorySize") public func getHistorySize() -> Int32 { 0 }
    @JavaMethod("getXPrecision") public func getXPrecision() -> Float { 1 }
    @JavaMethod("getYPrecision") public func getYPrecision() -> Float { 1 }
    @JavaMethod("getPointerId") public func getPointerId(_ index: Int32) -> Int32 { pointer(index)?.id ?? -1 }
    @JavaMethod("getToolType") public func getToolType(_ index: Int32) -> Int32 { pointer(index)?.toolType ?? 0 }
    @JavaMethod("getRawX") public func getRawX(_ index: Int32) -> Float { pointer(index)?.x ?? 0 }
    @JavaMethod("getRawY") public func getRawY(_ index: Int32) -> Float { pointer(index)?.y ?? 0 }

    @JavaMethod("getAxisValue") public func getAxisValue(_ axis: Int32, _ index: Int32) -> Float {
        guard let pointer = pointer(index) else { return 0 }
        switch axis {
        case Self.axisX: return pointer.x
        case Self.axisY: return pointer.y
        case Self.axisPressure: return pointer.axes[axis] ?? 1
        default: return pointer.axes[axis] ?? 0
        }
    }

    // No history: every host event becomes an event of its own.
    @JavaMethod("getHistoricalAxisValue") public func getHistoricalAxisValue(_ axis: Int32, _ index: Int32, _ position: Int32) -> Float {
        getAxisValue(axis, index)
    }

    @JavaMethod("getHistoricalEventTime") public func getHistoricalEventTime(_ position: Int32) -> Int64 { eventTime }
}

@JavaClass("android/view/KeyEvent")
public final class JavaKeyEvent: JavaObject {
    public static let actionDown: Int32 = 0
    public static let actionUp: Int32 = 1
    public static let sourceKeyboard: Int32 = 0x101
    public static let metaShiftOn: Int32 = 0x1
    public static let metaAltOn: Int32 = 0x2
    public static let metaCtrlOn: Int32 = 0x1000
    public static let metaMetaOn: Int32 = 0x10000
    public static let metaCapsLockOn: Int32 = 0x100000
    public static let metaNumLockOn: Int32 = 0x200000
    /// What getModifiers keeps of the meta state: the keys held, not the locks.
    static let modifierMask: Int32 = 0x77ff7

    public let action: Int32
    public let keyCode: Int32
    public let scanCode: Int32
    public let metaState: Int32
    public let repeatCount: Int32
    public let unicodeChar: Int32
    public let eventTime: Int64
    public let downTime: Int64
    public let source: Int32
    public let deviceId: Int32

    public init(action: Int32, keyCode: Int32, scanCode: Int32, metaState: Int32, repeatCount: Int32, unicodeChar: Int32,
                eventTime: Int64, downTime: Int64, source: Int32 = JavaKeyEvent.sourceKeyboard, deviceId: Int32 = 1) {
        self.action = action
        self.keyCode = keyCode
        self.scanCode = scanCode
        self.metaState = metaState
        self.repeatCount = repeatCount
        self.unicodeChar = unicodeChar
        self.eventTime = eventTime
        self.downTime = downTime
        self.source = source
        self.deviceId = deviceId
        super.init()
    }

    @JavaMethod("getAction") public func getAction() -> Int32 { action }
    @JavaMethod("getKeyCode") public func getKeyCode() -> Int32 { keyCode }
    @JavaMethod("getScanCode") public func getScanCode() -> Int32 { scanCode }
    @JavaMethod("getMetaState") public func getMetaState() -> Int32 { metaState }
    @JavaMethod("getModifiers") public func getModifiers() -> Int32 { metaState & Self.modifierMask }
    @JavaMethod("getRepeatCount") public func getRepeatCount() -> Int32 { repeatCount }
    @JavaMethod("getUnicodeChar") public func getUnicodeChar() -> Int32 { unicodeChar }
    @JavaMethod("getEventTime") public func getEventTime() -> Int64 { eventTime }
    @JavaMethod("getDownTime") public func getDownTime() -> Int64 { downTime }
    @JavaMethod("getFlags") public func getFlags() -> Int32 { 0 }
    @JavaMethod("getSource") public func getSource() -> Int32 { source }
    @JavaMethod("getDeviceId") public func getDeviceId() -> Int32 { deviceId }
}
