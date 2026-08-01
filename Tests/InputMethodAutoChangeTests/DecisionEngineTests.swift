import Testing
@testable import InputMethodAutoChange

/// Test double for Tier 2 — lets these tests exercise `DecisionEngine`'s
/// branching logic without touching Apple Intelligence/FoundationModels at
/// all, per the plan's testability requirement.
private final class FakeJudge: PlausibilityJudge {
    private let verdictToReturn: PlausibilityVerdict
    private(set) var callCount = 0

    init(verdict: PlausibilityVerdict) {
        self.verdictToReturn = verdict
    }

    func judge(candidate: String, language: CandidateLanguage) async -> PlausibilityVerdict {
        callCount += 1
        return verdictToReturn
    }
}

/// Test double for Tier 1's dictionary check -- a real `SpellCheckerWordChecker`
/// (NSSpellChecker) does recognize both Korean and English words on macOS,
/// but these tests need deterministic, offline control over which specific
/// words count as "in the dictionary" per case.
private struct FakeDictionaryChecker: DictionaryWordChecking {
    var recognizedWords: Set<String> = []
    func isRecognizedWord(_ word: String, languageCode: String) -> Bool {
        recognizedWords.contains(word)
    }
}

@Suite("DecisionEngine")
struct DecisionEngineTests {
    // "dkssud" on QWERTY, decoded under Korean, composes to 안녕 -- with an
    // empty fake dictionary this is *ambiguous* (structurally valid, not a
    // recognized word), which is exactly the case whose fate depends
    // entirely on `LLMCallMode`.
    private let dkssudBuffer: [BufferedKey] = [
        BufferedKey(keyCode: 0x02, shift: false), // d -> ㅇ
        BufferedKey(keyCode: 0x28, shift: false), // k -> ㅏ
        BufferedKey(keyCode: 0x01, shift: false), // s -> ㄴ
        BufferedKey(keyCode: 0x01, shift: false), // s -> ㄴ
        BufferedKey(keyCode: 0x20, shift: false), // u -> ㅕ
        BufferedKey(keyCode: 0x02, shift: false), // d -> ㅇ
    ]

    // A buffer that can't compose into valid Hangul at all: two bare
    // consonants (ㅇ, ㄱ) with no vowel between them.
    private let uncomposableBuffer: [BufferedKey] = [
        BufferedKey(keyCode: 0x02, shift: false), // d -> ㅇ
        BufferedKey(keyCode: 0x0F, shift: false), // r -> ㄱ
    ]

    @Test("dictionary-confirmed Korean candidate skips Tier 2 entirely, even in dictionaryOnly")
    func dictionaryConfirmedKoreanSkipsModel() async {
        let judge = FakeJudge(verdict: .implausible) // would reject if consulted -- it must not be
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(recognizedWords: ["안녕"]), judge: judge)
        let decision = await engine.decide(buffer: dkssudBuffer, currentLayout: .english, mode: .dictionaryOnly)
        #expect(decision?.replacementText == "안녕")
        #expect(judge.callCount == 0)
    }

    @Test("dictionary-confirmed English candidate skips Tier 2 entirely, even in modelAssisted")
    func dictionaryConfirmedEnglishSkipsModel() async {
        let buffer: [BufferedKey] = [
            BufferedKey(keyCode: 0x05, shift: false), // g -> ㅎ
            BufferedKey(keyCode: 0x04, shift: false), // h -> ㅗ
        ]
        let judge = FakeJudge(verdict: .implausible) // would reject if consulted -- it must not be
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(recognizedWords: ["gh"]), judge: judge)
        let decision = await engine.decide(buffer: buffer, currentLayout: .korean, mode: .modelAssisted)
        #expect(decision?.replacementText == "gh")
        #expect(judge.callCount == 0)
    }

    @Test("dictionaryOnly never consults Tier 2 for an ambiguous (non-dictionary) candidate -- leaves it alone")
    func dictionaryOnlyNeverAsksModelForAmbiguousCandidate() async {
        let judge = FakeJudge(verdict: .plausible) // would accept if consulted -- it must not be
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: judge)
        let decision = await engine.decide(buffer: dkssudBuffer, currentLayout: .english, mode: .dictionaryOnly)
        #expect(decision == nil)
        #expect(judge.callCount == 0)
    }

    @Test("dictionaryOnly with no candidate text at all is a no-op")
    func dictionaryOnlyNoCandidateIsNoOp() async {
        let judge = FakeJudge(verdict: .plausible)
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: judge)
        let decision = await engine.decide(buffer: uncomposableBuffer, currentLayout: .english, mode: .dictionaryOnly)
        #expect(decision == nil)
        #expect(judge.callCount == 0)
    }

    @Test("modelAssisted accepts an ambiguous candidate the model finds plausible")
    func modelAssistedAcceptsPlausibleAmbiguousCandidate() async {
        let judge = FakeJudge(verdict: .plausible)
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: judge)
        let decision = await engine.decide(buffer: dkssudBuffer, currentLayout: .english, mode: .modelAssisted)
        #expect(decision?.replacementText == "안녕")
        #expect(decision?.targetLayout == .korean)
        #expect(judge.callCount == 1)
    }

    @Test("modelAssisted rejects an ambiguous candidate the model finds implausible")
    func modelAssistedRejectsImplausibleAmbiguousCandidate() async {
        let judge = FakeJudge(verdict: .implausible)
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: judge)
        let decision = await engine.decide(buffer: dkssudBuffer, currentLayout: .english, mode: .modelAssisted)
        #expect(decision == nil)
        #expect(judge.callCount == 1)
    }

    @Test("modelAssisted: an ambiguous candidate from the reverse (Korean-active) direction still reaches the model")
    func modelAssistedReachesModelFromKoreanActiveLayout() async {
        // Active layout Korean composes fine to a complete syllable ("호");
        // the candidate English decoding ("gh") isn't a dictionary word,
        // making it ambiguous -- modelAssisted should still ask.
        let buffer: [BufferedKey] = [
            BufferedKey(keyCode: 0x05, shift: false), // g -> ㅎ
            BufferedKey(keyCode: 0x04, shift: false), // h -> ㅗ
        ]
        let judge = FakeJudge(verdict: .plausible)
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: judge)
        let decision = await engine.decide(buffer: buffer, currentLayout: .korean, mode: .modelAssisted)
        #expect(decision?.replacementText == "gh")
        #expect(decision?.targetLayout == .english)
        #expect(judge.callCount == 1)
    }

    @Test("modelAssisted: no candidate text at all is still a no-op, model not called")
    func modelAssistedNoCandidateIsNoOp() async {
        let judge = FakeJudge(verdict: .plausible)
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: judge)
        let decision = await engine.decide(buffer: uncomposableBuffer, currentLayout: .english, mode: .modelAssisted)
        #expect(decision == nil)
        #expect(judge.callCount == 0)
    }

    @Test("modelAssisted with the model unavailable does not correct an ambiguous candidate")
    func modelAssistedUnavailableModelDoesNotCorrect() async {
        let judge = FakeJudge(verdict: .unavailable)
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: judge)
        let decision = await engine.decide(buffer: dkssudBuffer, currentLayout: .english, mode: .modelAssisted)
        #expect(decision == nil)
    }

    @Test("modelAssisted with no judge configured does not correct an ambiguous candidate")
    func modelAssistedNoJudgeDoesNotCorrect() async {
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: nil)
        let decision = await engine.decide(buffer: dkssudBuffer, currentLayout: .english, mode: .modelAssisted)
        #expect(decision == nil)
    }

    @Test("empty buffer is a no-op regardless of mode")
    func emptyBufferIsNoOp() async {
        let judge = FakeJudge(verdict: .plausible)
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(), judge: judge)
        let decision = await engine.decide(buffer: [], currentLayout: .english, mode: .modelAssisted)
        #expect(decision == nil)
        #expect(judge.callCount == 0)
    }

    @Test("regression: Korean-mode-but-meant-English still corrects even when the active-layout rendering doesn't cleanly compose")
    func koreanToEnglishRegressionForNonComposingActiveText() async {
        // "apple" on QWERTY, typed while Korean 2-beolsik is active. Decoded
        // under Korean this is ㅁㅔㅔㅣㄷ, which does NOT cleanly compose
        // into syllables (repeated/orphan vowels, dangling trailing
        // consonant) -- before the renderBestEffort fix, computing the
        // on-screen length via the strict `compose()` returned nil here and
        // silently aborted the whole decision, so the Korean-to-English
        // direction never fired for realistic English words. "apple" is
        // also a dictionary word, so this takes the Tier-2-skipping fast
        // path -- the model must not be consulted.
        let buffer: [BufferedKey] = [
            BufferedKey(keyCode: 0x00, shift: false), // a -> ㅁ
            BufferedKey(keyCode: 0x23, shift: false), // p -> ㅔ
            BufferedKey(keyCode: 0x23, shift: false), // p -> ㅔ
            BufferedKey(keyCode: 0x25, shift: false), // l -> ㅣ
            BufferedKey(keyCode: 0x0E, shift: false), // e -> ㄷ
        ]
        let judge = FakeJudge(verdict: .plausible)
        let engine = DecisionEngine(dictionaryChecker: FakeDictionaryChecker(recognizedWords: ["apple"]), judge: judge)
        let decision = await engine.decide(buffer: buffer, currentLayout: .korean, mode: .dictionaryOnly)
        #expect(decision?.replacementText == "apple")
        #expect(decision?.targetLayout == .english)
        #expect(decision?.activeDisplayText == "메ㅔㅣㄷ") // as actually rendered on screen
        #expect(judge.callCount == 0)
    }
}
