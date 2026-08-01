import Testing
@testable import InputMethodAutoChange

@Suite("LayoutMaps")
struct LayoutMapsTests {
    @Test("spot-check known English letter keycodes")
    func englishSpotCheck() {
        #expect(LayoutMaps.decode(keyCode: 0x00, shift: false, layout: .english) == "a")
        #expect(LayoutMaps.decode(keyCode: 0x00, shift: true, layout: .english) == "A")
        #expect(LayoutMaps.decode(keyCode: 0x28, shift: false, layout: .english) == "k")
    }

    @Test("spot-check known 2-beolsik jamo keycodes")
    func koreanSpotCheck() {
        #expect(LayoutMaps.decode(keyCode: 0x02, shift: false, layout: .korean) == "ㅇ")
        #expect(LayoutMaps.decode(keyCode: 0x28, shift: false, layout: .korean) == "ㅏ")
        #expect(LayoutMaps.decode(keyCode: 0x01, shift: false, layout: .korean) == "ㄴ")
        #expect(LayoutMaps.decode(keyCode: 0x0F, shift: false, layout: .korean) == "ㄱ")
        #expect(LayoutMaps.decode(keyCode: 0x0F, shift: true, layout: .korean) == "ㄲ")
    }

    @Test("unmapped keycode (e.g. a digit) decodes to nil under either layout")
    func unmappedKeycode() {
        #expect(LayoutMaps.decode(keyCode: 0x12, shift: false, layout: .english) == nil)
        #expect(LayoutMaps.decode(keyCode: 0x12, shift: false, layout: .korean) == nil)
    }

    @Test("end-to-end: dkssud typed on QWERTY decodes+composes to 안녕 under Korean")
    func dkssudEndToEnd() {
        let buffer: [BufferedKey] = "dkssud".map { char in
            let keyCode = LayoutMaps.englishBase.first { $0.value == char }!.key
            return BufferedKey(keyCode: keyCode, shift: false)
        }
        let jamos = LayoutMaps.decode(buffer, layout: .korean)
        #expect(jamos != nil)
        #expect(HangulComposer.compose(jamos!) == "안녕")
    }

    @Test("decoding a buffer with an unmapped key fails the whole word")
    func bufferWithUnmappedKeyFails() {
        let buffer = [BufferedKey(keyCode: 0x00, shift: false), BufferedKey(keyCode: 0x12, shift: false)]
        #expect(LayoutMaps.decode(buffer, layout: .english) == nil)
    }
}
