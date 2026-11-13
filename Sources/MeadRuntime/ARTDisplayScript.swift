import Glibc
import MeadWindow

/// MEAD_DEBUG_TAPS="seconds:x,y;...": input played into the window input
/// goes to, timed from the first window, for trying an app's screens on a
/// machine nobody is at; the game runtime's script, for ART. "x,y" taps
/// there (window pixels), held 150 ms; "key=scancode" presses an SDL
/// scancode for 150 ms; "text=words" types them, key by key.
extension ARTDisplay {
    struct ScriptStep {
        enum Action {
            case touch(down: Bool, x: Float, y: Float)
            case key(scancode: UInt32, down: Bool, shift: Bool)
        }

        let at: Double
        let action: Action
    }

    static func parseScript(_ text: String) -> [ScriptStep] {
        var steps: [ScriptStep] = []
        for item in text.split(separator: ";") {
            let halves = item.split(separator: ":", maxSplits: 1)
            guard halves.count == 2, let at = Double(halves[0]) else { continue }
            let what = halves[1]
            if what.hasPrefix("key="), let code = UInt32(what.dropFirst(4)) {
                steps.append(ScriptStep(at: at, action: .key(scancode: code, down: true, shift: false)))
                steps.append(ScriptStep(at: at + 0.15, action: .key(scancode: code, down: false, shift: false)))
            } else if what.hasPrefix("text=") {
                var time = at
                for character in what.dropFirst(5) {
                    guard let (code, shift) = scancode(for: character) else { continue }
                    steps.append(ScriptStep(at: time, action: .key(scancode: code, down: true, shift: shift)))
                    steps.append(ScriptStep(at: time + 0.05, action: .key(scancode: code, down: false, shift: shift)))
                    time += 0.1
                }
            } else {
                let parts = what.split(separator: ",").compactMap { Float($0) }
                guard parts.count == 2 else { continue }
                steps.append(ScriptStep(at: at, action: .touch(down: true, x: parts[0], y: parts[1])))
                steps.append(ScriptStep(at: at + 0.15, action: .touch(down: false, x: parts[0], y: parts[1])))
            }
        }
        return steps.sorted { $0.at < $1.at }
    }

    /// SDL's scancode for a character on a US keyboard, and whether it takes
    /// shift.
    static func scancode(for character: Character) -> (UInt32, Bool)? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7a: return (4 + UInt32(ascii - 0x61), false)  // a to z
        case 0x41...0x5a: return (4 + UInt32(ascii - 0x41), true)  // A to Z
        case 0x31...0x39: return (30 + UInt32(ascii - 0x31), false)  // 1 to 9
        case 0x30: return (39, false)
        case 0x20: return (44, false)
        case 0x2d: return (45, false)
        case 0x2e: return (55, false)
        case 0x2c: return (54, false)
        default: return nil
        }
    }

    /// Plays the steps that are due. On the display thread.
    func playScript(elapsed: Double) {
        while scriptNext < script.count, script[scriptNext].at <= elapsed {
            let step = script[scriptNext]
            scriptNext += 1
            guard let window = inputWindow else { continue }
            if case let .touch(true, x, y) = step.action {
                let line = "mead: MEAD_DEBUG_TAPS: tap at \(x),\(y) in window \(window.id)\n"
                _ = line.withCString { write(2, $0, strlen($0)) }
            }
            var event = mead_sdl_event()
            switch step.action {
            case let .touch(down, x, y):
                event.finger.type = UInt32(down ? MEAD_SDL_EVENT_FINGER_DOWN : MEAD_SDL_EVENT_FINGER_UP)
                event.finger.touchID = 1
                event.finger.fingerID = 1
                event.finger.x = x / Float(max(window.pixelWidth, 1))
                event.finger.y = y / Float(max(window.pixelHeight, 1))
                event.finger.pressure = down ? 1 : 0
                event.finger.windowID = window.id
            case let .key(scancode, down, shift):
                event.key.type = UInt32(down ? MEAD_SDL_EVENT_KEY_DOWN : MEAD_SDL_EVENT_KEY_UP)
                event.key.windowID = window.id
                event.key.scancode = scancode
                event.key.mod = shift ? UInt16(MEAD_SDL_KMOD_LSHIFT) : 0
                event.key.down = down
            }
            handle(event)
        }
    }
}
