import Foundation

/// A file-backed log, independent of `NSLog`/the unified log -- added
/// because `log stream`/`log show` proved unreliable for actually seeing
/// this app's own messages live (level filtering, a sandboxed launch
/// context not being trusted the same way as a normal launch, ...). Every
/// call still also goes to `NSLog` (cheap, and still shows up in
/// Console.app), but the file is the reliable path: Settings' "Debug"
/// section has an "Enable Logs" checkbox and an "Export Logs…" button that
/// copies this file out to wherever the user picks, sidestepping `log`/
/// Console entirely.
enum DebugLogger {
    static let logFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputMethodAutoChange", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let queue = DispatchQueue(label: "InputMethodAutoChange.DebugLogger")

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        NSLog("InputMethodAutoChange: %@", message)
        guard AppSettings.shared.loggingEnabled else { return }
        let text = message
        queue.async {
            let line = "\(dateFormatter.string(from: Date())) \(text)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: logFileURL) }
    }

    /// A privacy-preserving description that is still enough to distinguish
    /// precomposed Hangul syllables from modern/compatibility jamo. Do not log
    /// scalar values here: exported logs may be shared for diagnosis, and the
    /// values would make the user's original text trivially recoverable.
    static func textProfile(_ text: String) -> String {
        var ascii = 0
        var hangulSyllables = 0
        var modernJamo = 0
        var compatibilityJamo = 0
        var other = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00...0x7F:
                ascii += 1
            case 0xAC00...0xD7A3:
                hangulSyllables += 1
            case 0x1100...0x11FF, 0xA960...0xA97F, 0xD7B0...0xD7FF:
                modernJamo += 1
            case 0x3130...0x318F:
                compatibilityJamo += 1
            default:
                other += 1
            }
        }

        return "graphemes=\(text.count) utf16=\(text.utf16.count) scalars=\(text.unicodeScalars.count) ascii=\(ascii) hangulSyllables=\(hangulSyllables) modernJamo=\(modernJamo) compatibilityJamo=\(compatibilityJamo) other=\(other)"
    }
}
