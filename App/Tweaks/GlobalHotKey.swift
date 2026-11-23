import AppKit
import Carbon.HIToolbox
import Foundation
import Tweaks

/// Registers a system-wide shortcut through Carbon's hot key API, the only public API that still
/// delivers a key combination while another app is in front.
@MainActor
final class GlobalHotKey {
    /// Carbon hands the press to one C function for every shortcut this process registered, so the
    /// actions live in a table keyed by the hot key id.
    nonisolated(unsafe) private static var actions: [UInt32: @Sendable () -> Void] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var handlerInstalled = false

    // Written only on the main actor; `deinit` cannot read main-actor state, so the two handles are
    // marked unsafe and are only read from the lifetime hooks that must release them.
    nonisolated(unsafe) private var reference: EventHotKeyRef?
    nonisolated(unsafe) private var id: UInt32?

    /// Registers `shortcut`, replacing the previous one. False when macOS refused the combination
    /// (another app already owns it).
    @discardableResult
    func register(_ shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        Self.installHandlerIfNeeded()
        let id = Self.nextID
        Self.nextID += 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D48_4B59), id: id)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        Self.actions[id] = { @Sendable in
            let run: @MainActor () -> Void = { action() }
            if Thread.isMainThread {
                MainActor.assumeIsolated { run() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { run() } }
            }
        }
        self.reference = reference
        self.id = id
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let id { Self.actions.removeValue(forKey: id) }
        reference = nil
        id = nil
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let id { Self.actions.removeValue(forKey: id) }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let action = GlobalHotKey.actions[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            action()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
