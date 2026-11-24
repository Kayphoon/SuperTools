import AppKit
import CoreGraphics
import SuperCapture

/// Replays a `Command+V` into whichever app was frontmost before the history
/// panel took focus.
///
/// This is the one place the app needs the Accessibility permission: synthesising
/// key events for another process is only allowed for a trusted client. Callers
/// must therefore treat a failure as an expected, recoverable outcome (the value
/// is already on the pasteboard, so the user can just press Command+V) and never
/// block the copy path on it.
enum PasteSynthesizer {
    enum Outcome: Equatable {
        case pasted
        case permissionRequired
        case failed
    }

    /// `V` on the ANSI layout; `CGEvent` virtual key codes are layout independent.
    private static let vKeyCode: CGKeyCode = 9

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Deep link into the Accessibility pane. macOS has no API that grants the
    /// permission silently; the user must tick the checkbox themselves.
    static func openAccessibilitySettings() {
        Diagnostics.log("paster: opening Accessibility settings (trusted=\(isTrusted))")
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Ask the system to show the Accessibility prompt once, without blocking.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        Diagnostics.log("paster: permission prompt shown, trusted=\(trusted)")
    }

    /// Send `Command+V`. `target` is the app that should receive it; it is
    /// reactivated first because the history panel currently holds focus.
    @MainActor
    static func paste(into target: NSRunningApplication?) async -> Outcome {
        guard isTrusted else {
            Diagnostics.log("paster: refused — Accessibility not granted")
            return .permissionRequired
        }
        if let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target.activate(options: [])
            // The activation is asynchronous; synthesising the keystroke in the
            // same turn would deliver it to the panel that still has focus.
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            Diagnostics.log("paster: could not create the key events")
            return .failed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        Diagnostics.log("paster: posted Command+V into \(target?.bundleIdentifier ?? "the frontmost app")")
        return .pasted
    }
}

enum PasteSynthesizerError: LocalizedError {
    case failed

    var errorDescription: String? {
        "已复制到剪贴板，但没能自动发按键。请手动按 ⌘V。"
    }
}
