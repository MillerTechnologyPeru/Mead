import Glibc
import MeadJNI

// Text input. A game opens a text box and asks for a keyboard; on Android the
// on-screen keyboard then edits the text and the game hears back the result.
// Here whatever runs the window makes those edits, from the host's own
// keyboard. Games ask in one of two ways: GameActivity's InputConnection,
// which hears back a State, or Minecraft's own showKeyboard, which hears back
// the whole text and the caret. Positions are in UTF-16 code units, as
// Java's strings count them.

/// One change to the text, as a keyboard makes it.
public enum TextEdit: Equatable {
    case insert(String)
    case deleteBackward
    case deleteForward
    case moveLeft
    case moveRight
    case moveToStart
    case moveToEnd
    /// Enter, in a box that takes it as "done" rather than as a key.
    case submit
}

/// A text box being typed into: its text, selection, and whether it's open.
public final class TextBox {
    private let lock = LockedValue((text: [UInt16](), start: 0, end: 0, active: false, multiline: false, maxLength: 0))

    public init() {}

    /// Whether the game wants typing, as it would want the soft keyboard.
    public var isActive: Bool { lock.withLock { $0.active } }
    public var isMultiline: Bool { lock.withLock { $0.multiline } }

    /// The text and selection now.
    public var current: (text: String, start: Int, end: Int) {
        lock.withLock { (String(decoding: $0.text, as: UTF16.self), $0.start, $0.end) }
    }

    public func setActive(_ active: Bool) {
        lock.withLock { $0.active = active }
    }

    /// Opens the box on `text` with the caret at its end, unless it's already
    /// open on that same text: then where the caret was stands.
    public func open(text: String, maxLength: Int = 0, multiline: Bool = false) {
        let units = Array(text.utf16)
        lock.withLock { value in
            let same = value.active && value.text == units
            value.active = true
            value.multiline = multiline
            value.maxLength = max(maxLength, 0)
            if !same {
                value.text = units
                value.start = units.count
                value.end = units.count
            }
        }
    }

    /// The text and selection, as the game says they are.
    public func set(text: String, start: Int, end: Int) {
        let units = Array(text.utf16)
        let clamp = { (value: Int) in min(max(value, 0), units.count) }
        let start = clamp(start), end = clamp(end)
        lock.withLock { $0.text = units; $0.start = min(start, end); $0.end = max(start, end) }
    }

    public func setCaret(_ position: Int) {
        lock.withLock { value in
            value.start = min(max(position, 0), value.text.count)
            value.end = value.start
        }
    }

    /// Applies an edit and returns the text and selection after it.
    @discardableResult
    public func apply(_ edit: TextEdit) -> (text: String, start: Int, end: Int) {
        lock.withLock { value in
            var text = value.text, start = value.start, end = value.end
            switch edit {
            case let .insert(string):
                var units = Array(string.utf16)
                if value.maxLength > 0 {
                    // As much as fits, never half a surrogate pair.
                    var room = max(value.maxLength - (text.count - (end - start)), 0)
                    if room < units.count {
                        if room > 0, UTF16.isLeadSurrogate(units[room - 1]) { room -= 1 }
                        units = Array(units[..<room])
                    }
                }
                text.replaceSubrange(start..<end, with: units)
                start += units.count
                end = start
            case .deleteBackward:
                if start != end {
                    text.removeSubrange(start..<end)
                } else if start > 0 {
                    // A surrogate pair goes as one character.
                    let width = start >= 2 && UTF16.isTrailSurrogate(text[start - 1]) && UTF16.isLeadSurrogate(text[start - 2]) ? 2 : 1
                    text.removeSubrange((start - width)..<start)
                    start -= width
                }
                end = start
            case .deleteForward:
                if start != end {
                    text.removeSubrange(start..<end)
                } else if start < text.count {
                    let width = start + 1 < text.count && UTF16.isLeadSurrogate(text[start]) && UTF16.isTrailSurrogate(text[start + 1]) ? 2 : 1
                    text.removeSubrange(start..<(start + width))
                }
                end = start
            case .moveLeft:
                if start != end { end = start } else if start > 0 {
                    start -= start >= 2 && UTF16.isTrailSurrogate(text[start - 1]) ? 2 : 1
                    end = start
                }
            case .moveRight:
                if start != end { start = end } else if end < text.count {
                    end += end + 1 < text.count && UTF16.isLeadSurrogate(text[end]) ? 2 : 1
                    start = end
                }
            case .moveToStart:
                start = 0
                end = 0
            case .moveToEnd:
                start = text.count
                end = start
            case .submit:
                break
            }
            value.text = text
            value.start = start
            value.end = end
            return (String(decoding: text, as: UTF16.self), start, end)
        }
    }
}

@JavaClass("com/google/androidgamesdk/gametextinput/State")
public final class JavaTextInputState: JavaObject {
    @JavaField("text") public var text: String?
    @JavaField("selectionStart") public var selectionStart: Int32
    @JavaField("selectionEnd") public var selectionEnd: Int32
    @JavaField("composingRegionStart") public var composingRegionStart: Int32
    @JavaField("composingRegionEnd") public var composingRegionEnd: Int32

    @JavaMethod(signature: "(Ljava/lang/String;IIII)V")
    public init(text: String?, selectionStart: Int32, selectionEnd: Int32, composingRegionStart: Int32, composingRegionEnd: Int32) {
        self.text = text
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
        self.composingRegionStart = composingRegionStart
        self.composingRegionEnd = composingRegionEnd
        super.init()
    }
}

@JavaClass("com/google/androidgamesdk/gametextinput/InputConnection")
public final class JavaTextInputConnection: JavaObject {
    public let box = TextBox()

    public override init() {
        super.init()
    }

    public var isActive: Bool { box.isActive }
    public var current: (text: String, start: Int, end: Int) { box.current }

    @JavaMethod("setSoftKeyboardActive") public func setSoftKeyboardActive(_ active: Bool, _ flags: Int32) {
        box.setActive(active)
    }

    @JavaMethod("restartInput") public func restartInput() {}

    @JavaMethod("setState", signature: "(Lcom/google/androidgamesdk/gametextinput/State;)V")
    public func setState(_ state: JavaObject?) {
        guard let state = state as? JavaTextInputState else { return }
        box.set(text: state.text ?? "", start: Int(state.selectionStart), end: Int(state.selectionEnd))
    }

    /// Applies an edit and returns the State to tell the game about.
    public func apply(_ edit: TextEdit) -> JavaTextInputState {
        let after = box.apply(edit)
        return JavaTextInputState(text: after.text, selectionStart: Int32(after.start), selectionEnd: Int32(after.end),
                                  composingRegionStart: -1, composingRegionEnd: -1)
    }
}
