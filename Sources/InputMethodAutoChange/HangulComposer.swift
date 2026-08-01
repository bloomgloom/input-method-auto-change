import Foundation

/// Deterministic 2-beolsik jamo auto-composition, the same state machine a
/// Korean IME runs internally to assemble keystrokes into syllable blocks.
/// Used two ways by the rest of the app, with two different failure
/// policies (see `compose` vs `renderBestEffort` below):
///   1. To reproduce what the OS has already rendered for the current word
///      under whichever layout is actually active (so `TextReplacer` knows
///      exactly how many characters to backspace). This must never "fail" —
///      the real OS IME always displays *something* for every keystroke,
///      including jamo that don't cleanly combine (shown as standalone
///      characters), so this app has to mirror that or it can't compute a
///      correct backspace count.
///   2. As the Tier-1 deterministic validity gate for the *candidate*
///      reinterpretation of a mistyped word — here an incomplete/orphaned
///      jamo really should reject the whole candidate, since that's exactly
///      the signal that the buffer wasn't cleanly typed as Korean.
enum HangulComposer {
    private static let choList: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]

    private static let jungList: [Character] = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ",
        "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ",
    ]

    /// Index 0 means "no trailing consonant".
    private static let jongList: [Character?] = [
        nil, "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ",
        "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]

    private static let choSet: Set<Character> = Set(choList)
    private static let jungSet: Set<Character> = Set(jungList)
    private static let simpleJongSet: Set<Character> = Set(jongList.compactMap { $0 })

    /// Two base vowels typed back-to-back that fuse into one compound vowel.
    private static let compoundVowels: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ",
        "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ",
        "ㅡㅣ": "ㅢ",
    ]

    /// Two base consonants typed back-to-back, while already sitting in the
    /// trailing-consonant slot, that fuse into one compound jongseong.
    private static let compoundJong: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ",
        "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ", "ㄹㅅ": "ㄽ",
        "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ",
    ]

    /// Inverse of `compoundJong`, plus every simple jongseong mapping to
    /// itself — used for 종성 재배치 (reassigning a trailing consonant to the
    /// next syllable's leading consonant when a vowel follows it). For a
    /// compound jongseong only its second component moves; the first stays.
    private static let jongSplit: [Character: (remain: Character?, moved: Character)] = {
        var result: [Character: (Character?, Character)] = [:]
        let compoundValues = Set(compoundJong.values)
        for j in simpleJongSet where !compoundValues.contains(j) {
            result[j] = (nil, j)
        }
        for (pair, compound) in compoundJong {
            let chars = Array(pair)
            result[compound] = (chars[0], chars[1])
        }
        return result
    }()

    /// One piece of output from the state machine: either a cleanly
    /// composed syllable block, or a jamo that couldn't attach to anything
    /// and is rendered standalone (a "compatibility jamo" character, which
    /// is independently displayable Unicode — this is what the real OS IME
    /// shows for jamo that don't fit into a syllable box).
    private enum Token {
        case syllable(Character)
        case orphan(Character)
    }

    private enum State {
        case empty
        case hasCho(cho: Character)
        case hasChoJung(cho: Character, jung: Character)
        case hasChoJungJong(cho: Character, jung: Character, jong: Character)
    }

    /// The shared combination engine. Never "fails" — every input either
    /// extends the pending syllable or gets flushed as a token (syllable or
    /// orphan). Callers decide what an orphan token means for their use case.
    private struct Engine {
        private var state: State = .empty
        private var tokens: [Token] = []

        mutating func feedConsonant(_ c: Character) {
            switch state {
            case .empty:
                state = .hasCho(cho: c)
            case .hasCho(let pendingCho):
                // Nothing can extend a bare leading consonant except a
                // vowel; flush it standalone and start fresh with the new
                // one.
                tokens.append(.orphan(pendingCho))
                state = .hasCho(cho: c)
            case .hasChoJung(let cho, let jung):
                if HangulComposer.simpleJongSet.contains(c) {
                    state = .hasChoJungJong(cho: cho, jung: jung, jong: c)
                } else {
                    finalizeBlock(cho: cho, jung: jung, jong: nil)
                    state = .hasCho(cho: c)
                }
            case .hasChoJungJong(let cho, let jung, let jong):
                let pair = "\(jong)\(c)"
                if let compound = HangulComposer.compoundJong[pair] {
                    state = .hasChoJungJong(cho: cho, jung: jung, jong: compound)
                } else {
                    finalizeBlock(cho: cho, jung: jung, jong: jong)
                    state = .hasCho(cho: c)
                }
            }
        }

        mutating func feedVowel(_ v: Character) {
            switch state {
            case .empty:
                // A bare vowel with no preceding consonant can't attach to
                // anything.
                tokens.append(.orphan(v))
            case .hasCho(let cho):
                state = .hasChoJung(cho: cho, jung: v)
            case .hasChoJung(let cho, let jung):
                let pair = "\(jung)\(v)"
                if let compound = HangulComposer.compoundVowels[pair] {
                    state = .hasChoJung(cho: cho, jung: compound)
                } else {
                    finalizeBlock(cho: cho, jung: jung, jong: nil)
                    tokens.append(.orphan(v))
                    state = .empty
                }
            case .hasChoJungJong(let cho, let jung, let jong):
                if let split = HangulComposer.jongSplit[jong] {
                    finalizeBlock(cho: cho, jung: jung, jong: split.remain)
                    state = .hasChoJung(cho: split.moved, jung: v)
                } else {
                    // Invariant: every jong that can land in `state` came
                    // either from `simpleJongSet` or a `compoundJong` value,
                    // both covered by `jongSplit` — this branch shouldn't be
                    // reachable, but degrade gracefully rather than lose input.
                    finalizeBlock(cho: cho, jung: jung, jong: jong)
                    tokens.append(.orphan(v))
                    state = .empty
                }
            }
        }

        private mutating func finalizeBlock(cho: Character, jung: Character, jong: Character?) {
            guard let choIdx = HangulComposer.choList.firstIndex(of: cho),
                  let jungIdx = HangulComposer.jungList.firstIndex(of: jung),
                  let jongIdx = HangulComposer.jongList.firstIndex(where: { $0 == jong }),
                  let scalar = Unicode.Scalar(0xAC00 + (choIdx * 21 + jungIdx) * 28 + jongIdx)
            else {
                // Unreachable in practice: cho/jung/jong here only ever come
                // from the canonical tables above.
                return
            }
            tokens.append(.syllable(Character(scalar)))
        }

        mutating func finish() -> [Token] {
            switch state {
            case .empty:
                break
            case .hasCho(let cho):
                tokens.append(.orphan(cho))
            case .hasChoJung(let cho, let jung):
                finalizeBlock(cho: cho, jung: jung, jong: nil)
            case .hasChoJungJong(let cho, let jung, let jong):
                finalizeBlock(cho: cho, jung: jung, jong: jong)
            }
            return tokens
        }
    }

    private static func run(_ jamos: [Character], skipUnclassifiable: Bool) -> [Token]? {
        var engine = Engine()
        for j in jamos {
            if choSet.contains(j) {
                engine.feedConsonant(j)
            } else if jungSet.contains(j) {
                engine.feedVowel(j)
            } else if skipUnclassifiable {
                continue
            } else {
                return nil
            }
        }
        return engine.finish()
    }

    /// Strict Tier-1 validity check: composes a full jamo sequence into
    /// Hangul syllables, or `nil` if any part of it doesn't cleanly combine
    /// (a dangling consonant, an orphan vowel, an unclassifiable character,
    /// or an empty sequence). Used to judge whether a *candidate*
    /// reinterpretation is well-formed Korean.
    static func compose(_ jamos: [Character]) -> String? {
        guard let tokens = run(jamos, skipUnclassifiable: false), !tokens.isEmpty else { return nil }
        var result = ""
        for token in tokens {
            switch token {
            case .syllable(let c): result.append(c)
            case .orphan: return nil
            }
        }
        return result
    }

    /// Lenient, always-succeeding rendering: mirrors what the OS Hangul IME
    /// would actually display for this keystroke sequence, including
    /// standalone jamo that don't combine into a full syllable. Used to
    /// figure out what's *already on screen* under the active layout, so
    /// `TextReplacer` knows how many characters to backspace — this must
    /// never fail, since the OS never simply shows nothing.
    static func renderBestEffort(_ jamos: [Character]) -> String {
        let tokens = run(jamos, skipUnclassifiable: true) ?? []
        var result = ""
        for token in tokens {
            switch token {
            case .syllable(let c), .orphan(let c):
                result.append(c)
            }
        }
        return result
    }
}
