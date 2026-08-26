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
    // ponytail: CGEventPost has no flush; replace this delay with target-value
    // verification if slower editors still process the batch after 50 ms.
    private static let syntheticEventSettleDelay: TimeInterval = 0.05

    /// Every event this app posts is tagged with this marker in its
    /// `eventSourceUserData` field so `KeyEventTapManager` can recognize and
    /// ignore its own synthetic input instead of re-buffering it.
    static let syntheticEventMarker: Int64 = 0x494D_4541 // "IMEA"

    static func replace(deletingCount: Int, with replacement: String) {
        DebugLogger.log("correction replacement begin deleting=\(deletingCount) replacement={\(DebugLogger.textProfile(replacement))}")
        if replaceUsingAccessibility(deletingCount: deletingCount, with: replacement) {
            DebugLogger.log("correction text replacement handled via focused range")
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
            DebugLogger.log("undo text replacement handled via focused range")
            return
        }

        DebugLogger.log("Accessibility undo replacement unavailable; falling back to synthetic events")
        replaceUsingSyntheticEvents(deletingCount: deletingCount, with: replacement)
    }

    @discardableResult
    private static func replaceUsingSyntheticEvents(
        deletingCount: Int,
        with replacement: String
    ) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        DebugLogger.log("synthetic replacement begin deleting=\(deletingCount) eventSource=\(source == nil ? "nil" : "created") replacement={\(DebugLogger.textProfile(replacement))}")

        for _ in 0..<deletingCount {
            guard post(keyCode: backspaceKeyCode, source: source) else { return false }
        }

        guard !replacement.isEmpty else {
            DebugLogger.log("synthetic replacement completed with deletion only")
            Thread.sleep(forTimeInterval: syntheticEventSettleDelay)
            return true
        }
        let utf16 = Array(replacement.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            DebugLogger.log("synthetic replacement failed reason=unicode-event-creation")
            return false
        }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        tag(down)
        tag(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        DebugLogger.log("synthetic replacement events posted")
        Thread.sleep(forTimeInterval: syntheticEventSettleDelay)
        DebugLogger.log("synthetic replacement settled delayMs=\(Int(syntheticEventSettleDelay * 1_000))")
        return true
    }

    /// Replaces the requested range through the focused element itself.
    /// Accessibility ranges use UTF-16 offsets; every character this app can
    /// generate from its English/Korean layout maps is one UTF-16 code unit,
    /// so `deletingCount` is also the correct range length here.
    private static func replaceUsingAccessibility(deletingCount: Int, with replacement: String) -> Bool {
        guard deletingCount >= 0 else {
            DebugLogger.log("AX replacement unavailable step=validate-deletion-count")
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard focusedResult == .success, let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            DebugLogger.log("AX replacement unavailable step=focused-element status=\(focusedResult.rawValue)")
            return false
        }
        let element = focusedElementRef as! AXUIElement

        var elementPID: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &elementPID)
        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "nil"

        var selectedRangeRef: AnyObject?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )
        guard selectedRangeResult == .success, let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            DebugLogger.log("AX replacement unavailable step=selected-range status=\(selectedRangeResult.rawValue) pid=\(elementPID) pidStatus=\(pidResult.rawValue) role=\(role)")
            return false
        }
        let selectedRangeValue = selectedRangeRef as! AXValue
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
            DebugLogger.log("AX replacement unavailable step=selected-range-type pid=\(elementPID) role=\(role)")
            return false
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange),
              selectedRange.length == 0,
              selectedRange.location >= deletingCount
        else {
            DebugLogger.log("AX replacement unavailable step=selected-range-validation pid=\(elementPID) role=\(role) location=\(selectedRange.location) length=\(selectedRange.length) deleting=\(deletingCount)")
            return false
        }

        DebugLogger.log("AX replacement begin pid=\(elementPID) pidStatus=\(pidResult.rawValue) role=\(role) cursor=\(selectedRange.location) deleting=\(deletingCount)")

        var replacementRange = CFRange(
            location: selectedRange.location - deletingCount,
            length: deletingCount
        )
        let deletedProfile = textProfile(in: element, range: replacementRange)

        if role == "AXComboBox" {
            return replaceComboBoxValue(
                in: element,
                pid: elementPID,
                valueRange: replacementRange,
                with: replacement
            )
        }

        guard let replacementRangeValue = AXValueCreate(.cfRange, &replacementRange) else {
            DebugLogger.log("AX replacement unavailable step=create-replacement-range pid=\(elementPID) role=\(role)")
            return false
        }

        let setRangeResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            replacementRangeValue
        )
        guard setRangeResult == .success else {
            DebugLogger.log("AX replacement unavailable step=set-replacement-range status=\(setRangeResult.rawValue) pid=\(elementPID) role=\(role) location=\(replacementRange.location) length=\(replacementRange.length)")
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        )
        let insertedProfile = textProfile(
            in: element,
            range: CFRange(location: replacementRange.location, length: replacement.utf16.count)
        )
        DebugLogger.log(
            "AX replacement observed pid=\(elementPID) role=\(role) "
                + "requestedRange=\(replacementRange.location):\(replacementRange.length) "
                + "deleted={\(deletedProfile)} inserted={\(insertedProfile)}"
        )
        guard result == .success,
              selectionMatchesExpectedCursor(
                in: element,
                location: replacementRange.location + replacement.utf16.count
              )
        else {
            DebugLogger.log("AX replacement verification failed selectedTextStatus=\(result.rawValue) pid=\(elementPID) role=\(role) expectedCursor=\(replacementRange.location + replacement.utf16.count)")
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                selectedRangeValue
            )
            return false
        }
        DebugLogger.log("AX replacement verified pid=\(elementPID) role=\(role) finalCursor=\(replacementRange.location + replacement.utf16.count)")
        return true
    }

    private static func replaceComboBoxValue(
        in element: AXUIElement,
        pid: pid_t,
        valueRange: CFRange,
        with replacement: String
    ) -> Bool {
        guard let value = stringAttribute(element, kAXValueAttribute as CFString),
              valueRange.location >= 0,
              valueRange.length >= 0,
              valueRange.location + valueRange.length <= value.utf16.count
        else {
            DebugLogger.log("AX value replacement suppressed pid=\(pid) role=AXComboBox reason=value-range-unavailable")
            return true
        }

        let correctedValue = (value as NSString).replacingCharacters(
            in: NSRange(location: valueRange.location, length: valueRange.length),
            with: replacement
        )
        let setValueResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            correctedValue as CFString
        )

        var cursorRange = CFRange(
            location: valueRange.location + replacement.utf16.count,
            length: 0
        )
        let setCursorResult: AXError
        if let cursorValue = AXValueCreate(.cfRange, &cursorRange) {
            setCursorResult = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                cursorValue
            )
        } else {
            setCursorResult = .failure
        }

        let valueVerified = stringAttribute(element, kAXValueAttribute as CFString) == correctedValue
        let cursorVerified = selectionMatchesExpectedCursor(in: element, location: cursorRange.location)
        DebugLogger.log(
            "AX value replacement observed pid=\(pid) role=AXComboBox "
                + "setValueStatus=\(setValueResult.rawValue) setCursorStatus=\(setCursorResult.rawValue) "
                + "valueVerified=\(valueVerified) cursorVerified=\(cursorVerified)"
        )
        return true
    }

    private static func textProfile(in element: AXUIElement, range: CFRange) -> String {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return "range-value-unavailable" }

        var textRef: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textRef
        )
        guard result == .success, let text = textRef as? String else {
            return "unavailable(status=\(result.rawValue))"
        }
        return DebugLogger.textProfile(text)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
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

    private static func post(keyCode: CGKeyCode, source: CGEventSource?) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        tag(down)
        tag(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    private static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
    }
}
