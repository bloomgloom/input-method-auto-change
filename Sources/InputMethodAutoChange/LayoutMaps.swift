import Foundation

/// Raw macOS virtual keycode (same numeric space as `CGKeyCode`).
/// Kept as a plain `UInt16` here (rather than importing CoreGraphics) so this
/// file and its tests have no dependency on system frameworks.
typealias RawKeyCode = UInt16

enum Layout {
    case english
    case korean
}

/// Static keycode -> character tables for the two layouts this app cares about:
/// US QWERTY (English) and 2-beolsik (Korean). Keycodes are positional, so the
/// same physical key produces the same `RawKeyCode` under either input source —
/// that's what lets us re-decode a buffered keystroke sequence under either
/// hypothesis after the fact.
enum LayoutMaps {
    static let englishBase: [RawKeyCode: Character] = [
        0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x05: "g", 0x04: "h",
        0x06: "z", 0x07: "x", 0x08: "c", 0x09: "v", 0x0B: "b",
        0x0C: "q", 0x0D: "w", 0x0E: "e", 0x0F: "r", 0x10: "y", 0x11: "t",
        0x1F: "o", 0x20: "u", 0x22: "i", 0x23: "p",
        0x25: "l", 0x26: "j", 0x28: "k",
        0x2D: "n", 0x2E: "m",
    ]

    static let englishShifted: [RawKeyCode: Character] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x05: "G", 0x04: "H",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B",
        0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P",
        0x25: "L", 0x26: "J", 0x28: "K",
        0x2D: "N", 0x2E: "M",
    ]

    /// 2-beolsik base jamo, keyed by the same physical keycodes as `englishBase`.
    static let koreanBase: [RawKeyCode: Character] = [
        0x0C: "ㅂ", 0x0D: "ㅈ", 0x0E: "ㄷ", 0x0F: "ㄱ", 0x11: "ㅅ",
        0x10: "ㅛ", 0x20: "ㅕ", 0x22: "ㅑ", 0x1F: "ㅐ", 0x23: "ㅔ",
        0x00: "ㅁ", 0x01: "ㄴ", 0x02: "ㅇ", 0x03: "ㄹ", 0x05: "ㅎ",
        0x04: "ㅗ", 0x26: "ㅓ", 0x28: "ㅏ", 0x25: "ㅣ",
        0x06: "ㅋ", 0x07: "ㅌ", 0x08: "ㅊ", 0x09: "ㅍ", 0x0B: "ㅠ",
        0x2D: "ㅜ", 0x2E: "ㅡ",
    ]

    /// Shift+key produces the double consonants and two double-vowel keys (ㅒ/ㅖ).
    static let koreanShifted: [RawKeyCode: Character] = [
        0x0C: "ㅃ", 0x0D: "ㅉ", 0x0E: "ㄸ", 0x0F: "ㄲ", 0x11: "ㅆ",
        0x1F: "ㅒ", 0x23: "ㅖ",
    ]

    static func decode(keyCode: RawKeyCode, shift: Bool, layout: Layout) -> Character? {
        switch layout {
        case .english:
            if shift, let c = englishShifted[keyCode] { return c }
            return englishBase[keyCode]
        case .korean:
            if shift, let c = koreanShifted[keyCode] { return c }
            return koreanBase[keyCode]
        }
    }

    /// Whether this keycode decodes as an alphabet/jamo letter under either
    /// layout -- i.e. it's a candidate for a word being typed, as opposed to
    /// a digit, a symbol, or a non-printing key (arrow keys, F-keys, the
    /// dedicated 한자/한영 input-source-switch key, ...).
    static func isLetterOrJamo(keyCode: RawKeyCode, shift: Bool) -> Bool {
        decode(keyCode: keyCode, shift: shift, layout: .english) != nil
            || decode(keyCode: keyCode, shift: shift, layout: .korean) != nil
    }

    /// Digit-row and common symbol keys, keyed the same way as the letter
    /// tables above. Unlike letters, these render the same character
    /// regardless of which of the two layouts is active -- 2-beolsik Korean
    /// only remaps the letter keys, not the number/symbol row -- so there's
    /// just one table, not one per layout.
    static let literalBase: [RawKeyCode: Character] = [
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\",
        0x29: ";", 0x27: "'", 0x2C: "/", 0x32: "`",
    ]

    static let literalShifted: [RawKeyCode: Character] = [
        0x1D: ")", 0x12: "!", 0x13: "@", 0x14: "#", 0x15: "$",
        0x17: "%", 0x16: "^", 0x1A: "&", 0x1C: "*", 0x19: "(",
        0x1B: "_", 0x18: "+", 0x21: "{", 0x1E: "}", 0x2A: "|",
        0x29: ":", 0x27: "\"", 0x32: "~",
    ]

    /// The literal character a digit/symbol key types, if it's one this
    /// table knows about. `nil` for anything else (letters -- use `decode`
    /// for those -- and non-printing keys), which callers must treat as
    /// "unknown, don't assume nothing was printed" rather than as "printed
    /// nothing".
    static func literalCharacter(keyCode: RawKeyCode, shift: Bool) -> Character? {
        if shift, let c = literalShifted[keyCode] { return c }
        return literalBase[keyCode]
    }

    /// Decodes a whole buffered word under one layout hypothesis. Returns `nil`
    /// if any key in the buffer has no mapping under that layout (e.g. a digit
    /// key while decoding as Korean) — such a buffer can't be a candidate at all.
    static func decode(_ buffer: [BufferedKey], layout: Layout) -> [Character]? {
        var result: [Character] = []
        result.reserveCapacity(buffer.count)
        for key in buffer {
            guard let c = decode(keyCode: key.keyCode, shift: key.shift, layout: layout) else {
                return nil
            }
            result.append(c)
        }
        return result
    }
}
