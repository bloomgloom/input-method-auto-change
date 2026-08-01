import Foundation

/// What to do about a just-finished word: what's currently displayed (so the
/// caller knows how much to delete, and can restore it verbatim if the user
/// undoes the correction), what to retype instead, and which input source to
/// switch to afterwards.
struct ReplacementDecision {
    let activeDisplayText: String
    let replacementText: String
    let targetLayout: Layout
}

/// Ties Tier 1 (deterministic: Hangul composition validity plus a
/// dictionary check in both directions) and Tier 2 (on-device model
/// plausibility judgment) together behind a single strategy switch keyed on
/// `LLMCallMode`:
///   - A dictionary-confirmed candidate is accepted immediately and never
///     consults Tier 2 at all, regardless of `LLMCallMode` — this is the fast
///     path that keeps common, real words from paying on-device model
///     latency (NSSpellChecker supports both Korean and English).
///   - Anything else is merely *ambiguous*: structurally valid (Korean
///     composed cleanly) or non-empty decodable text, but not a dictionary
///     hit (a proper noun, slang, a new coinage...). What happens to it is
///     exactly what `LLMCallMode` controls:
///       - `.dictionaryOnly` (default): leave it alone, never consult Tier 2.
///         Maximizes speed/predictability at the cost of only ever
///         correcting dictionary words.
///       - `.modelAssisted`: ask Tier 2 for an opinion; accept only if it
///         comes back `.plausible` (an unavailable model or a negative
///         verdict both mean "don't touch it").
struct DecisionEngine {
    private let dictionaryChecker: DictionaryWordChecking
    private let judge: PlausibilityJudge?

    init(dictionaryChecker: DictionaryWordChecking, judge: PlausibilityJudge?) {
        self.dictionaryChecker = dictionaryChecker
        self.judge = judge
    }

    private enum Tier1Outcome {
        /// Nothing coherent could even be rendered (e.g. Hangul composition
        /// hard-failed, or a key had no mapping) — there is no text to offer
        /// Tier 2 either, so this is a no-op regardless of `LLMCallMode`.
        case noCandidateText
        /// The dictionary recognizes this as a real word — fast path, skips
        /// Tier 2 entirely.
        case dictionaryConfirmed(String)
        /// Structurally/lexically plausible but not a dictionary hit —
        /// whether this gets corrected at all depends entirely on
        /// `LLMCallMode`.
        case ambiguous(String)
    }

    func decide(buffer: [BufferedKey], currentLayout: Layout, mode: LLMCallMode) async -> ReplacementDecision? {
        guard !buffer.isEmpty else { return nil }
        let otherLayout: Layout = currentLayout == .english ? .korean : .english

        guard let activeChars = LayoutMaps.decode(buffer, layout: currentLayout),
              let candidateChars = LayoutMaps.decode(buffer, layout: otherLayout)
        else {
            return nil
        }
        let activeDisplay = renderedText(for: activeChars, layout: currentLayout)

        // Never touch text that's already a recognized real word in the
        // layout it was actually typed in -- even if reinterpreting the same
        // keystrokes under the other layout also happens to pass Tier 1 (e.g.
        // Korean particles like "이"/"을"/"는"/"가" decode keystroke-for-
        // keystroke into short strings like "dl" that a dictionary also
        // accepts). Preserving already-valid input outranks catching a
        // coincidental false-positive collision in the other direction.
        if case .dictionaryConfirmed = tier1Outcome(activeChars, layout: currentLayout) {
            return nil
        }

        let candidateLanguage: CandidateLanguage = otherLayout == .korean ? .korean : .english

        switch tier1Outcome(candidateChars, layout: otherLayout) {
        case .noCandidateText:
            return nil

        case .dictionaryConfirmed(let text):
            return ReplacementDecision(activeDisplayText: activeDisplay, replacementText: text, targetLayout: otherLayout)

        case .ambiguous(let text):
            guard mode == .modelAssisted, let judge else { return nil }
            guard case .plausible = await judge.judge(candidate: text, language: candidateLanguage) else { return nil }
            return ReplacementDecision(activeDisplayText: activeDisplay, replacementText: text, targetLayout: otherLayout)
        }
    }

    private func tier1Outcome(_ chars: [Character], layout: Layout) -> Tier1Outcome {
        switch layout {
        case .korean:
            guard let composed = HangulComposer.compose(chars) else { return .noCandidateText }
            if dictionaryChecker.isRecognizedWord(composed, languageCode: "ko") {
                return .dictionaryConfirmed(composed)
            }
            return .ambiguous(composed)
        case .english:
            let text = String(chars)
            guard !text.isEmpty else { return .noCandidateText }
            if dictionaryChecker.isRecognizedWord(text, languageCode: "en") {
                return .dictionaryConfirmed(text)
            }
            return .ambiguous(text)
        }
    }

    /// What's already on screen for the current word under the active
    /// layout — must never fail (see `HangulComposer.renderBestEffort`),
    /// since we need this to compute a correct backspace count even when
    /// the user typed something that doesn't cleanly compose as Korean
    /// (which is exactly the Korean-mode-but-meant-English case).
    private func renderedText(for chars: [Character], layout: Layout) -> String {
        switch layout {
        case .english:
            return String(chars)
        case .korean:
            return HangulComposer.renderBestEffort(chars)
        }
    }
}
