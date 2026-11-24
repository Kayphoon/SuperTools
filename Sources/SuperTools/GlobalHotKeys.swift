import AppKit
import SuperCapture
import Carbon

@MainActor
final class GlobalHotKeys {
    private struct Registration {
        let id: UInt32
        let reference: EventHotKeyRef
    }
    private var registrations: [NativeShortcut: Registration] = [:]
    private var handler: EventHandlerRef?
    private var captureID: UInt32?
    private var historyID: UInt32?
    var capture: (() -> Void)?
    var history: (() -> Void)?

    func start(capture: NativeShortcut = .capture, history: NativeShortcut = .history) throws {
        Diagnostics.log("hotkeys: start capture=\(capture.displayString) history=\(history.displayString)")
        try configure(capture: capture, history: history) {}
    }

    func configure(capture: NativeShortcut, history: NativeShortcut, updateCache: () throws -> Void) throws {
        try capture.validate()
        try history.validate()
        guard capture != history else { throw NativeSettingsError.duplicateShortcuts }
        if handler == nil { try installHandler() }
        var additions: [NativeShortcut: Registration] = [:]
        let usedIDs = Set(registrations.values.map(\.id))
        var availableIDs: [UInt32] = [1, 2, 3, 4].filter { !usedIDs.contains($0) }
        do {
            // Retain the old registrations until both new bindings and the cache
            // update succeed. Reuse bindings when the two actions are swapped.
            for shortcut in [capture, history] where registrations[shortcut] == nil {
                additions[shortcut] = try register(shortcut, id: availableIDs.removeFirst())
            }
            try updateCache()
        } catch {
            for registration in additions.values { UnregisterEventHotKey(registration.reference) }
            if registrations.isEmpty { stop() }
            throw error
        }
        var configured: [NativeShortcut: Registration] = [:]
        for shortcut in [capture, history] { configured[shortcut] = registrations[shortcut] ?? additions[shortcut] }
        for (shortcut, registration) in registrations where configured[shortcut] == nil {
            UnregisterEventHotKey(registration.reference)
        }
        registrations = configured
        captureID = registrations[capture]?.id
        historyID = registrations[history]?.id
        Diagnostics.log("hotkeys: configured captureID=\(captureID.map(String.init) ?? "nil") historyID=\(historyID.map(String.init) ?? "nil")")
    }

    private func installHandler() throws {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The dispatcher target, not the application target: while a menu is being
        // tracked the app runs a nested event loop, and events addressed to the
        // application target are not dispatched in it. That made the hotkey look
        // dead whenever the status item menu was open. The dispatcher sees the
        // hotkey before it is routed, so it fires in every event loop mode.
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            // Carbon dispatches application hotkeys on the application event loop.
            let keys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                Diagnostics.log("hotkeys: fired id=\(identifier.id)")
                if identifier.id == keys.captureID { keys.capture?() }
                else if identifier.id == keys.historyID { keys.history?() }
            }
            return noErr
        }, 1, &eventType, context, &handler)
        Diagnostics.log("hotkeys: InstallEventHandler status=\(status)")
        guard status == noErr else { throw HotKeyError.registration(status) }
    }

    private func register(_ shortcut: NativeShortcut, id: UInt32) throws -> Registration {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x53544F4C, id: id)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), identifier,
                                         GetApplicationEventTarget(), 0, &reference)
        Diagnostics.log("hotkeys: register \(shortcut.displayString) id=\(id) status=\(status)")
        guard status == noErr, let reference else { throw HotKeyError.registration(status) }
        return Registration(id: id, reference: reference)
    }

    func stop() {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
        captureID = nil
        historyID = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

enum HotKeyError: LocalizedError {
    case registration(OSStatus)
    var errorDescription: String? {
        switch self {
        case .registration(let status): return "全局快捷键注册失败（\(status)）。请检查所选快捷键是否被其他应用占用，或选择其他快捷键。"
        }
    }
}
