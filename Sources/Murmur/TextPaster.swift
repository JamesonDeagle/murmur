import AppKit
import Carbon

enum TextPaster {
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

        mlog("TextPaster: Cmd+V posted, trusted=\(AXIsProcessTrusted()), text persisted to clipboard")
    }
}
