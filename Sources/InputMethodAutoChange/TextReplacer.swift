import ApplicationServices
import CoreGraphics
import Foundation

/// Replaces text immediately before the cursor using synthetic backspaces
/// plus a Unicode-string keyboard event.
///
/// `deletingCount` is the on-screen rendered character count, not the raw
/// keystroke count — see `DecisionEngine`/`HangulComposer` for why those
/// differ under Korean input.
enum TextReplacer {
    private static let backspaceKeyCode: CGKeyCode = 0x33

    /// Every event this app posts is tagged with this marker in its
    /// `eventSourceUserData` field so `KeyEventTapManager` can recognize and
    /// ignore its own synthetic input instead of re-buffering it.
    static let syntheticEventMarker: Int64 = 0x494D_4541 // "IMEA"

    static func replace(deletingCount: Int, with replacement: String) {
        if replaceUsingAccessibility(deletingCount: deletingCount, with: replacement) {
            DebugLogger.log("correction text replacement completed via Accessibility")
            return
        }

        DebugLogger.log("Accessibility correction replacement unavailable; falling back to synthetic events")
        replaceUsingSyntheticEvents(deletingCount: deletingCount, with: replacement)
    }

    /// Undo restoration needs to work in editors that ignore Unicode-string
    /// keyboard events. Use a direct Accessibility range replacement there,
    /// with the synthetic path retained as a compatibility fallback.
    static func replaceForUndo(deletingCount: Int, with replacement: String) {
        if replaceUsingAccessibility(deletingCount: deletingCount, with: replacement) {
            DebugLogger.log("undo text replacement completed via Accessibility")
            return
        }

        DebugLogger.log("Accessibility undo replacement unavailable; falling back to synthetic events")
        replaceUsingSyntheticEvents(deletingCount: deletingCount, with: replacement)
    }

    private static func replaceUsingSyntheticEvents(deletingCount: Int, with replacement: String) {
        let source = CGEventSource(stateID: .hidSystemState)

        for _ in 0..<deletingCount {
            post(keyCode: backspaceKeyCode, source: source)
        }

        guard !replacement.isEmpty else { return }
        let utf16 = Array(replacement.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        tag(down)
        tag(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Replaces the requested range through the focused element itself.
    /// Accessibility ranges use UTF-16 offsets; every character this app can
    /// generate from its English/Korean layout maps is one UTF-16 code unit,
    /// so `deletingCount` is also the correct range length here.
    private static func replaceUsingAccessibility(deletingCount: Int, with replacement: String) -> Bool {
        guard deletingCount >= 0 else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success,
        let focusedElementRef,
        CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else {
            return false
        }
        let element = focusedElementRef as! AXUIElement

        var selectedRangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
        let selectedRangeRef,
        CFGetTypeID(selectedRangeRef) == AXValueGetTypeID()
        else {
            return false
        }
        let selectedRangeValue = selectedRangeRef as! AXValue
        guard AXValueGetType(selectedRangeValue) == .cfRange else { return false }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange),
              selectedRange.length == 0,
              selectedRange.location >= deletingCount
        else {
            return false
        }

        var replacementRange = CFRange(
            location: selectedRange.location - deletingCount,
            length: deletingCount
        )
        guard let replacementRangeValue = AXValueCreate(.cfRange, &replacementRange),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                replacementRangeValue
              ) == .success
        else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        )
        guard result == .success,
              selectionMatchesExpectedCursor(
                in: element,
                location: replacementRange.location + replacement.utf16.count
              )
        else {
            // We changed only the selection so far. Restore the original
            // cursor before the synthetic fallback gets a chance to run.
            // Terminal is known to report success for setting selected text
            // while leaving the range selected and the contents unchanged;
            // verifying the collapsed cursor catches that false success.
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                selectedRangeValue
            )
            return false
        }
        return true
    }

    private static func selectionMatchesExpectedCursor(in element: AXUIElement, location: Int) -> Bool {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
        let rangeRef,
        CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else {
            return false
        }

        let value = rangeRef as! AXValue
        var range = CFRange()
        return AXValueGetType(value) == .cfRange
            && AXValueGetValue(value, .cfRange, &range)
            && range.location == location
            && range.length == 0
    }

    private static func post(keyCode: CGKeyCode, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        tag(down)
        tag(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
    }
}
