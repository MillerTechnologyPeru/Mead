import Glibc
import MeadWindow

/// Input, on the display thread, as Android's input events on the windows'
/// input channels: keys as `KeyEvent`s, and the pointer, touches and
/// gamepads' axes as `MotionEvent`s, with Android's sources, actions and
/// axes. From Wayland's seat (ARTWayland.swift), and from SDL's events:
/// gamepads, and the keys and touches checks inject.
extension ARTDisplay {
    // Android's input constants (android/input.h).
    enum Android {
        static let sourceKeyboard: Int32 = 0x101
        static let sourceMouse: Int32 = 0x2002
        static let sourceTouchscreen: Int32 = 0x1002
        static let sourceGamepad: Int32 = 0x401
        static let sourceJoystick: Int32 = 0x0100_0010

        static let keyDown: Int32 = 0
        static let keyUp: Int32 = 1
        static let flagLongPress: Int32 = 0x80

        static let motionDown: Int32 = 0
        static let motionUp: Int32 = 1
        static let motionMove: Int32 = 2
        static let motionPointerDown: Int32 = 5
        static let motionPointerUp: Int32 = 6
        static let motionHoverMove: Int32 = 7
        static let motionScroll: Int32 = 8
        static let motionButtonPress: Int32 = 11
        static let motionButtonRelease: Int32 = 12

        static let axisX: Int32 = 0
        static let axisY: Int32 = 1
        static let axisPressure: Int32 = 2
        static let axisSize: Int32 = 3
        static let axisVScroll: Int32 = 9
        static let axisHScroll: Int32 = 10

        static let toolFinger: Int32 = 1
        static let toolMouse: Int32 = 3

        static let buttonPrimary: Int32 = 1
        static let buttonSecondary: Int32 = 2
        static let buttonTertiary: Int32 = 4

        // KeyEvent's meta state bits.
        static let metaShift: Int32 = 0x1 | 0x40
        static let metaAlt: Int32 = 0x2 | 0x10
        static let metaCtrl: Int32 = 0x1000 | 0x2000
        static let metaMeta: Int32 = 0x10000 | 0x20000
        static let metaCapsLock: Int32 = 0x100000
        static let metaNumLock: Int32 = 0x200000

        // The input devices' IDs here: one keyboard, one mouse, one
        // touchscreen, and gamepads from gamepadBase on by SDL's ID.
        static let keyboard: Int32 = 1
        static let mouse: Int32 = 2
        static let touchscreen: Int32 = 3
        static let gamepadBase: Int32 = 16
    }

    /// CLOCK_MONOTONIC in nanoseconds: Android's input event times.
    static func now() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    // MARK: Keys

    /// A key, as Android's key code, to a window: a press, a release, or a
    /// repeat of a held key (`repeatCount`, from 1), keeping its down time.
    func deliverKey(_ window: Window, keyCode: Int32, scanCode: Int32, down: Bool, meta: Int32,
                    repeatCount: Int32? = nil) {
        guard let input = window.input, keyCode != 0 else { return }
        let time = Self.now()
        let repeating = down && window.keyDownTimes[keyCode] != nil
        if down, !repeating { window.keyDownTimes[keyCode] = time }
        let downTime = window.keyDownTimes[keyCode] ?? time
        if !down { window.keyDownTimes[keyCode] = nil }
        // A repeat's first is a long press, as Android's dispatcher marks it.
        let flags: Int32 = repeatCount == 1 ? Android.flagLongPress : 0
        _ = functions.sendKey(input, Android.keyboard, Android.sourceKeyboard, down ? Android.keyDown : Android.keyUp, flags,
                              keyCode, scanCode, meta, repeatCount ?? (repeating ? 1 : 0), downTime, time)
    }

    /// Whether a key is a modifier, which doesn't repeat: shift, alt,
    /// control, meta, function and the locks.
    static func isModifier(_ keyCode: Int32) -> Bool {
        [57, 58, 59, 60, 113, 114, 115, 116, 117, 118, 119, 143].contains(keyCode)
    }

    /// A key from Wayland's keyboard: a Linux evdev code, mapped as Android's
    /// input reader maps it, by Generic.kl; xkb's usual modifier bits (shift,
    /// lock, control, mod1 alt, mod2 num lock, mod4 super) as the meta state.
    /// Returns the Android key code.
    @discardableResult
    func waylandKey(_ window: Window, code: UInt32, down: Bool, modifiers: UInt32, locked: UInt32,
                    repeatCount: Int32? = nil) -> Int32 {
        var meta: Int32 = 0
        if modifiers & 0x01 != 0 { meta |= Android.metaShift }
        if modifiers & 0x04 != 0 { meta |= Android.metaCtrl }
        if modifiers & 0x08 != 0 { meta |= Android.metaAlt }
        if modifiers & 0x40 != 0 { meta |= Android.metaMeta }
        if locked & 0x02 != 0 { meta |= Android.metaCapsLock }
        if locked & 0x10 != 0 { meta |= Android.metaNumLock }
        let keyCode = functions.mapKey(Int32(bitPattern: code))
        deliverKey(window, keyCode: keyCode, scanCode: Int32(bitPattern: code), down: down, meta: meta,
                   repeatCount: repeatCount)
        return keyCode
    }

    // MARK: Motion

    /// A pointer of a motion event: its ID, tool and axes.
    struct Pointer {
        var id: Int32
        var tool: Int32
        var axes: [Int32: Float]
    }

    @discardableResult
    func sendMotion(_ window: Window, device: Int32, source: Int32, action: Int32, actionButton: Int32 = 0,
                    buttonState: Int32 = 0, downTime: Int64, pointers: [Pointer]) -> Int32 {
        guard let input = window.input, !pointers.isEmpty else { return -1 }
        let axisCount = 48
        var bits: UInt64 = 0
        var values = [Float](repeating: 0, count: pointers.count * axisCount)
        for (index, pointer) in pointers.enumerated() {
            for (axis, value) in pointer.axes where axis >= 0 && Int(axis) < axisCount {
                bits |= UInt64(1) << UInt64(axis)
                values[index * axisCount + Int(axis)] = value
            }
        }
        let ids = pointers.map(\.id), tools = pointers.map(\.tool)
        return functions.sendMotion(input, device, source, action, actionButton, 0, 0, buttonState, downTime, Self.now(),
                                    UInt32(pointers.count), ids, tools, bits, values)
    }

    private func mousePointer(x: Float, y: Float) -> Pointer {
        Pointer(id: 0, tool: Android.toolMouse, axes: [Android.axisX: x, Android.axisY: y, Android.axisPressure: 1])
    }

    /// A mouse button (Android's), at x, y in the window's pixels.
    func pointerButton(_ window: Window, button: Int32, down: Bool, x: Float, y: Float) {
        guard window.input != nil else { return }
        let pointer = mousePointer(x: x, y: y)
        let time = Self.now()
        if down {
            // As Android's mouse: DOWN with the first button, then
            // BUTTON_PRESS for each.
            let first = window.mouseButtons == 0
            window.mouseButtons |= button
            if first {
                window.mouseDownTime = time
                sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionDown,
                           buttonState: window.mouseButtons, downTime: time, pointers: [pointer])
            }
            sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionButtonPress,
                       actionButton: button, buttonState: window.mouseButtons, downTime: window.mouseDownTime, pointers: [pointer])
        } else {
            window.mouseButtons &= ~button
            sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionButtonRelease,
                       actionButton: button, buttonState: window.mouseButtons, downTime: window.mouseDownTime, pointers: [pointer])
            if window.mouseButtons == 0 {
                sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionUp,
                           downTime: window.mouseDownTime, pointers: [pointer])
            }
        }
    }

    /// The mouse moved to x, y in the window's pixels.
    func pointerMoved(_ window: Window, x: Float, y: Float) {
        guard window.input != nil else { return }
        let pointer = mousePointer(x: x, y: y)
        if window.mouseButtons != 0 {
            sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionMove,
                       buttonState: window.mouseButtons, downTime: window.mouseDownTime, pointers: [pointer])
        } else {
            sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionHoverMove,
                       downTime: Self.now(), pointers: [pointer])
        }
    }

    /// Scrolling at x, y, in notches: up and right positive.
    func pointerScrolled(_ window: Window, x: Float, y: Float, vertical: Float, horizontal: Float) {
        guard window.input != nil else { return }
        var pointer = mousePointer(x: x, y: y)
        pointer.axes[Android.axisVScroll] = vertical
        pointer.axes[Android.axisHScroll] = horizontal
        sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionScroll,
                   buttonState: window.mouseButtons, downTime: Self.now(), pointers: [pointer])
    }

    enum TouchAction { case down, up, move }

    /// A touch, by its source's ID, at x, y in the window's pixels (an up
    /// keeps the touch's last place when it has none).
    func touched(_ window: Window, action touchAction: TouchAction, id source: UInt64, x: Float?, y: Float?,
                 pressure: Float) {
        guard window.input != nil else { return }
        let time = Self.now()
        var action: Int32
        switch touchAction {
        case .down:
            // The lowest pointer ID not in use, as Android numbers them.
            var id: Int32 = 0
            while window.fingers.contains(where: { $0.id == id }) { id += 1 }
            window.fingers.append((source, id, x ?? 0, y ?? 0, pressure))
            let index = Int32(window.fingers.count - 1)
            if window.fingers.count == 1 {
                window.touchDownTime = time
                action = Android.motionDown
            } else {
                action = Android.motionPointerDown | index << 8
            }
        case .up:
            guard let index = window.fingers.firstIndex(where: { $0.source == source }) else { return }
            if let x, let y {
                window.fingers[index].x = x
                window.fingers[index].y = y
            }
            action = window.fingers.count == 1 ? Android.motionUp : Android.motionPointerUp | Int32(index) << 8
        case .move:
            guard let index = window.fingers.firstIndex(where: { $0.source == source }) else { return }
            window.fingers[index].x = x ?? window.fingers[index].x
            window.fingers[index].y = y ?? window.fingers[index].y
            window.fingers[index].pressure = pressure
            action = Android.motionMove
        }
        let pointers = window.fingers.map {
            Pointer(id: $0.id, tool: Android.toolFinger,
                    axes: [Android.axisX: $0.x, Android.axisY: $0.y, Android.axisPressure: $0.pressure > 0 ? $0.pressure : 1,
                           Android.axisSize: 0.1])
        }
        sendMotion(window, device: Android.touchscreen, source: Android.sourceTouchscreen, action: action,
                   downTime: window.touchDownTime, pointers: pointers)
        if touchAction == .up {
            window.fingers.removeAll { $0.source == source }
        }
    }

    // MARK: SDL's events

    /// SDL's events: gamepads, and keys and touches injected for checks (SDL
    /// has no windows here; theirs carry Mead's window IDs).
    func handle(_ event: mead_sdl_event) {
        switch Int(event.type) {
        case MEAD_SDL_EVENT_KEY_DOWN, MEAD_SDL_EVENT_KEY_UP:
            let key = event.key
            guard let window = window(id: key.windowID) ?? inputWindow else { return }
            deliverKey(window, keyCode: androidKeyCode(forScancode: key.scancode), scanCode: Int32(key.scancode),
                       down: key.down, meta: androidMetaState(key.mod))
        case MEAD_SDL_EVENT_FINGER_DOWN, MEAD_SDL_EVENT_FINGER_UP, MEAD_SDL_EVENT_FINGER_MOTION:
            let touch = event.finger
            guard let window = window(id: touch.windowID) ?? inputWindow else { return }
            let action: TouchAction = Int(touch.type) == MEAD_SDL_EVENT_FINGER_DOWN ? .down
                : Int(touch.type) == MEAD_SDL_EVENT_FINGER_UP ? .up : .move
            touched(window, action: action, id: touch.fingerID,
                    x: touch.x * Float(window.width), y: touch.y * Float(window.height), pressure: touch.pressure)
        case MEAD_SDL_EVENT_GAMEPAD_ADDED:
            if gamepads[event.gdevice.which] == nil, let gamepad = SDL.openGamepad(event.gdevice.which) {
                gamepads[event.gdevice.which] = gamepad
            }
        case MEAD_SDL_EVENT_GAMEPAD_REMOVED:
            if let gamepad = gamepads.removeValue(forKey: event.gdevice.which) {
                SDL.closeGamepad(gamepad)
            }
            gamepadAxes[event.gdevice.which] = nil
        case MEAD_SDL_EVENT_GAMEPAD_BUTTON_DOWN, MEAD_SDL_EVENT_GAMEPAD_BUTTON_UP:
            gamepadButton(event.gbutton)
        case MEAD_SDL_EVENT_GAMEPAD_AXIS_MOTION:
            gamepadAxis(event.gaxis)
        default:
            break
        }
    }

    private func gamepadButton(_ button: mead_sdl_gamepad_button_event) {
        guard let window = inputWindow, let input = window.input else { return }
        let code = androidKeyCode(forGamepadButton: button.button)
        guard code != 0 else { return }
        let time = Self.now()
        _ = functions.sendKey(input, Android.gamepadBase + Int32(button.which), Android.sourceGamepad,
                              button.down ? Android.keyDown : Android.keyUp, 0, code, 0, 0, 0, time, time)
    }

    private func gamepadAxis(_ axis: mead_sdl_gamepad_axis_event) {
        guard let window = inputWindow, window.input != nil else { return }
        var axes = gamepadAxes[axis.which] ?? [:]
        let value = androidAxisValue(axis.value)
        for android in androidAxes(forGamepadAxis: axis.axis) {
            axes[android] = value
        }
        gamepadAxes[axis.which] = axes
        sendMotion(window, device: Android.gamepadBase + Int32(axis.which), source: Android.sourceJoystick,
                   action: Android.motionMove, downTime: Self.now(), pointers: [Pointer(id: 0, tool: 0, axes: axes)])
    }
}
