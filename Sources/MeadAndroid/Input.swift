import CMeadAndroid
import Glibc

let AINPUT_EVENT_TYPE_KEY: Int32 = 1
let AINPUT_EVENT_TYPE_MOTION: Int32 = 2
let AINPUT_SOURCE_KEYBOARD: Int32 = 0x101
let AINPUT_SOURCE_TOUCHSCREEN: Int32 = 0x1002
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

    init(type: Int32, source: Int32, action: Int32, eventTime: Int64, downTime: Int64,
         keyCode: Int32 = 0, scanCode: Int32 = 0, repeatCount: Int32 = 0, x: Float = 0, y: Float = 0) {
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
public func AInputEvent_getDeviceId(_ pointer: UnsafeMutableRawPointer) -> Int32 { 1 }

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
public func AMotionEvent_getToolType(_ pointer: UnsafeMutableRawPointer, _ index: Int) -> Int32 { 1 } // finger

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
    switch axis {
    case 0: return event(pointer).x
    case 1: return event(pointer).y
    case 2: return 1
    default: return 0
    }
}

/// SDL's keyboard scancodes as Android's key codes; those Android has.
public func androidKeyCode(forScancode scancode: UInt32) -> Int32 {
    switch scancode {
    case 4...29: return 29 + Int32(scancode - 4) // A to Z
    case 30...38: return 8 + Int32(scancode - 30) // 1 to 9
    case 39: return 7 // 0
    case 40: return 66 // enter
    case 41: return 111 // escape
    case 42: return 67 // backspace is Android's DEL
    case 43: return 61 // tab
    case 44: return 62 // space
    case 45: return 69 // minus
    case 46: return 70 // equals
    case 47: return 71 // left bracket
    case 48: return 72 // right bracket
    case 49: return 73 // backslash
    case 51: return 74 // semicolon
    case 52: return 75 // apostrophe
    case 53: return 68 // grave
    case 54: return 55 // comma
    case 55: return 56 // period
    case 56: return 76 // slash
    case 58...69: return 131 + Int32(scancode - 58) // F1 to F12
    case 74: return 122 // home
    case 75: return 92 // page up
    case 76: return 112 // delete is Android's FORWARD_DEL
    case 77: return 123 // end
    case 78: return 93 // page down
    case 79: return 22 // right
    case 80: return 21 // left
    case 81: return 20 // down
    case 82: return 19 // up
    case 224: return 113 // left control
    case 225: return 59 // left shift
    case 226: return 57 // left alt
    case 228: return 114 // right control
    case 229: return 60 // right shift
    case 230: return 58 // right alt
    default: return 0
    }
}
