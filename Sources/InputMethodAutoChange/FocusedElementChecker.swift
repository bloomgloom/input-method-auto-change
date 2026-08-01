import AppKit
import ApplicationServices
import Foundation

/// Determines whether the system's currently focused UI element is an
/// editable text field, via the Accessibility API. This replaces a
/// hardcoded per-app allowlist: instead of only acting in a fixed set of
/// apps, the app acts wherever a real text field happens to be focused,
/// which naturally excludes non-text contexts (Vim normal mode, terminal
/// command lines, games using letter keys as controls) without needing to
/// enumerate every app that should or shouldn't be included.
///
/// Deliberately only consulted at word-boundary time (space/return), not on
/// every keystroke: this is a cross-process XPC call to the focused app's
/// own accessibility server, and running it on every keystroke system-wide
/// would risk adding noticeable latency to all typing everywhere, not just
/// within a text field.
enum FocusedElementChecker {
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXComboBox",
        "AXSearchField",
    ]

    /// PIDs we've already nudged into building their full accessibility
    /// tree (see `enableEnhancedAccessibilityIfNeeded`) -- only needs doing
    /// once per running process.
    private static var enhancedAccessibilityPIDs: Set<pid_t> = []
    private static let enhancedAccessibilityLock = NSLock()

    /// Delay before each retry beyond the first attempt, in seconds. A
    /// just-switched-to (or just-launched) app's accessibility server can
    /// take a beat to catch up -- observed as the first word typed into a
    /// freshly-focused document not getting corrected at all (the text
    /// itself types in fine; this check alone is what silently blocks
    /// `triggerDecision` from ever running for it). A single 50ms retry
    /// wasn't always enough for a cold-launched native app (e.g. a brand
    /// new TextEdit window), so this backs off further before giving up --
    /// still adds nothing to the overwhelmingly common case where the first
    /// attempt succeeds.
    private static let retryDelays: [TimeInterval] = [0.05, 0.15]

    static func isFocusedElementEditableText(for pid: pid_t) -> Bool {
        enableEnhancedAccessibilityIfNeeded(for: pid)
        if checkFocusedElementEditableText(attempt: 1) {
            return true
        }

        for (index, delay) in retryDelays.enumerated() {
            Thread.sleep(forTimeInterval: delay)
            if checkFocusedElementEditableText(attempt: index + 2) {
                return true
            }
        }
        return false
    }

    private static func checkFocusedElementEditableText(attempt: Int) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElementRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else {
            DebugLogger.log("no focused UI element could be retrieved via Accessibility (attempt \(attempt))")
            return false
        }
        let element = focusedElementRef as! AXUIElement

        let role = stringAttribute(element, kAXRoleAttribute as CFString)
        if let role, editableRoles.contains(role) {
            return true
        }

        // Fallback for fields that don't report one of the standard AppKit
        // roles above (Safari's address bar, System Settings' search field,
        // and various web/custom text widgets have all been reported to
        // slip past a role-only check): any element exposing a selected
        // text range is, by definition, some kind of text-editing widget
        // with a cursor/selection, regardless of what it calls its role.
        var rangeRef: AnyObject?
        let hasSelectedTextRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success

        if !hasSelectedTextRange {
            // Not touched on the hot path (only runs once or twice per word
            // boundary) -- left in to make it possible to diagnose a field
            // that still isn't detected, via Settings' "Export Logs" for
            // the reported role next time this returns false.
            DebugLogger.log("focused element not recognized as editable text (role: \(role ?? "nil"), attempt \(attempt))")
        }
        return hasSelectedTextRange
    }

    /// Chromium-based apps (Electron, and Chrome itself) don't build their
    /// full accessibility tree by default -- only once something signals
    /// that assistive tech is in use, normally VoiceOver running. Without
    /// that, `kAXFocusedUIElementAttribute` on such an app either fails
    /// outright or resolves to a container with no useful role/selected-text
    /// info, which is why a plain web `<textarea>` inside an
    /// Electron-wrapped app wasn't being detected as editable at all.
    /// Setting this attribute on the app's own `AXUIElement` is the
    /// standard, widely-used trick to force that tree to populate without
    /// actually needing VoiceOver on.
    private static func enableEnhancedAccessibilityIfNeeded(for pid: pid_t) {
        enhancedAccessibilityLock.lock()
        let wasInserted = enhancedAccessibilityPIDs.insert(pid).inserted
        enhancedAccessibilityLock.unlock()
        guard wasInserted else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }
}
