import AppKit
import Carbon

/// Session-scoped Carbon hotkeys for the capture overlay.
///
/// The overlay never activates the app — activation is what made Stage
/// Manager animate a full app switch on every capture — so the keys that
/// must always work (Escape and the two confirm keys) are not left to
/// panel key routing alone: they are also registered as Carbon hotkeys
/// for the duration of a session. Carbon delivers them no matter which
/// app is active and consumes them before any other handler sees them,
/// so each press is handled exactly once; every other key (tools,
/// arrows, undo) still arrives through the key panel. All registrations
/// are dropped on `stop()`, which runs on every path out of the overlay.
@MainActor
final class SessionHotKeys {
    enum Action: UInt32 {
        case escape = 1001
        case confirmImage = 1002
        case confirmText = 1003
    }

    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onAction: ((Action) -> Void)?

    /// Registers the given keys. When two entries share a key combo, the
    /// first one wins, mirroring the precedence the canvas applies
    /// (Escape, then the text key, then the image key).
    func start(keys: [(action: Action, keyCode: Int, modifiers: Int)]) {
        stop()
        guard !keys.isEmpty else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Dispatcher target, like GlobalHotKeys: the handler must fire in
        // every event-loop mode, including while a menu is being tracked.
        let installStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, let action = Action(rawValue: identifier.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let keys = Unmanaged<SessionHotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { keys.onAction?(action) }
            return noErr
        }, 1, &eventType, context, &handler)
        guard installStatus == noErr else {
            Diagnostics.log("session hotkeys: InstallEventHandler status=\(installStatus)")
            handler = nil
            return
        }
        var seen: Set<Int> = []
        for key in keys {
            let combo = key.keyCode << 16 | key.modifiers
            guard seen.insert(combo).inserted else { continue }
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x53544F4C, id: key.action.rawValue)
            let status = RegisterEventHotKey(UInt32(key.keyCode), UInt32(key.modifiers), identifier,
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references.append(reference)
            } else {
                Diagnostics.log("session hotkeys: register keyCode=\(key.keyCode) mods=\(key.modifiers) status=\(status)")
            }
        }
        Diagnostics.log("session hotkeys: registered \(references.count)/\(keys.count)")
    }

    func stop() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
