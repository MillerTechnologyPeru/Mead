import CMeadAndroid
import Glibc
import MeadWindow

let AINPUT_EVENT_TYPE_KEY: Int32 = 1
let AINPUT_EVENT_TYPE_MOTION: Int32 = 2
let AINPUT_SOURCE_KEYBOARD: Int32 = 0x101
let AINPUT_SOURCE_TOUCHSCREEN: Int32 = 0x1002
let AINPUT_SOURCE_GAMEPAD: Int32 = 0x401
let AINPUT_SOURCE_JOYSTICK: Int32 = 0x0100_0010
let AMOTION_EVENT_AXIS_X: Int32 = 0
let AMOTION_EVENT_AXIS_Y: Int32 = 1
let AMOTION_EVENT_AXIS_Z: Int32 = 11
let AMOTION_EVENT_AXIS_RZ: Int32 = 14
let AMOTION_EVENT_AXIS_LTRIGGER: Int32 = 17
let AMOTION_EVENT_AXIS_RTRIGGER: Int32 = 18
let AMOTION_EVENT_AXIS_GAS: Int32 = 22
let AMOTION_EVENT_AXIS_BRAKE: Int32 = 23
let AKEY_EVENT_ACTION_DOWN: Int32 = 0
let AKEY_EVENT_ACTION_UP: Int32 = 1
let AMOTION_EVENT_ACTION_DOWN: Int32 = 0
let AMOTION_EVENT_ACTION_UP: Int32 = 1
let AMOTION_EVENT_ACTION_MOVE: Int32 = 2

/// An AInputEvent: a key, or a one-finger motion.
public final class InputEvent {
    public let type: Int32
    public let source: Int32
    public let action: Int32
    public let eventTime: Int64
    public let downTime: Int64
    // Keys.
    public let keyCode: Int32
    public let scanCode: Int32
    public let repeatCount: Int32
    // Motion.
    public let x: Float
    public let y: Float
    /// A gamepad's axes, by Android's axis numbers; a finger has only x and y.
    public let axes: [Int32: Float]
    public let deviceId: Int32

    init(type: Int32, source: Int32, action: Int32, eventTime: Int64, downTime: Int64,
         keyCode: Int32 = 0, scanCode: Int32 = 0, repeatCount: Int32 = 0, x: Float = 0, y: Float = 0,
         axes: [Int32: Float] = [:], deviceId: Int32 = 1) {
        self.type = type
        self.source = source
        self.action = action
        self.eventTime = eventTime
        self.downTime = downTime
        self.keyCode = keyCode
        self.scanCode = scanCode
        self.repeatCount = repeatCount
        self.x = x
        self.y = y
        self.axes = axes
        self.deviceId = deviceId
    }
}

/// An AInputQueue: events the window's thread adds and the app's takes.
public final class InputQueue {
    private let lock = Mutex()
    private var events: [InputEvent] = []
    private let readableFD = mead_event_create()
    private var looper: Looper?

    public init() {}

    deinit {
        close(readableFD)
    }

    public func enqueue(_ event: InputEvent) {
        lock.withLock { events.append(event) }
        mead_event_signal(readableFD)
    }

    var hasEvents: Bool {
        lock.withLock { !events.isEmpty }
    }

    func next() -> InputEvent? {
        lock.withLock {
            guard !events.isEmpty else {
                mead_event_drain(readableFD)
                return nil
            }
            let event = events.removeFirst()
            if events.isEmpty {
                mead_event_drain(readableFD)
            }
            return event
        }
    }

    func attach(to looper: Looper, ident: Int32, callback: LooperCallback?, data: UnsafeMutableRawPointer?) {
        self.looper = looper
        _ = looper.addFd(readableFD, ident: ident, events: Int32(MEAD_LOOPER_EVENT_INPUT), callback: callback, data: data)
    }

    func detach() {
        _ = looper?.removeFd(readableFD)
        looper = nil
    }
}

private func queue(_ pointer: UnsafeMutableRawPointer) -> InputQueue {
    Unmanaged<InputQueue>.fromOpaque(pointer).takeUnretainedValue()
}

private func event(_ pointer: UnsafeMutableRawPointer) -> InputEvent {
    Unmanaged<InputEvent>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("AInputQueue_attachLooper")
public func AInputQueue_attachLooper(_ pointer: UnsafeMutableRawPointer, _ looper: UnsafeMutableRawPointer, _ ident: Int32, _ callback: LooperCallback?, _ data: UnsafeMutableRawPointer?) {
    queue(pointer).attach(to: Unmanaged<Looper>.fromOpaque(looper).takeUnretainedValue(), ident: ident, callback: callback, data: data)
}

@_cdecl("AInputQueue_detachLooper")
public func AInputQueue_detachLooper(_ pointer: UnsafeMutableRawPointer) {
    queue(pointer).detach()
}

@_cdecl("AInputQueue_hasEvents")
public func AInputQueue_hasEvents(_ pointer: UnsafeMutableRawPointer) -> Int32 {
    queue(pointer).hasEvents ? 1 : 0
}

@_cdecl("AInputQueue_getEvent")
public func AInputQueue_getEvent(_ pointer: UnsafeMutableRawPointer, _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32 {
    guard let next = queue(pointer).next() else {
        out.pointee = nil
        return -1
    }
    out.pointee = Unmanaged.passRetained(next).toOpaque()
    return 0
}

@_cdecl("AInputQueue_preDispatchEvent")
public func AInputQueue_preDispatchEvent(_ pointer: UnsafeMutableRawPointer, _ event: UnsafeMutableRawPointer) -> Int32 {
    0 // no input method stands between the window and the app
}

@_cdecl("AInputQueue_finishEvent")
public func AInputQueue_finishEvent(_ pointer: UnsafeMutableRawPointer, _ event: UnsafeMutableRawPointer, _ handled: Int32) {
    Unmanaged<InputEvent>.fromOpaque(event).release()
}

@_cdecl("AInputEvent_getType")
public func AInputEvent_getType(_ pointer: UnsafeMutableRawPointer) -> Int32 { event(pointer).type }

@_cdecl("AInputEvent_getDeviceId")
public func AInputEvent_getDeviceId(_ pointer: UnsafeMutableRawPointer) -> Int32 { event(pointer).deviceId }

@_cdecl("AInputEvent_getSource")
public func AInputEvent_getSource(_ pointer: UnsafeMutableRawPointer) -> Int32 { event(pointer).source }

@_cdecl("AKeyEvent_getAction")
public func AKeyEvent_getAction(_ pointer: UnsafeMutableRawPointer) -> Int32 { event(pointer).action }

@_cdecl("AKeyEvent_getFlags")
public func AKeyEvent_getFlags(_ pointer: UnsafeMutableRawPointer) -> Int32 { 0 }

@_cdecl("AKeyEvent_getKeyCode")
public func AKeyEvent_getKeyCode(_ pointer: UnsafeMutableRawPointer) -> Int32 { event(pointer).keyCode }

@_cdecl("AKeyEvent_getScanCode")
public func AKeyEvent_getScanCode(_ pointer: UnsafeMutableRawPointer) -> Int32 { event(pointer).scanCode }

@_cdecl("AKeyEvent_getMetaState")
public func AKeyEvent_getMetaState(_ pointer: UnsafeMutableRawPointer) -> Int32 { 0 }

@_cdecl("AKeyEvent_getRepeatCount")
public func AKeyEvent_getRepeatCount(_ pointer: UnsafeMutableRawPointer) -> Int32 { event(pointer).repeatCount }

@_cdecl("AKeyEvent_getDownTime")
public func AKeyEvent_getDownTime(_ pointer: UnsafeMutableRawPointer) -> Int64 { event(pointer).downTime }

@_cdecl("AKeyEvent_getEventTime")
public func AKeyEvent_getEventTime(_ pointer: UnsafeMutableRawPointer) -> Int64 { event(pointer).eventTime }

@_cdecl("AMotionEvent_getAction")
public func AMotionEvent_getAction(_ pointer: UnsafeMutableRawPointer) -> Int32 { event(pointer).action }

@_cdecl("AMotionEvent_getFlags")
public func AMotionEvent_getFlags(_ pointer: UnsafeMutableRawPointer) -> Int32 { 0 }

@_cdecl("AMotionEvent_getMetaState")
public func AMotionEvent_getMetaState(_ pointer: UnsafeMutableRawPointer) -> Int32 { 0 }

@_cdecl("AMotionEvent_getButtonState")
public func AMotionEvent_getButtonState(_ pointer: UnsafeMutableRawPointer) -> Int32 { 0 }

@_cdecl("AMotionEvent_getEdgeFlags")
public func AMotionEvent_getEdgeFlags(_ pointer: UnsafeMutableRawPointer) -> Int32 { 0 }

@_cdecl("AMotionEvent_getDownTime")
public func AMotionEvent_getDownTime(_ pointer: UnsafeMutableRawPointer) -> Int64 { event(pointer).downTime }

@_cdecl("AMotionEvent_getEventTime")
public func AMotionEvent_getEventTime(_ pointer: UnsafeMutableRawPointer) -> Int64 { event(pointer).eventTime }

@_cdecl("AMotionEvent_getXOffset")
public func AMotionEvent_getXOffset(_ pointer: UnsafeMutableRawPointer) -> Float { 0 }

@_cdecl("AMotionEvent_getYOffset")
public func AMotionEvent_getYOffset(_ pointer: UnsafeMutableRawPointer) -> Float { 0 }

@_cdecl("AMotionEvent_getXPrecision")
public func AMotionEvent_getXPrecision(_ pointer: UnsafeMutableRawPointer) -> Float { 1 }

@_cdecl("AMotionEvent_getYPrecision")
public func AMotionEvent_getYPrecision(_ pointer: UnsafeMutableRawPointer) -> Float { 1 }

@_cdecl("AMotionEvent_getPointerCount")
public func AMotionEvent_getPointerCount(_ pointer: UnsafeMutableRawPointer) -> Int { 1 }

@_cdecl("AMotionEvent_getPointerId")
public func AMotionEvent_getPointerId(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Int32 { 0 }

@_cdecl("AMotionEvent_getToolType")
public func AMotionEvent_getToolType(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Int32 {
    event(pointer).axes.isEmpty ? 1 : 0 // a finger, or nothing that is one
}

@_cdecl("AMotionEvent_getRawX")
public func AMotionEvent_getRawX(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Float { event(pointer).x }

@_cdecl("AMotionEvent_getRawY")
public func AMotionEvent_getRawY(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Float { event(pointer).y }

@_cdecl("AMotionEvent_getX")
public func AMotionEvent_getX(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Float { event(pointer).x }

@_cdecl("AMotionEvent_getY")
public func AMotionEvent_getY(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Float { event(pointer).y }

@_cdecl("AMotionEvent_getPressure")
public func AMotionEvent_getPressure(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Float { 1 }

@_cdecl("AMotionEvent_getSize")
public func AMotionEvent_getSize(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Float { 0 }

@_cdecl("AMotionEvent_getHistorySize")
public func AMotionEvent_getHistorySize(_ pointer: UnsafeMutableRawPointer) -> Int { 0 }

@_cdecl("AMotionEvent_getAxisValue")
public func AMotionEvent_getAxisValue(_ pointer: UnsafeMutableRawPointer, _ axis: Int32, _ index: Int) -> Float {
    if !event(pointer).axes.isEmpty {
        return event(pointer).axes[axis] ?? 0
    }
    switch axis {
    case 0: return event(pointer).x
    case 1: return event(pointer).y
    case 2: return 1
    default: return 0
    }
}
