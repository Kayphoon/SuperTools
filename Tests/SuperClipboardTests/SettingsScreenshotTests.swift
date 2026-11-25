import AppKit
import Testing
@testable import SuperTools

/// Offscreen renders of every settings page, in light and dark
/// appearance, for visual review. Lives on the screenshot branch only;
/// the workflow uploads the PNGs as a build artifact.
struct SettingsScreenshotTests {
    @Test func renderSettingsPages() async throws {
        try await MainActor.run {
            let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
                ?? (NSTemporaryDirectory() + "settings-shots")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

            let panel = SettingsPanel(settings: NativeSettings())
            let window = try #require(panel.window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))

            let names = ["general", "shortcuts", "clipboard", "about"]
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua),
                                                 ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for (index, name) in names.enumerated() {
                    panel.selectSectionForRender(index)
                    let view = try #require(window.contentView)
                    view.layoutSubtreeIfNeeded()
                    view.needsDisplay = true
                    view.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    let data = try #require(renderPNG(view))
                    let path = "\(directory)/settings-\(name)-\(appearanceName).png"
                    try data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// Renders the view at 2x into a PNG.
    private func renderPNG(_ view: NSView) -> Data? {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * 2),
                                         pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
