import Carbon
import AppKit

final class HotkeyManager: @unchecked Sendable {
    private var hotkeyRef: EventHotKeyRef?
    private var onToggle: (() -> Void)?
    private var eventHandler: EventHandlerRef?

    static let shared = HotkeyManager()

    /// Register a global hotkey. Returns true when the system accepted it.
    ///
    /// Some macOS 15.x builds (FB15168205) refuse RegisterEventHotKey for
    /// combos whose modifiers are only Option and/or Shift (returns -9868).
    /// On this machine (macOS 26) Option+Space registers fine, so it stays the
    /// product default — the caller (AppState.registerHotkey) checks the return
    /// value and falls back to Cmd+Shift+Space when the OS says no.
    @discardableResult
    func register(modifiers: UInt32 = UInt32(optionKey), keyCode: UInt32 = 49, onToggle: @escaping () -> Void) -> Bool {
        // keyCode 49 = Space. Default Option+Space.
        self.onToggle = onToggle
        unregister()

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4D555252) // "MURR"
        hotKeyID.id = 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let refPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                mgr.onToggle?()
                return noErr
            },
            1,
            &eventType,
            refPtr,
            &eventHandler
        )

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
        if status != noErr {
            mlog("HotkeyManager: RegisterEventHotKey failed (\(status)) for modifiers=\(modifiers) keyCode=\(keyCode)")
            hotkeyRef = nil
        }
        return status == noErr
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}
