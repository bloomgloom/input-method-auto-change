import Testing
@testable import InputMethodAutoChange

@Suite("HangulComposer")
struct HangulComposerTests {
    @Test("dkssud's jamo sequence composes to 안녕")
    func basicGreeting() {
        #expect(HangulComposer.compose(Array("ㅇㅏㄴㄴㅕㅇ")) == "안녕")
    }

    @Test("compound jongseong reassignment: 값 + 이 -> 갑시")
    func compoundJongseongReassignment() {
        // ㄱㅏ + ㅂㅅ (forms ㅄ) + ㅣ: the ㅅ half of the compound jongseong
        // moves to become the next syllable's leading consonant.
        #expect(HangulComposer.compose(Array("ㄱㅏㅂㅅㅣ")) == "갑시")
    }

    @Test("simple jongseong reassignment: 한 + 이 -> 하니")
    func simpleJongseongReassignment() {
        #expect(HangulComposer.compose(Array("ㅎㅏㄴㅣ")) == "하니")
    }

    @Test("compound vowel: ㅁㅜㅓ composes to 뭐")
    func compoundVowel() {
        #expect(HangulComposer.compose(Array("ㅁㅜㅓ")) == "뭐")
    }

    @Test("double consonants (shift) compose correctly: ㄲㅏ -> 까")
    func doubleConsonant() {
        #expect(HangulComposer.compose(Array("ㄲㅏ")) == "까")
    }

    @Test("a single complete syllable with no batchim is valid")
    func simpleSyllable() {
        #expect(HangulComposer.compose(Array("ㄱㅏㄴ")) == "간")
    }

    @Test("two bare leading consonants with no vowel between them is rejected")
    func twoBareConsonants() {
        #expect(HangulComposer.compose(Array("ㄱㄴ")) == nil)
    }

    @Test("a leading bare vowel with no consonant is rejected")
    func leadingBareVowel() {
        #expect(HangulComposer.compose(Array("ㅏㄴ")) == nil)
    }

    @Test("a dangling leading consonant at the end of the word is rejected")
    func danglingLeadingConsonant() {
        #expect(HangulComposer.compose(Array("ㅎㅏㄴㄱ")) == nil)
    }

    @Test("a non-jamo character makes the whole candidate invalid")
    func nonJamoRejected() {
        #expect(HangulComposer.compose(Array("ㄱa")) == nil)
    }

    @Test("empty input has no candidate to compose")
    func emptyInput() {
        #expect(HangulComposer.compose([]) == nil)
    }

    @Test("renderBestEffort never fails: two bare consonants render as standalone jamo")
    func renderBestEffortNeverFails() {
        #expect(HangulComposer.renderBestEffort(Array("ㄱㄴ")) == "ㄱㄴ")
    }

    @Test("renderBestEffort: a well-formed sequence composes the same as compose()")
    func renderBestEffortMatchesComposeWhenValid() {
        #expect(HangulComposer.renderBestEffort(Array("ㅇㅏㄴㄴㅕㅇ")) == "안녕")
    }

    @Test("renderBestEffort: an English word decoded under Korean renders a best-effort mix of syllables and standalone jamo, rather than failing")
    func renderBestEffortHandlesEnglishWordDecodedAsKorean() {
        // "apple" on QWERTY decodes to ㅁㅔㅔㅣㄷ under 2-beolsik: ㅁ+ㅔ
        // composes to a syllable, but the repeated/orphaned vowels and the
        // dangling trailing ㄷ can't attach to anything -- the real OS IME
        // would still display all of this, just not as clean syllables
        // throughout, and this must return *something* rather than nil.
        let rendered = HangulComposer.renderBestEffort(Array("ㅁㅔㅔㅣㄷ"))
        #expect(rendered == "메ㅔㅣㄷ")
        #expect(HangulComposer.compose(Array("ㅁㅔㅔㅣㄷ")) == nil)
    }

    @Test("renderBestEffort of empty input is an empty string, not nil")
    func renderBestEffortEmptyInput() {
        #expect(HangulComposer.renderBestEffort([]) == "")
    }
}
