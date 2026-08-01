import AppKit
import CoreGraphics
import Foundation

/// The global, layout-independent keystroke listener. Runs a `.defaultTap`
/// `CGEventTap` (needs Accessibility trust, which the app already requires
/// for `CGEventPost` anyway) rather than `.listenOnly`: it never modifies or
/// swallows the real keystrokes it observes *except* for one specific case
/// -- a Cmd+Z immediately following one of our own corrections, which it
/// intercepts to perform a precise revert instead of letting the app's own
/// undo (which wouldn't cleanly restore the original word or the input
/// source) handle it. Every other keystroke is passed through unchanged.
final class KeyEventTapManager {
    /// One entry in the running log of everything typed since the last time
    /// no correction was pending. Needed because a correction's own decide()
    /// call (especially Tier 2) can take long enough that the user keeps
    /// typing before it resolves -- see `triggerDecision` for how this gets
    /// replayed.
    private enum LogEntry {
        case key(BufferedKey)
        case boundary(BufferedKey)
    }

    /// What's needed to precisely reverse the most recent correction: the
    /// exact text that was on screen before it (to retype verbatim) and the
    /// layout to switch back to, plus how much of our own retype to delete.
    private struct CorrectionRecord {
        let originalText: String
        let originalLayout: Layout
        let correctedLength: Int
    }

    /// Continues the custom undo sequence after a correction was restored:
    /// one more Cmd+Z removes the restored original input, then further
    /// repeated Cmd+Z presses are swallowed so the host app's now-stale undo
    /// entries cannot toggle between corrected and original text.
    private enum CustomUndoContinuation {
        case restoredOriginal(length: Int)
        case exhausted
    }

    private static let undoKeyCode: RawKeyCode = 0x06 // 'z'
    private static let deleteKeyCode: RawKeyCode = 0x33 // Backspace

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var wordBuffer = WordBuffer()
    private var lastFrontmostBundleID: String?
    private var lastCorrection: CorrectionRecord?
    private var customUndoContinuation: CustomUndoContinuation?
    /// Incremented whenever the cursor/focus/input context may have changed.
    /// An asynchronous decision only edits text if this still matches the
    /// value captured at its word boundary.
    private var contextGeneration: UInt64 = 0

    /// Everything typed since the oldest still-in-flight correction was
    /// triggered (or empty, if none are in flight). Only ever mutated on the
    /// main thread (the tap callback's thread) or via `MainActor.run` from
    /// within a correction's task, so the two never race.
    private var sessionLog: [LogEntry] = []
    private var pendingCorrectionsInFlight = 0

    /// Chains corrections (and reverts) so their actual text edits always
    /// apply in the order they were triggered, even though the (possibly
    /// slow) Tier 2 decision for a correction can resolve out of order.
    private var applyChain: Task<Void, Never> = Task {}

    private let settings: AppSettings
    private let decisionEngine: DecisionEngine

    init(settings: AppSettings, decisionEngine: DecisionEngine) {
        self.settings = settings
        self.decisionEngine = decisionEngine
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyEventTapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap gets disabled if our callback is ever too slow (or the
        // user disables it in System Settings); re-enable so we don't go
        // permanently silent.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // Ignore our own synthetic backspace/retype events -- otherwise
        // we'd re-buffer the correction we just typed, causing a feedback
        // loop between TextReplacer and this tap.
        if event.getIntegerValueField(.eventSourceUserData) == TextReplacer.syntheticEventMarker {
            return Unmanaged.passRetained(event)
        }

        // A click can move focus or the insertion point without producing a
        // keyboard event. Never let a slow decision made for the old cursor
        // delete text at the new one.
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            invalidateTextContext()
            lastFrontmostBundleID = nil
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let keyCode = RawKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isPlainUndo =
            keyCode == Self.undoKeyCode
            && event.flags.contains(.maskCommand)
            && !event.flags.contains(.maskShift)
            && !event.flags.contains(.maskControl)
            && !event.flags.contains(.maskAlternate)

        // Cmd+Z right after one of our own corrections: swallow the real
        // keystroke (the app's own undo wouldn't cleanly restore the
        // original word *and* switch the input source back -- see
        // `revertLastCorrection`) and do a precise reversal ourselves
        // instead. Any other keystroke invalidates this opportunity, below.
        if keyCode == Self.undoKeyCode, event.flags.contains(.maskCommand) {
            DebugLogger.log("cmd+z seen, shift=\(event.flags.contains(.maskShift)) pendingInFlight=\(pendingCorrectionsInFlight) hasLastCorrection=\(lastCorrection != nil)")
        }
        if isPlainUndo, pendingCorrectionsInFlight == 0 {
            if let record = lastCorrection {
                lastCorrection = nil
                revertLastCorrection(record)
                return nil
            }

            switch customUndoContinuation {
            case .restoredOriginal(let length):
                customUndoContinuation = .exhausted
                removeRestoredOriginal(length: length)
                return nil
            case .exhausted:
                return nil
            case nil:
                break
            }
        }
        lastCorrection = nil
        customUndoContinuation = nil

        // Command/Control-held keystrokes are shortcuts, and Option-letter
        // produces symbols/diacritics rather than the layout-map letter.
        // Don't buffer any of them as ordinary word input. Shift alone is
        // legitimate (capital letters, double consonants in Korean).
        if event.flags.contains(.maskCommand)
            || event.flags.contains(.maskControl)
            || event.flags.contains(.maskAlternate) {
            invalidateTextContext()
            return Unmanaged.passRetained(event)
        }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if bundleID != lastFrontmostBundleID {
            // Focus moved to a different app since the last keystroke, so
            // the buffer no longer reflects one continuous word typed into
            // one text field. (Cheap local property read -- unlike the
            // focused-element check below, this is fine to do on every
            // keystroke.)
            invalidateTextContext()
            lastFrontmostBundleID = bundleID
        }

        if let bundleID, settings.isExcluded(bundleIdentifier: bundleID) {
            invalidateTextContext()
            return Unmanaged.passRetained(event)
        }

        // A real Backspace: keep the buffer matching what's actually still
        // on screen instead of letting it fall through to the generic
        // append below, which would silently corrupt the buffer (its
        // keycode has no `LayoutMaps` entry, so decoding the whole buffer
        // would fail from here until the next boundary) -- this is what
        // made typing a fresh word fail to convert after deleting a
        // previous one back to empty.
        if keyCode == Self.deleteKeyCode {
            contextGeneration &+= 1
            sessionLog.removeAll(keepingCapacity: true)
            wordBuffer.deleteLast()
            return Unmanaged.passRetained(event)
        }

        // Read Shift from the key event itself. A cached flagsChanged state
        // can be stale when the tap starts while Shift is already held.
        let shiftIsDown = event.flags.contains(.maskShift)

        if WordBoundary.isBoundary(keyCode, shift: shiftIsDown) {
            let boundaryKey = BufferedKey(keyCode: keyCode, shift: shiftIsDown)
            sessionLog.append(.boundary(boundaryKey))
            if WordBoundary.triggersDecision(keyCode, shift: shiftIsDown), !wordBuffer.isEmpty {
                triggerDecision(for: wordBuffer.keys, boundaryKey: boundaryKey)
            }
            wordBuffer.reset()
            return Unmanaged.passRetained(event)
        }

        if LayoutMaps.isLetterOrJamo(keyCode: keyCode, shift: shiftIsDown) {
            let key = BufferedKey(keyCode: keyCode, shift: shiftIsDown)
            wordBuffer.append(key)
            sessionLog.append(.key(key))
            return Unmanaged.passRetained(event)
        }

        // Not a letter/jamo. Two cases:
        if LayoutMaps.literalCharacter(keyCode: keyCode, shift: shiftIsDown) != nil {
            let boundaryKey = BufferedKey(keyCode: keyCode, shift: shiftIsDown)
            // A known digit/symbol key -- e.g. the "." in "ㅈㅈㅈ.", or a
            // digit inside a mistyped word. Treat it exactly like the
            // existing punctuation boundaries below: it both ends the
            // current run *and* is itself real, on-screen text (accounted
            // for via `WordBoundary.insertedCharacter`'s digit/symbol
            // fallback), so the run typed so far gets checked immediately
            // rather than silently carrying into whatever comes after.
            // This is also what makes "안 되던 것을 한 다음 이어 치면 그 뒤로는
            // 검사가 안 됨" no longer true for digits/symbols specifically:
            // each run between them is now its own independent candidate.
            sessionLog.append(.boundary(boundaryKey))
            if !wordBuffer.isEmpty {
                triggerDecision(for: wordBuffer.keys, boundaryKey: boundaryKey)
            }
            wordBuffer.reset()
            return Unmanaged.passRetained(event)
        }

        // An unmapped, non-printing key (arrow keys, F-keys, the dedicated
        // 한자/한영 input-source-switch key, ...). Unlike the digit/symbol
        // case above, we don't know what (if anything) it put on screen, so
        // there's no safe `insertedCharacter` to compute -- just end the
        // run without attempting a correction, the same as a Command
        // shortcut or an app switch. Letting it into the buffer instead
        // would "poison" it: `LayoutMaps.decode` requires every key in a
        // buffer to resolve under a given layout, so one unmapped key would
        // silently kill the *whole* run's correction at the next boundary.
        // Reproduced by: switch input source mid-word via the 한영 key right
        // after focusing a fresh field, then type a word that would
        // otherwise correct fine -- the switch key's own keyDown used to
        // land in the buffer first and `DecisionEngine.decide()` would
        // quietly return nil for the whole thing.
        invalidateTextContext()
        return Unmanaged.passRetained(event)
    }

    private func invalidateTextContext() {
        contextGeneration &+= 1
        wordBuffer.reset()
        sessionLog.removeAll(keepingCapacity: true)
        lastCorrection = nil
        customUndoContinuation = nil
    }

    /// Runs the (possibly Tier-2-model-backed, non-trivial-latency) decision
    /// off of the tap callback so we never risk the OS disabling the tap for
    /// running too long inside it.
    ///
    /// Because this tap never blocks ordinary keystrokes, two things can
    /// already have happened by the time the decision resolves and we're
    /// ready to act:
    ///   1. The boundary key itself (space/return/sentence-ending
    ///      punctuation) has already been typed into the document, so the
    ///      deletion has to cover that character too, and the retype has to
    ///      put it back.
    ///   2. The user may have kept typing *more* words in the meantime --
    ///      backspacing a fixed count from whatever the cursor's current
    ///      position is would eat into that, not the word we meant to fix.
    ///      So we replay everything logged since this word's own boundary,
    ///      verbatim, after the correction.
    /// Multiple corrections can be in flight at once (e.g. the user typed
    /// two whole words before the first one's Tier 2 call returned);
    /// `applyChain` makes sure their actual text edits still land in
    /// trigger order, one at a time, so they never race each other.
    private func triggerDecision(for keys: [BufferedKey], boundaryKey: BufferedKey) {
        guard let currentLayout = InputSourceSwitcher.currentLayout(),
              let triggeringPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return }
        let mode = settings.llmCallMode
        let engine = decisionEngine
        let boundaryCharacter = WordBoundary.insertedCharacter(for: boundaryKey.keyCode, shift: boundaryKey.shift)
        let triggerIndex = sessionLog.count
        let triggerGeneration = contextGeneration
        pendingCorrectionsInFlight += 1

        let previousInChain = applyChain
        applyChain = Task { [weak self] in
            async let decisionResult = engine.decide(buffer: keys, currentLayout: currentLayout, mode: mode)
            async let focusedElementIsEditable = FocusedElementChecker.isFocusedElementEditableText(for: triggeringPID)
            await previousInChain.value
            guard let self else { return }

            guard await focusedElementIsEditable else {
                DebugLogger.log("correction skipped: focused element was not editable")
                await MainActor.run { self.finishPendingCorrection() }
                return
            }

            guard let decision = await decisionResult else {
                DebugLogger.log("correction skipped: decision engine returned no replacement")
                await MainActor.run { self.finishPendingCorrection() }
                return
            }

            // `TISCreateInputSourceList` (used by `InputSourceSwitcher`)
            // asserts that it's called on the main thread and crashes
            // (SIGTRAP via dispatch_assert_queue) otherwise -- this whole
            // block, including the text replacement, is kept on the main
            // actor together so that's guaranteed regardless of which
            // thread this Task's continuation happened to resume on.
            await MainActor.run {
                guard self.contextGeneration == triggerGeneration,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == triggeringPID
                else {
                    DebugLogger.log("correction skipped: input context changed before replacement")
                    self.finishPendingCorrection()
                    return
                }

                let start = min(triggerIndex, self.sessionLog.count)
                let trailingText = self.renderTrailing(self.sessionLog[start...], layout: currentLayout)
                let correctedText = decision.replacementText + boundaryCharacter + trailingText

                let deletingCount = decision.activeDisplayText.count + 1 + trailingText.count

                if currentLayout == .english, decision.targetLayout == .korean {
                    // Keep ABC active while inserting the already-composed
                    // Korean Unicode text, then switch to Korean for the
                    // user's subsequent typing. In Safari Dock web apps,
                    // changing the input source immediately before an AX
                    // text mutation can leave the focused WebKit editor's
                    // Korean composition context stale.
                    TextReplacer.replace(deletingCount: deletingCount, with: correctedText)
                    InputSourceSwitcher.switchTo(.korean)
                } else {
                    // When correcting Korean to English, leave the original
                    // ordering intact. The active Korean composition engine
                    // can otherwise intercept TextReplacer's synthetic
                    // Unicode event by its raw virtual keycode (always 0)
                    // instead of honoring its Unicode string payload.
                    InputSourceSwitcher.switchTo(decision.targetLayout)
                    TextReplacer.replace(deletingCount: deletingCount, with: correctedText)
                }

                self.lastCorrection = CorrectionRecord(
                    originalText: decision.activeDisplayText + boundaryCharacter + trailingText,
                    originalLayout: currentLayout,
                    correctedLength: correctedText.count
                )
                self.customUndoContinuation = nil
                DebugLogger.log("stored lastCorrection originalText=\(self.lastCorrection!.originalText) originalLayout=\(currentLayout) correctedLength=\(correctedText.count)")
                self.finishPendingCorrection()
            }
        }
    }

    /// Precisely undoes the most recent correction: deletes exactly what we
    /// retyped and restores the original text and input source, chained
    /// after any still-pending correction so the two can never race.
    private func revertLastCorrection(_ record: CorrectionRecord) {
        pendingCorrectionsInFlight += 1
        let previousInChain = applyChain
        applyChain = Task { [weak self] in
            await previousInChain.value
            guard let self else { return }
            await MainActor.run {
                DebugLogger.log("reverting: deletingCount=\(record.correctedLength) originalText=\(record.originalText) originalLayout=\(record.originalLayout)")

                // Retype while ABC is active, then restore the input source.
                // In the common Korean -> English correction case the
                // corrected text leaves ABC active, but the inverse direction
                // leaves the Korean IME active. Posting a Unicode-string event
                // while that IME is active is unreliable: it can interpret
                // TextReplacer's virtual keycode as fresh composing input and
                // eat or alter the original word. This is the same constraint
                // as the correction path above, except undo must restore the
                // *old* source only after the original text has been posted.
                InputSourceSwitcher.switchTo(.english)
                TextReplacer.replaceForUndo(deletingCount: record.correctedLength, with: record.originalText)
                InputSourceSwitcher.switchTo(record.originalLayout)
                self.customUndoContinuation = .restoredOriginal(length: record.originalText.count)
                self.finishPendingCorrection()
            }
        }
    }

    /// The second consecutive Cmd+Z represents undoing the user's original
    /// input itself. Handle it directly instead of exposing the host app's
    /// undo stack, which contains implementation-detail edits from our
    /// automatic correction and would otherwise oscillate between strings.
    private func removeRestoredOriginal(length: Int) {
        pendingCorrectionsInFlight += 1
        let previousInChain = applyChain
        applyChain = Task { [weak self] in
            await previousInChain.value
            guard let self else { return }
            await MainActor.run {
                TextReplacer.replaceForUndo(deletingCount: length, with: "")
                self.finishPendingCorrection()
            }
        }
    }

    private func finishPendingCorrection() {
        pendingCorrectionsInFlight -= 1
        if pendingCorrectionsInFlight == 0 {
            sessionLog.removeAll(keepingCapacity: true)
        }
    }

    /// Renders everything logged since a correction was triggered back into
    /// display text, so it can be retyped verbatim after the correction.
    /// Splits on boundary entries so any composed Korean sub-word in there
    /// renders the same way `DecisionEngine` would compute it, rather than
    /// naively decoding the whole span as one run.
    private func renderTrailing(_ entries: ArraySlice<LogEntry>, layout: Layout) -> String {
        var result = ""
        var currentRun: [BufferedKey] = []

        func flush() {
            guard !currentRun.isEmpty else { return }
            let chars = LayoutMaps.decode(currentRun, layout: layout) ?? []
            switch layout {
            case .english: result += String(chars)
            case .korean: result += HangulComposer.renderBestEffort(chars)
            }
            currentRun.removeAll()
        }

        for entry in entries {
            switch entry {
            case .key(let key):
                currentRun.append(key)
            case .boundary(let key):
                flush()
                result += WordBoundary.insertedCharacter(for: key.keyCode, shift: key.shift)
            }
        }
        flush()
        return result
    }
}

private func keyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let manager = Unmanaged<KeyEventTapManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.handle(type: type, event: event)
}
