import CMeadWindow

// SDL's input as Android's: key codes, axes and meta state, for both of
// Mead's ways of delivering input to Android code.

/// Android's motion event axes (AMOTION_EVENT_AXIS_*) that SDL's gamepads
/// have.
public enum AndroidAxis {
    public static let x: Int32 = 0
    public static let y: Int32 = 1
    public static let z: Int32 = 11
    public static let rz: Int32 = 14
    public static let ltrigger: Int32 = 17
    public static let rtrigger: Int32 = 18
    public static let gas: Int32 = 22
    public static let brake: Int32 = 23
}

/// SDL's gamepad buttons as Android's key codes.
public func androidKeyCode(forGamepadButton button: UInt8) -> Int32 {
    switch Int(button) {
    case MEAD_SDL_GAMEPAD_BUTTON_SOUTH: return 96 // A
    case MEAD_SDL_GAMEPAD_BUTTON_EAST: return 97 // B
    case MEAD_SDL_GAMEPAD_BUTTON_WEST: return 99 // X
    case MEAD_SDL_GAMEPAD_BUTTON_NORTH: return 100 // Y
    case MEAD_SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return 102 // L1
    case MEAD_SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return 103 // R1
    case MEAD_SDL_GAMEPAD_BUTTON_LEFT_STICK: return 106
    case MEAD_SDL_GAMEPAD_BUTTON_RIGHT_STICK: return 107
    case MEAD_SDL_GAMEPAD_BUTTON_START: return 108
    case MEAD_SDL_GAMEPAD_BUTTON_BACK: return 109 // select
    case MEAD_SDL_GAMEPAD_BUTTON_GUIDE: return 110 // mode
    case MEAD_SDL_GAMEPAD_BUTTON_DPAD_UP: return 19
    case MEAD_SDL_GAMEPAD_BUTTON_DPAD_DOWN: return 20
    case MEAD_SDL_GAMEPAD_BUTTON_DPAD_LEFT: return 21
    case MEAD_SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return 22
    default: return 0
    }
}

/// Android's axes for one of SDL's: triggers are reported under two names,
/// as Android's own drivers do.
public func androidAxes(forGamepadAxis axis: UInt8) -> [Int32] {
    switch Int(axis) {
    case MEAD_SDL_GAMEPAD_AXIS_LEFTX: return [AndroidAxis.x]
    case MEAD_SDL_GAMEPAD_AXIS_LEFTY: return [AndroidAxis.y]
    case MEAD_SDL_GAMEPAD_AXIS_RIGHTX: return [AndroidAxis.z]
    case MEAD_SDL_GAMEPAD_AXIS_RIGHTY: return [AndroidAxis.rz]
    case MEAD_SDL_GAMEPAD_AXIS_LEFT_TRIGGER: return [AndroidAxis.ltrigger, AndroidAxis.brake]
    case MEAD_SDL_GAMEPAD_AXIS_RIGHT_TRIGGER: return [AndroidAxis.rtrigger, AndroidAxis.gas]
    default: return []
    }
}

/// SDL's axis range as Android's: -1 to 1, or 0 to 1 for a trigger.
public func androidAxisValue(_ value: Int16) -> Float {
    max(Float(value) / 32767, -1)
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
    case 101, 118: return 82 // application, menu: Android's MENU
    case 270: return 4 // AC back: Android's BACK
    case 224: return 113 // left control
    case 225: return 59 // left shift
    case 226: return 57 // left alt
    case 228: return 114 // right control
    case 229: return 60 // right shift
    case 230: return 58 // right alt
    default: return 0
    }
}

/// SDL's modifier keys as Android's meta state (KeyEvent.META_*).
public func androidMetaState(_ mod: UInt16) -> Int32 {
    let mod = Int(mod)
    var state: Int32 = 0
    if mod & MEAD_SDL_KMOD_LSHIFT != 0 { state |= 0x1 | 0x40 }  // shift, left shift
    if mod & MEAD_SDL_KMOD_RSHIFT != 0 { state |= 0x1 | 0x80 }
    if mod & MEAD_SDL_KMOD_LALT != 0 { state |= 0x2 | 0x10 }  // alt, left alt
    if mod & MEAD_SDL_KMOD_RALT != 0 { state |= 0x2 | 0x20 }
    if mod & MEAD_SDL_KMOD_LCTRL != 0 { state |= 0x1000 | 0x2000 }  // ctrl, left ctrl
    if mod & MEAD_SDL_KMOD_RCTRL != 0 { state |= 0x1000 | 0x4000 }
    if mod & MEAD_SDL_KMOD_LGUI != 0 { state |= 0x10000 | 0x20000 }  // meta, left meta
    if mod & MEAD_SDL_KMOD_RGUI != 0 { state |= 0x10000 | 0x40000 }
    if mod & MEAD_SDL_KMOD_CAPS != 0 { state |= 0x100000 }
    if mod & MEAD_SDL_KMOD_NUM != 0 { state |= 0x200000 }
    return state
}
