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

/// Checks the active layout before considering the other layout, so preserving
/// plausible input always outranks finding a plausible reinterpretation:
///   1. Active-layout dictionary hit: leave the word alone.
///   2. In `.modelAssisted`, ask the model about an ambiguous active-layout
///      word. If plausible, leave it alone.
///   3. Other-layout dictionary hit: correct immediately.
///   4. In `.modelAssisted`, ask the model about an ambiguous other-layout
///      word and correct only if plausible.
/// If the active-layout model is unavailable, only a deterministic dictionary
/// hit in the other layout may cause a correction; an uncertain candidate is
/// left alone.
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

        let activeOutcome = tier1Outcome(activeChars, layout: currentLayout)

        // Never touch text that's already recognized in the layout it was
        // actually typed in. In model-assisted mode this protection also
        // covers proper nouns, slang, and other plausible non-dictionary
        // input before the opposite layout is considered.
        if case .dictionaryConfirmed = activeOutcome {
            return nil
        }

        var activeModelWasUnavailable = false
        if mode == .modelAssisted,
           case .ambiguous(let activeText) = activeOutcome,
           let judge {
            let activeLanguage: CandidateLanguage = currentLayout == .korean ? .korean : .english
            switch await judge.judge(candidate: activeText, language: activeLanguage) {
            case .plausible:
                return nil
            case .implausible:
                break
            case .unavailable:
                activeModelWasUnavailable = true
            }
        }

        let candidateLanguage: CandidateLanguage = otherLayout == .korean ? .korean : .english

        switch tier1Outcome(candidateChars, layout: otherLayout) {
        case .noCandidateText:
            return nil

        case .dictionaryConfirmed(let text):
            return ReplacementDecision(activeDisplayText: activeDisplay, replacementText: text, targetLayout: otherLayout)

        case .ambiguous(let text):
            guard mode == .modelAssisted,
                  !activeModelWasUnavailable,
                  let judge
            else { return nil }
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
