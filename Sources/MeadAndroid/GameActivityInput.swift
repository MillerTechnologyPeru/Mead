import CMeadWindow
import Glibc
import MeadJava
import MeadWindow

/// SDL's events as GameActivity's: what Android's View would hand its
/// onTouchEvent, onGenericMotionEvent and onKeyDown/onKeyUp.
///
/// The mouse is a mouse, as on a Chromebook: button presses and releases with
/// the buttons held, hover moves, and the wheel scrolling; while the game has
/// it captured, moves are movement. That is how mcpelauncher feeds Minecraft too. Real touches are fingers, kept apart in
/// Android's multi-pointer way.
final class GameActivityInput {
    private let sendMotion: (JavaMotionEvent) -> Void
    private let sendKey: (JavaKeyEvent) -> Void
    private let editText: (TextEdit) -> Void
    private let clock: () -> Int64
    /// Set while the game has a text box open: typing then edits its text,
    /// as Android's keyboard would, instead of arriving as key presses.
    var textInputActive = false
    /// Set when the open box takes Enter as "done", as an Android text field
    /// does, rather than leaving it a key press.
    var textInputTakesReturn = false

    /// Fingers down, in the order Android lists them: by pointer ID.
    private var touches: [(key: UInt64, pointer: JavaMotionEvent.Pointer)] = []
    private var touchDownTime: Int64 = 0
    private var keyDownTimes: [UInt32: Int64] = [:]
    /// Set while the game has the pointer captured: motion then goes as
    /// movement, from the relative mouse, as Android delivers captured events.
    var pointerCaptured = false
    private var mouseButtons: Int32 = 0
    private var mouseDownTime: Int64 = 0
    /// Set for a game made for touch, with no mouse of its own: the left
    /// button is a finger, and moving with it held drags that finger.
    var mouseIsFinger = false
    private var mouseFingerDown = false
    /// The finger the mouse plays, apart from any real finger's ID.
    private static let mouseFinger = UInt64.max
    /// SDL_TOUCH_MOUSEID: a mouse event SDL made up from a real touch, which
    /// has arrived already as a finger event of its own.
    private static let touchMouse = UInt32.max

    init(sendMotion: @escaping (JavaMotionEvent) -> Void, sendKey: @escaping (JavaKeyEvent) -> Void,
         editText: @escaping (TextEdit) -> Void = { _ in }, clock: @escaping () -> Int64 = GameActivityInput.uptimeMillis) {
        self.sendMotion = sendMotion
        self.sendKey = sendKey
        self.editText = editText
        self.clock = clock
    }

    /// Android's SystemClock.uptimeMillis, which event times are in: the
    /// monotonic clock. SDL's timestamps count from when SDL started instead.
    static func uptimeMillis() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        return Int64(now.tv_sec) * 1000 + Int64(now.tv_nsec) / 1_000_000
    }

    /// Mouse positions come in SDL's points and leave in pixels, as Android's
    /// are; fingers come in the window's 0-to-1 range.
    func handle(_ event: mead_sdl_event, windowWidth: Float, windowHeight: Float, pixelsPerPoint scale: Float = 1) {
        // Handled as they arrive, so the time they arrive is the time they happened.
        let time = clock()
        if mouseIsFinger, mouseAsFinger(event, pixelsPerPoint: scale, time: time) { return }
        switch Int(event.type) {
        case MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN, MEAD_SDL_EVENT_MOUSE_BUTTON_UP:
            let button = event.button
            let android: Int32
            switch Int(button.button) {
            case MEAD_SDL_BUTTON_LEFT: android = JavaMotionEvent.buttonPrimary
            case MEAD_SDL_BUTTON_RIGHT: android = JavaMotionEvent.buttonSecondary
            case MEAD_SDL_BUTTON_MIDDLE: android = JavaMotionEvent.buttonTertiary
            default: return
            }
            if button.down {
                if mouseButtons == 0 { mouseDownTime = time }
                mouseButtons |= android
            } else {
                mouseButtons &= ~android
            }
            mouse(button.down ? JavaMotionEvent.actionButtonPress : JavaMotionEvent.actionButtonRelease, x: button.x * scale, y: button.y * scale,
                  time: time, actionButton: android)
        case MEAD_SDL_EVENT_MOUSE_MOTION:
            if pointerCaptured {
                sendMotion(JavaMotionEvent(action: JavaMotionEvent.actionHoverMove, source: JavaMotionEvent.sourceMouseRelative,
                                           eventTime: time, downTime: time, buttonState: mouseButtons,
                                           pointers: [JavaMotionEvent.Pointer(id: 0, toolType: JavaMotionEvent.toolTypeMouse,
                                                                              x: event.motion.xrel * scale, y: event.motion.yrel * scale)]))
            } else {
                mouse(JavaMotionEvent.actionHoverMove, x: event.motion.x * scale, y: event.motion.y * scale, time: time)
            }
        case MEAD_SDL_EVENT_MOUSE_WHEEL:
            let wheel = event.wheel
            let flip: Float = wheel.direction == UInt32(MEAD_SDL_MOUSEWHEEL_FLIPPED) ? -1 : 1
            let pointer = JavaMotionEvent.Pointer(id: 0, toolType: JavaMotionEvent.toolTypeMouse, x: wheel.mouse_x * scale, y: wheel.mouse_y * scale,
                                                  axes: [JavaMotionEvent.axisVerticalScroll: wheel.y * flip,
                                                         JavaMotionEvent.axisHorizontalScroll: wheel.x * flip])
            sendMotion(JavaMotionEvent(action: JavaMotionEvent.actionScroll, source: JavaMotionEvent.sourceMouse,
                                       eventTime: time, downTime: time, buttonState: mouseButtons, pointers: [pointer]))
        case MEAD_SDL_EVENT_FINGER_DOWN, MEAD_SDL_EVENT_FINGER_UP, MEAD_SDL_EVENT_FINGER_MOTION:
            // Fingers come in the window's 0-to-1 range.
            let finger = event.finger
            touch(key: finger.fingerID, down: Int(event.type) == MEAD_SDL_EVENT_FINGER_DOWN, up: Int(event.type) == MEAD_SDL_EVENT_FINGER_UP,
                  x: finger.x * windowWidth, y: finger.y * windowHeight, time: time)
        case MEAD_SDL_EVENT_TEXT_INPUT:
            if textInputActive, let text = event.text.text {
                editText(.insert(String(cString: text)))
            }
        case MEAD_SDL_EVENT_KEY_DOWN, MEAD_SDL_EVENT_KEY_UP:
            let key = event.key
            if textInputActive, textInputTakesReturn, key.scancode == 40 || key.scancode == 88 {  // Enter, keypad Enter
                if key.down { editText(.submit) }
                return
            }
            if textInputActive, let edit = Self.textEdit(scancode: key.scancode, typed: key.key, mod: key.mod) {
                // A keyboard's own work: the game hears the result, not the key.
                if key.down, let edit = edit { editText(edit) }
                return
            }
            let code = androidKeyCode(forScancode: key.scancode)
            guard code != 0 else { break }
            if key.down, !key.repeat { keyDownTimes[key.scancode] = time }
            let downTime = keyDownTimes[key.scancode] ?? time
            if !key.down { keyDownTimes[key.scancode] = nil }
            sendKey(JavaKeyEvent(action: key.down ? JavaKeyEvent.actionDown : JavaKeyEvent.actionUp, keyCode: code,
                                 scanCode: Int32(key.scancode), metaState: Self.metaState(key.mod), repeatCount: key.repeat ? 1 : 0,
                                 unicodeChar: Self.character(key.key, mod: key.mod), eventTime: time, downTime: downTime))
        default:
            break
        }
    }

    /// Handles `event` if it's the mouse's, as a finger: true if it was.
    private func mouseAsFinger(_ event: mead_sdl_event, pixelsPerPoint scale: Float, time: Int64) -> Bool {
        switch Int(event.type) {
        case MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN, MEAD_SDL_EVENT_MOUSE_BUTTON_UP:
            let button = event.button
            guard button.which != Self.touchMouse, Int(button.button) == MEAD_SDL_BUTTON_LEFT else { return true }
            mouseFingerDown = button.down
            touch(key: Self.mouseFinger, down: button.down, up: !button.down, x: button.x * scale, y: button.y * scale, time: time)
            return true
        case MEAD_SDL_EVENT_MOUSE_MOTION:
            let motion = event.motion
            if motion.which != Self.touchMouse, mouseFingerDown {
                touch(key: Self.mouseFinger, down: false, up: false, x: motion.x * scale, y: motion.y * scale, time: time)
            }
            return true
        default:
            return false
        }
    }

    private func mouse(_ action: Int32, x: Float, y: Float, time: Int64, actionButton: Int32 = 0) {
        sendMotion(JavaMotionEvent(action: action, source: JavaMotionEvent.sourceMouse, eventTime: time,
                                   downTime: mouseButtons != 0 || actionButton != 0 ? mouseDownTime : time,
                                   buttonState: mouseButtons, actionButton: actionButton,
                                   pointers: [JavaMotionEvent.Pointer(id: 0, toolType: JavaMotionEvent.toolTypeMouse, x: x, y: y)]))
    }

    private func touch(key: UInt64, down: Bool, up: Bool, x: Float, y: Float, time: Int64) {
        var index = touches.firstIndex { $0.key == key }
        if down, index == nil {
            // The lowest pointer ID not in use, as Android picks them.
            var id: Int32 = 0
            while touches.contains(where: { $0.pointer.id == id }) { id += 1 }
            if touches.isEmpty { touchDownTime = time }
            touches.append((key, JavaMotionEvent.Pointer(id: id, toolType: JavaMotionEvent.toolTypeFinger, x: x, y: y)))
            touches.sort { $0.pointer.id < $1.pointer.id }
            index = touches.firstIndex { $0.key == key }
        }
        guard let index else { return }
        let old = touches[index].pointer
        touches[index].pointer = JavaMotionEvent.Pointer(id: old.id, toolType: old.toolType, x: x, y: y)
        let action: Int32
        if down {
            action = touches.count == 1 ? JavaMotionEvent.actionDown : JavaMotionEvent.actionPointerDown | Int32(index) << 8
        } else if up {
            action = touches.count == 1 ? JavaMotionEvent.actionUp : JavaMotionEvent.actionPointerUp | Int32(index) << 8
        } else {
            action = JavaMotionEvent.actionMove
        }
        sendMotion(JavaMotionEvent(action: action, source: JavaMotionEvent.sourceTouchscreen, eventTime: time, downTime: touchDownTime,
                                   pointers: touches.map(\.pointer)))
        if up { touches.remove(at: index) }
    }

    /// While a text box is open, what a key does to its text: an edit, nil
    /// inside for a key whose typing arrives as text input, or nil outright
    /// for a key that stays a key press (Enter, Escape, Tab, function keys).
    static func textEdit(scancode: UInt32, typed: UInt32, mod: UInt16) -> TextEdit?? {
        switch scancode {
        case 42: return .some(.deleteBackward)  // Backspace
        case 76: return .some(.deleteForward)   // Delete
        case 80: return .some(.moveLeft)
        case 79: return .some(.moveRight)
        case 74: return .some(.moveToStart)     // Home
        case 77: return .some(.moveToEnd)       // End
        default:
            let control = Int(mod) & (MEAD_SDL_KMOD_LCTRL | MEAD_SDL_KMOD_RCTRL | MEAD_SDL_KMOD_LGUI | MEAD_SDL_KMOD_RGUI) != 0
            return typed >= 0x20 && typed < 0x7f && !control ? .some(nil) : nil
        }
    }

    static func metaState(_ mod: UInt16) -> Int32 {
        androidMetaState(mod)
    }

    /// The character a key types, as KeyEvent.getUnicodeChar has it, from SDL's
    /// key code: printable ASCII, letters shifted by shift and caps lock.
    static func character(_ key: UInt32, mod: UInt16) -> Int32 {
        guard key >= 0x20, key < 0x7f else { return 0 }
        let shifted = Int(mod) & (MEAD_SDL_KMOD_LSHIFT | MEAD_SDL_KMOD_RSHIFT) != 0
        let capsLock = Int(mod) & MEAD_SDL_KMOD_CAPS != 0
        if key >= 0x61, key <= 0x7a, shifted != capsLock { return Int32(key) - 0x20 }
        if shifted, let index = Array("`1234567890-=[]\\;',./".utf8).firstIndex(of: UInt8(key)) {
            return Int32(Array("~!@#$%^&*()_+{}|:\"<>?".utf8)[index])
        }
        return Int32(key)
    }
}
