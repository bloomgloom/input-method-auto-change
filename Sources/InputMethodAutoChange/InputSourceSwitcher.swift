import Carbon
import Foundation

/// Wraps the Carbon Text Input Source Services (the same mechanism the
/// `im-select` CLI tool uses) to read and switch the active system input
/// source between English/ABC and Korean 2-beolsik.
enum InputSourceSwitcher {
    private static let koreanInputSourceID = "com.apple.inputmethod.Korean.2SetKorean"
    private static let englishInputSourceIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US",
    ]

    static func currentLayout() -> Layout? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        if id == koreanInputSourceID { return .korean }
        if englishInputSourceIDs.contains(id) { return .english }
        return nil
    }

    static func switchTo(_ layout: Layout) {
        let candidateIDs = layout == .korean ? [koreanInputSourceID] : englishInputSourceIDs
        guard let source = firstAvailableInputSource(matching: candidateIDs) else { return }
        TISSelectInputSource(source)
    }

    private static func firstAvailableInputSource(matching ids: [String]) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for id in ids {
            if let match = list.first(where: { source in
                guard let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
                let sourceID = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
                return sourceID == id
            }) {
                return match
            }
        }
        return nil
    }
}
