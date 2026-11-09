import CMeadWindow
import Glibc
import MeadJava
import MeadWindow

/// SDL's events as GameActivity's: what Android's View would hand its
/// onTouchEvent, onGenericMotionEvent and onKeyDown/onKeyUp.
///
/// The mouse is a mouse, as on a Chromebook: button presses and releases with
/// the buttons held, hover moves, and the wheel scrolling. That is how
/// mcpelauncher feeds Minecraft too. Real touches are fingers, kept apart in
/// Android's multi-pointer way.
final class GameActivityInput {
    private let sendMotion: (JavaMotionEvent) -> Void
    private let sendKey: (JavaKeyEvent) -> Void
    private let clock: () -> Int64

    /// Fingers down, in the order Android lists them: by pointer ID.
    private var touches: [(key: UInt64, pointer: JavaMotionEvent.Pointer)] = []
    private var touchDownTime: Int64 = 0
    private var keyDownTimes: [UInt32: Int64] = [:]
    private var mouseButtons: Int32 = 0
    private var mouseDownTime: Int64 = 0

    init(sendMotion: @escaping (JavaMotionEvent) -> Void, sendKey: @escaping (JavaKeyEvent) -> Void,
         clock: @escaping () -> Int64 = GameActivityInput.uptimeMillis) {
        self.sendMotion = sendMotion
        self.sendKey = sendKey
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
            mouse(JavaMotionEvent.actionHoverMove, x: event.motion.x * scale, y: event.motion.y * scale, time: time)
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
        case MEAD_SDL_EVENT_KEY_DOWN, MEAD_SDL_EVENT_KEY_UP:
            let key = event.key
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

    static func metaState(_ mod: UInt16) -> Int32 {
        let mod = Int(mod)
        var state: Int32 = 0
        if mod & MEAD_SDL_KMOD_LSHIFT != 0 { state |= JavaKeyEvent.metaShiftOn | 0x40 }
        if mod & MEAD_SDL_KMOD_RSHIFT != 0 { state |= JavaKeyEvent.metaShiftOn | 0x80 }
        if mod & MEAD_SDL_KMOD_LALT != 0 { state |= JavaKeyEvent.metaAltOn | 0x10 }
        if mod & MEAD_SDL_KMOD_RALT != 0 { state |= JavaKeyEvent.metaAltOn | 0x20 }
        if mod & MEAD_SDL_KMOD_LCTRL != 0 { state |= JavaKeyEvent.metaCtrlOn | 0x2000 }
        if mod & MEAD_SDL_KMOD_RCTRL != 0 { state |= JavaKeyEvent.metaCtrlOn | 0x4000 }
        if mod & MEAD_SDL_KMOD_LGUI != 0 { state |= JavaKeyEvent.metaMetaOn | 0x20000 }
        if mod & MEAD_SDL_KMOD_RGUI != 0 { state |= JavaKeyEvent.metaMetaOn | 0x40000 }
        if mod & MEAD_SDL_KMOD_CAPS != 0 { state |= JavaKeyEvent.metaCapsLockOn }
        if mod & MEAD_SDL_KMOD_NUM != 0 { state |= JavaKeyEvent.metaNumLockOn }
        return state
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
