import Foundation

/// What happens to a candidate that the dictionary (Tier 1) doesn't
/// recognize as a real word -- a dictionary-confirmed candidate is *always*
/// accepted immediately in either mode, without ever consulting Tier 2; this
/// only controls the ambiguous (non-dictionary) case.
enum LLMCallMode: String, CaseIterable {
    /// Default: leave ambiguous candidates alone. Never consults the
    /// on-device model -- fastest, but only ever corrects real dictionary
    /// words.
    case dictionaryOnly
    /// Also asks the on-device model about ambiguous candidates (proper
    /// nouns, slang, new coinages) and accepts them if it says they're
    /// plausible. Slower, but covers more than dictionary words alone.
    case modelAssisted
}

/// One app the user has added to the Settings "Exceptions" tab. `isExcluded`
/// is the on/off toggle shown next to it in that list: on means this app is
/// actively skipped; off means it's still listed but corrections currently
/// work there anyway. Kept in the list either way (rather than removed when
/// toggled off), so re-excluding it later doesn't require re-adding it via
/// the app picker.
struct AppException: Codable, Equatable {
    let bundleIdentifier: String
    let displayName: String
    var isExcluded: Bool
}

/// One word the user has added to the Settings "User Dictionary" list --
/// treated as Tier-1 dictionary-confirmed (see `DecisionEngine`) whenever
/// `isEnabled` is on, the same way a real `NSSpellChecker` hit is: accepted
/// immediately, without ever consulting Tier 2. Meant for proper nouns,
/// slang, or other words the system dictionary doesn't recognize but the
/// user always wants auto-corrected on sight. Kept in the list either way
/// when toggled off (rather than removed), same reasoning as
/// `AppException.isExcluded`.
struct UserDictionaryEntry: Codable, Equatable {
    var word: String
    var isEnabled: Bool
}

/// Thin `UserDefaults` wrapper. No DI framework, no persistence layer beyond
/// what `UserDefaults` already gives us — this is a personal-use utility.
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private let llmCallModeKey = "llmCallMode"
    private let showsInMenuBarKey = "showsInMenuBar"
    private let exceptionsKey = "appExceptions"
    private let userDictionaryKey = "userDictionaryEntries"
    private let loggingEnabledKey = "loggingEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var llmCallMode: LLMCallMode {
        get {
            defaults.string(forKey: llmCallModeKey).flatMap(LLMCallMode.init(rawValue:)) ?? .dictionaryOnly
        }
        set { defaults.set(newValue.rawValue, forKey: llmCallModeKey) }
    }

    /// Whether the menu bar status item is shown. Off leaves the app running
    /// headless -- `AppDelegate.applicationShouldHandleReopen` is the way
    /// back into Settings to turn it on again.
    var showsInMenuBar: Bool {
        get { defaults.object(forKey: showsInMenuBarKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: showsInMenuBarKey) }
    }

    var appExceptions: [AppException] {
        get {
            guard let data = defaults.data(forKey: exceptionsKey),
                  let decoded = try? JSONDecoder().decode([AppException].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: exceptionsKey)
        }
    }

    /// Whether corrections should be skipped for this app -- true only when
    /// it's both in the exceptions list *and* currently toggled on there.
    func isExcluded(bundleIdentifier: String) -> Bool {
        appExceptions.first(where: { $0.bundleIdentifier == bundleIdentifier })?.isExcluded ?? false
    }

    /// Whether `DebugLogger.log` appends to its file, in addition to always
    /// going to `NSLog`/the unified log -- off by default since the file
    /// otherwise grows forever with every focus check and keystroke-tap
    /// event. See Settings' "Debug" section.
    var loggingEnabled: Bool {
        get { defaults.bool(forKey: loggingEnabledKey) }
        set { defaults.set(newValue, forKey: loggingEnabledKey) }
    }

    var userDictionaryEntries: [UserDictionaryEntry] {
        get {
            guard let data = defaults.data(forKey: userDictionaryKey),
                  let decoded = try? JSONDecoder().decode([UserDictionaryEntry].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: userDictionaryKey)
        }
    }
}
