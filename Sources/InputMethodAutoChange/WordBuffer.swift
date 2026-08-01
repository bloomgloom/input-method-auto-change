import Foundation

/// One captured keystroke: a raw, layout-independent keycode plus whether
/// Shift was held (needed to distinguish e.g. `ㄱ` from `ㄲ`, or `a` from `A`).
struct BufferedKey: Equatable {
    let keyCode: RawKeyCode
    let shift: Bool
}

/// Keycodes that end the current word. Space, Return, and sentence-ending
/// punctuation all trigger a correction decision; Tab just resets the buffer
/// without triggering one.
enum WordBoundary {
    static let space: RawKeyCode = 0x31
    static let `return`: RawKeyCode = 0x24
    static let tab: RawKeyCode = 0x30

    /// Punctuation that also triggers a decision immediately, the same as
    /// space/return — without waiting for a following space or return, which
    /// may never come (e.g. the user hits a Send button right after the
    /// closing "?"). Keyed by (keycode, shift) since e.g. the "/" key only
    /// counts shifted, as "?" — bare "/" isn't sentence-ending punctuation.
    private struct PunctuationKey: Hashable {
        let keyCode: RawKeyCode
        let shift: Bool
    }

    private static let punctuation: [PunctuationKey: Character] = [
        PunctuationKey(keyCode: 0x2F, shift: false): ".", // period key
        PunctuationKey(keyCode: 0x2B, shift: false): ",", // comma key
        PunctuationKey(keyCode: 0x2C, shift: true): "?",  // shift+/
        PunctuationKey(keyCode: 0x12, shift: true): "!",  // shift+1
    ]

    static func isBoundary(_ keyCode: RawKeyCode, shift: Bool) -> Bool {
        keyCode == space || keyCode == `return` || keyCode == tab
            || punctuation[PunctuationKey(keyCode: keyCode, shift: shift)] != nil
    }

    static func triggersDecision(_ keyCode: RawKeyCode, shift: Bool) -> Bool {
        keyCode == space || keyCode == `return`
            || punctuation[PunctuationKey(keyCode: keyCode, shift: shift)] != nil
    }

    /// The literal character the OS will already have inserted for this
    /// boundary key by the time a correction runs — this tap is
    /// `.listenOnly` and never blocks the real keystroke, so the boundary
    /// character is already on screen before `TextReplacer` gets a chance to
    /// act. Callers need this both to delete it (it's now part of what's
    /// displayed) and to retype it after the correction, so it isn't lost.
    static func insertedCharacter(for keyCode: RawKeyCode, shift: Bool) -> String {
        if keyCode == `return` { return "\n" }
        if keyCode == space { return " " }
        if let char = punctuation[PunctuationKey(keyCode: keyCode, shift: shift)] { return String(char) }
        if let char = LayoutMaps.literalCharacter(keyCode: keyCode, shift: shift) { return String(char) }
        return ""
    }
}

/// Accumulates raw keystrokes for the word currently being typed. Reset on
/// any word boundary, or externally whenever focus moves to a different app
/// or window (the caller is responsible for calling `reset()` in that case —
/// this type has no notion of focus itself).
struct WordBuffer {
    private(set) var keys: [BufferedKey] = []

    mutating func append(_ key: BufferedKey) {
        keys.append(key)
    }

    /// Mirrors a real Backspace: drops the most recently buffered key, if
    /// any, so the buffer keeps matching what's actually still on screen.
    mutating func deleteLast() {
        if !keys.isEmpty {
            keys.removeLast()
        }
    }

    mutating func reset() {
        keys.removeAll(keepingCapacity: true)
    }

    var isEmpty: Bool { keys.isEmpty }
}
