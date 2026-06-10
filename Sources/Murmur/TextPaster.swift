import AppKit
import Carbon
import CoreGraphics

enum TextPaster {
    /// Ensure we're allowed to synthesize keyboard events (the `kTCCServicePostEvent`
    /// permission, "post events" — a sandbox-compatible alternative to full
    /// Accessibility, which App Sandbox forbids).
    ///
    /// Under App Sandbox `AXIsProcessTrustedWithOptions` never succeeds, so we
    /// gate on CoreGraphics' event-posting access instead (Apple docs:
    /// `CGRequestPostEventAccess`; Developer Forums thread 789896).
    /// `CGPreflightPostEventAccess()` reports current status without prompting;
    /// `CGRequestPostEventAccess()` triggers the one-time system prompt and
    /// returns once the user has answered.
    ///
    /// Returns true if posting events is already (or now) permitted.
    @discardableResult
    static func ensurePermission() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        _ = CGRequestPostEventAccess()
        return CGPreflightPostEventAccess()
    }

    /// Put the transcribed text on the clipboard and try to paste it into the
    /// frontmost app via simulated Cmd+V.
    ///
    /// If the user forgot to focus a text field (or the focused control
    /// rejects paste), the simulated Cmd+V is a no-op — but the text **stays
    /// on the clipboard** so they can paste it manually with Cmd+V wherever
    /// they actually wanted it. This is the dictation-friendly trade-off:
    /// we deliberately don't restore the previous clipboard contents like a
    /// "polite" clipboard tool would, because losing a dictated paragraph is
    /// worse than losing whatever was in the clipboard before.
    static func paste(_ text: String) {
        mlog("TextPaster: paste called with '\(text.prefix(50))'")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let verify = pasteboard.string(forType: .string)
        mlog("TextPaster: clipboard set, verify='\(verify?.prefix(50) ?? "nil")'")

        // Under App Sandbox we need the "post events" permission to synthesize
        // Cmd+V. If it isn't granted yet, prompt for it and bail this time —
        // the text is already on the clipboard, so the user can paste manually
        // with Cmd+V. Next dictation, once granted, will paste automatically.
        guard CGPreflightPostEventAccess() else {
            mlog("TextPaster: PostEvent access not granted — text left on clipboard, requesting access")
            _ = CGRequestPostEventAccess()
            return
        }

        // Simulate Cmd+V — works only if the frontmost app accepts paste in
        // its focused control. Failure here is silent and expected.
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 'v'
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

        mlog("TextPaster: CGEventSource=\(source != nil), keyDown=\(keyDown != nil), keyUp=\(keyUp != nil)")

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        mlog("TextPaster: Cmd+V posted, postEvent=\(CGPreflightPostEventAccess()), text persisted to clipboard")
    }
}
