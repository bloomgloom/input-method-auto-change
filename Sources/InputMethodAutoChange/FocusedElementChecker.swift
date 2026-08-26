import AppKit
import ApplicationServices
import Foundation

/// Determines whether the system's currently focused UI element is an
/// editable text field, via the Accessibility API. This replaces a
/// hardcoded per-app allowlist: instead of only acting in a fixed set of
/// apps, the app acts wherever a native text field happens to be focused.
/// Web-backed fields are excluded because Accessibility replacement can
/// desynchronize their DOM/IME state.
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

    static func isFocusedElementEditableText(for pid: pid_t) -> Bool {
        enableEnhancedAccessibilityIfNeeded(for: pid)
        return checkFocusedElementEditableText()
    }

    private static func checkFocusedElementEditableText() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElementRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else {
            DebugLogger.log("no focused UI element could be retrieved via Accessibility")
            return false
        }
        let element = focusedElementRef as! AXUIElement

        // Web-backed editors can desynchronize their DOM/IME state when
        // changed through Accessibility. Missing a correction is safer than
        // corrupting composition or whitespace in browsers and Electron apps.
        if isInsideWebArea(element) {
            DebugLogger.log("focused element excluded because it is inside AXWebArea")
            return false
        }

        let role = stringAttribute(element, kAXRoleAttribute as CFString)
        if let role, editableRoles.contains(role) {
            return true
        }

        // Fallback for native fields that don't report one of the standard
        // AppKit roles above (Safari's address bar and System Settings'
        // search field can slip past a role-only check): any element exposing
        // a selected text range is, by definition, some kind of text-editing widget
        // with a cursor/selection, regardless of what it calls its role.
        var rangeRef: AnyObject?
        let hasSelectedTextRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success

        if !hasSelectedTextRange {
            // Not touched on the hot path (only runs once per word
            // boundary) -- left in to make it possible to diagnose a field
            // that still isn't detected, via Settings' "Export Logs" for
            // the reported role next time this returns false.
            DebugLogger.log("focused element not recognized as editable text (role: \(role ?? "nil"))")
        }
        return hasSelectedTextRange
    }

    private static func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current = element

        while true {
            if stringAttribute(current, kAXRoleAttribute as CFString) == "AXWebArea" {
                return true
            }

            var parentRef: AnyObject?
            guard AXUIElementCopyAttributeValue(
                current,
                kAXParentAttribute as CFString,
                &parentRef
            ) == .success,
            let parentRef,
            CFGetTypeID(parentRef) == AXUIElementGetTypeID()
            else { return false }

            current = parentRef as! AXUIElement
        }
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
