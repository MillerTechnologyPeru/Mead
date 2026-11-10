import Glibc
import MeadWindow

/// SDL's events, on the display thread, as Android's input events on the
/// windows' input channels: keys as `KeyEvent`s, and the mouse, touches and
/// gamepads' axes as `MotionEvent`s, with Android's sources, actions and
/// axes.
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

    func handle(_ event: mead_sdl_event) {
        switch Int(event.type) {
        case MEAD_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            if let window = window(id: event.window.windowID) { resized(window) }
        case MEAD_SDL_EVENT_WINDOW_FOCUS_GAINED:
            focusedWindowID = event.window.windowID
        case MEAD_SDL_EVENT_KEY_DOWN, MEAD_SDL_EVENT_KEY_UP:
            key(event.key)
        case MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN, MEAD_SDL_EVENT_MOUSE_BUTTON_UP:
            mouseButton(event.button)
        case MEAD_SDL_EVENT_MOUSE_MOTION:
            mouseMotion(event.motion)
        case MEAD_SDL_EVENT_MOUSE_WHEEL:
            mouseWheel(event.wheel)
        case MEAD_SDL_EVENT_FINGER_DOWN, MEAD_SDL_EVENT_FINGER_UP, MEAD_SDL_EVENT_FINGER_MOTION:
            finger(event.finger)
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

    // MARK: Keys

    private func key(_ key: mead_sdl_keyboard_event) {
        guard let window = window(id: key.windowID) ?? inputWindow, let input = window.input else { return }
        let code = androidKeyCode(forScancode: key.scancode)
        guard code != 0 else { return }
        let time = Self.now()
        if key.down, !key.repeat { window.keyDownTimes[key.scancode] = time }
        let downTime = window.keyDownTimes[key.scancode] ?? time
        if !key.down { window.keyDownTimes[key.scancode] = nil }
        _ = functions.sendKey(input, Android.keyboard, Android.sourceKeyboard, key.down ? Android.keyDown : Android.keyUp, 0,
                              code, Int32(key.scancode), androidMetaState(key.mod), key.repeat ? 1 : 0, downTime, time)
    }

    private func gamepadButton(_ button: mead_sdl_gamepad_button_event) {
        guard let window = inputWindow, let input = window.input else { return }
        let code = androidKeyCode(forGamepadButton: button.button)
        guard code != 0 else { return }
        let time = Self.now()
        _ = functions.sendKey(input, Android.gamepadBase + Int32(button.which), Android.sourceGamepad,
                              button.down ? Android.keyDown : Android.keyUp, 0, code, 0, 0, 0, time, time)
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

    private func mousePointer(_ window: Window, x: Float, y: Float) -> Pointer {
        Pointer(id: 0, tool: Android.toolMouse,
                axes: [Android.axisX: x * window.pixelsPerPoint, Android.axisY: y * window.pixelsPerPoint, Android.axisPressure: 1])
    }

    private func mouseButton(_ button: mead_sdl_mouse_button_event) {
        guard let window = window(id: button.windowID), window.input != nil else { return }
        let android: Int32
        switch Int(button.button) {
        case MEAD_SDL_BUTTON_LEFT: android = Android.buttonPrimary
        case MEAD_SDL_BUTTON_RIGHT: android = Android.buttonSecondary
        case MEAD_SDL_BUTTON_MIDDLE: android = Android.buttonTertiary
        default: return
        }
        let pointer = mousePointer(window, x: button.x, y: button.y)
        let time = Self.now()
        if button.down {
            // As Android's mouse: DOWN with the first button, then
            // BUTTON_PRESS for each.
            let first = window.mouseButtons == 0
            window.mouseButtons |= android
            if first {
                window.mouseDownTime = time
                sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionDown,
                           buttonState: window.mouseButtons, downTime: time, pointers: [pointer])
            }
            sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionButtonPress,
                       actionButton: android, buttonState: window.mouseButtons, downTime: window.mouseDownTime, pointers: [pointer])
        } else {
            window.mouseButtons &= ~android
            sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionButtonRelease,
                       actionButton: android, buttonState: window.mouseButtons, downTime: window.mouseDownTime, pointers: [pointer])
            if window.mouseButtons == 0 {
                sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionUp,
                           downTime: window.mouseDownTime, pointers: [pointer])
            }
        }
    }

    private func mouseMotion(_ motion: mead_sdl_mouse_motion_event) {
        guard let window = window(id: motion.windowID), window.input != nil else { return }
        let pointer = mousePointer(window, x: motion.x, y: motion.y)
        if window.mouseButtons != 0 {
            sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionMove,
                       buttonState: window.mouseButtons, downTime: window.mouseDownTime, pointers: [pointer])
        } else {
            let time = Self.now()
            sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionHoverMove,
                       downTime: time, pointers: [pointer])
        }
    }

    private func mouseWheel(_ wheel: mead_sdl_mouse_wheel_event) {
        guard let window = window(id: wheel.windowID), window.input != nil else { return }
        let flipped = wheel.direction == UInt32(MEAD_SDL_MOUSEWHEEL_FLIPPED) ? Float(-1) : 1
        var pointer = mousePointer(window, x: wheel.mouse_x, y: wheel.mouse_y)
        pointer.axes[Android.axisVScroll] = wheel.y * flipped
        pointer.axes[Android.axisHScroll] = wheel.x * flipped
        let time = Self.now()
        sendMotion(window, device: Android.mouse, source: Android.sourceMouse, action: Android.motionScroll,
                   buttonState: window.mouseButtons, downTime: time, pointers: [pointer])
    }

    private func finger(_ touch: mead_sdl_touch_event) {
        guard let window = window(id: touch.windowID) ?? inputWindow, window.input != nil else { return }
        let x = touch.x * Float(window.pixelWidth), y = touch.y * Float(window.pixelHeight)
        let time = Self.now()
        var action: Int32
        switch Int(touch.type) {
        case MEAD_SDL_EVENT_FINGER_DOWN:
            // The lowest pointer ID not in use, as Android numbers them.
            var id: Int32 = 0
            while window.fingers.contains(where: { $0.id == id }) { id += 1 }
            window.fingers.append((touch.fingerID, id, x, y, touch.pressure))
            let index = Int32(window.fingers.count - 1)
            if window.fingers.count == 1 {
                window.touchDownTime = time
                action = Android.motionDown
            } else {
                action = Android.motionPointerDown | index << 8
            }
        case MEAD_SDL_EVENT_FINGER_UP:
            guard let index = window.fingers.firstIndex(where: { $0.sdl == touch.fingerID }) else { return }
            window.fingers[index].x = x
            window.fingers[index].y = y
            action = window.fingers.count == 1 ? Android.motionUp : Android.motionPointerUp | Int32(index) << 8
        default:
            guard let index = window.fingers.firstIndex(where: { $0.sdl == touch.fingerID }) else { return }
            window.fingers[index].x = x
            window.fingers[index].y = y
            window.fingers[index].pressure = touch.pressure
            action = Android.motionMove
        }
        let pointers = window.fingers.map {
            Pointer(id: $0.id, tool: Android.toolFinger,
                    axes: [Android.axisX: $0.x, Android.axisY: $0.y, Android.axisPressure: $0.pressure > 0 ? $0.pressure : 1,
                           Android.axisSize: 0.1])
        }
        sendMotion(window, device: Android.touchscreen, source: Android.sourceTouchscreen, action: action,
                   downTime: window.touchDownTime, pointers: pointers)
        if Int(touch.type) == MEAD_SDL_EVENT_FINGER_UP {
            window.fingers.removeAll { $0.sdl == touch.fingerID }
        }
    }

    private func gamepadAxis(_ axis: mead_sdl_gamepad_axis_event) {
        guard let window = inputWindow, window.input != nil else { return }
        var axes = gamepadAxes[axis.which] ?? [:]
        let value = androidAxisValue(axis.value)
        for android in androidAxes(forGamepadAxis: axis.axis) {
            axes[android] = value
        }
        gamepadAxes[axis.which] = axes
        let time = Self.now()
        sendMotion(window, device: Android.gamepadBase + Int32(axis.which), source: Android.sourceJoystick,
                   action: Android.motionMove, downTime: time, pointers: [Pointer(id: 0, tool: 0, axes: axes)])
    }
}
