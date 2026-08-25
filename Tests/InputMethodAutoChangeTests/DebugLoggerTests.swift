import Testing
@testable import InputMethodAutoChange

@Test("text profile distinguishes composed Hangul from jamo without exposing text")
func textProfileDistinguishesHangulForms() {
    #expect(DebugLogger.textProfile("가ᄀㄱa") == "graphemes=4 utf16=4 scalars=4 ascii=1 hangulSyllables=1 modernJamo=1 compatibilityJamo=1 other=0")
}
