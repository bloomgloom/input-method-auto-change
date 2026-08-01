import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Tier-1 deterministic dictionary gate, used symmetrically for both
/// directions: is the candidate reinterpretation an actual recognized word
/// in its target language, rather than just structurally well-formed text?
/// (Any Latin string is trivially well-formed character-wise, and Hangul
/// composition succeeding only means the jamo assembled into valid syllable
/// blocks -- neither guarantees the result is a real word.)
protocol DictionaryWordChecking {
    func isRecognizedWord(_ word: String, languageCode: String) -> Bool
}

#if canImport(AppKit)
/// Backed by `NSSpellChecker`, which supports Korean ("ko") spell-checking
/// out of the box on macOS alongside English ("en") -- confirmed empirically
/// (e.g. "안녕"/"하세요" recognized, "안뇽"/made-up syllable strings are not).
/// This lets Tier 1 catch most common real words for both directions
/// without ever needing Tier 2 (the on-device model), which is the main
/// lever for reducing correction latency: Tier 2 is only worth consulting
/// for words this dictionary doesn't recognize (proper nouns, slang, new
/// coinages) rather than as the default confirmation step for every word.
struct SpellCheckerWordChecker: DictionaryWordChecking {
    func isRecognizedWord(_ word: String, languageCode: String) -> Bool {
        guard !word.isEmpty else { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: languageCode,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        // No misspelling found anywhere in the word == recognized as-is.
        return range.location == NSNotFound
    }
}
#endif

/// Backed by the Settings "User Dictionary" list (`AppSettings.shared`'s
/// `userDictionaryEntries`) -- an exact (case-insensitive), language-
/// agnostic match against any currently-enabled entry. Language-agnostic
/// because a user-added word (a name, slang, a coinage) is just as much a
/// "real word" whichever side of the correction it's being checked as.
struct UserDictionaryWordChecker: DictionaryWordChecking {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func isRecognizedWord(_ word: String, languageCode: String) -> Bool {
        guard !word.isEmpty else { return false }
        return settings.userDictionaryEntries.contains {
            $0.isEnabled && $0.word.caseInsensitiveCompare(word) == .orderedSame
        }
    }
}

/// Recognized if *any* underlying checker recognizes it -- lets the system
/// spell checker and the user's own dictionary both feed Tier 1 without
/// `DecisionEngine` needing to know there's more than one.
struct CombinedWordChecker: DictionaryWordChecking {
    private let checkers: [DictionaryWordChecking]

    init(checkers: [DictionaryWordChecking]) {
        self.checkers = checkers
    }

    func isRecognizedWord(_ word: String, languageCode: String) -> Bool {
        checkers.contains { $0.isRecognizedWord(word, languageCode: languageCode) }
    }
}
