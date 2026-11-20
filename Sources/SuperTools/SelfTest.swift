import AppKit
import SuperCapture

/// Headless diagnostic entry point (`SuperTools --self-test`).
///
/// Exercises the real bundle's ScreenCaptureKit path and overlay presentation
/// without a menu bar, so "pressed the hotkey and nothing happened" can be
/// split into: no permission, no capture, or no window on screen.
///
/// AppKit event sources (ScreenCaptureKit completion, NSAnimationContext) need a
/// running main run loop, so this drives `NSApp.run()` and stops itself instead
/// of blocking the main thread on a semaphore.
@MainActor
final class SelfTest: NSObject, NSApplicationDelegate {
    static func run() {
        let app = NSApplication.shared
        let test = SelfTest()
        app.delegate = test
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(test) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.log("=== self-test start (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
        Diagnostics.log("bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)")
        Diagnostics.log("screens=\(NSScreen.screens.map { "\($0.frame)@\($0.backingScaleFactor)" }.joined(separator: " | "))")

        let preflight = CGPreflightScreenCaptureAccess()
        Diagnostics.log("CGPreflightScreenCaptureAccess=\(preflight)")
        if !preflight {
            Diagnostics.log("requesting screen capture access; a system prompt may appear")
            _ = CGRequestScreenCaptureAccess()
        }

        Task { @MainActor in
            let grabber = ScreenGrabber()
            do {
                let frames = try await grabber.capture()
                for frame in frames {
                    Diagnostics.log("capture frame=\(frame.frame) px=\(frame.image.width)x\(frame.image.height)")
                }
                Diagnostics.log("capture OK frames=\(frames.count)")
            } catch {
                Diagnostics.log("capture FAILED: \(error.localizedDescription)")
            }

            let overlay = OverlayWindowController()
            overlay.onCapture = { _, _ in Diagnostics.log("overlay onCapture fired") }
            overlay.onError = { error in Diagnostics.log("overlay error: \(error.localizedDescription)") }
            overlay.present()
            Diagnostics.log("overlay.present() called")

            try? await Task.sleep(nanoseconds: 1_500_000_000)

            let visible = NSApp.windows.filter { $0.isVisible }.map {
                "\(type(of: $0)) frame=\($0.frame) alpha=\($0.alphaValue) level=\($0.level.rawValue)"
            }
            Diagnostics.log("visible windows: \(visible.isEmpty ? "none" : visible.joined(separator: " | "))")
            overlay.cancel()
            Diagnostics.log("=== self-test end ===")
            NSApp.stop(nil)
            NSApp.terminate(nil)
        }
    }
}
