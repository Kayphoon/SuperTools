import AppKit
import SuperCapture

@MainActor
final class CopyNotice {
    private var panel: NSPanel?
    private var dismiss: DispatchWorkItem?

    func show(_ text: String) {
        close()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }

        let surface = GlassSurfaceView(variant: .regular, cornerRadius: 22, isInteractive: false)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        if let symbol = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) {
            let icon = NSImageView(image: symbol)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            icon.contentTintColor = .controlAccentColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(icon)
        }

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        row.addArrangedSubview(label)

        surface.contentContainer.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: surface.contentContainer.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: surface.contentContainer.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: surface.contentContainer.trailingAnchor, constant: -18),
            row.bottomAnchor.constraint(equalTo: surface.contentContainer.bottomAnchor, constant: -10)
        ])

        surface.layoutSubtreeIfNeeded()
        let fitting = surface.fittingSize
        let width = min(max(fitting.width, 180), 380)
        let height = max(fitting.height, 44)
        surface.cornerRadius = height / 2

        let targetFrame = CGRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.minY + 72,
            width: width,
            height: height
        )

        let window = NSPanel(
            contentRect: targetFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.configureLiquidGlassWindow()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.contentView = surface
        window.orderFrontRegardless()
        window.animateLiquidGlassEntrance(targetFrame: targetFrame)
        panel = window

        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func close() {
        dismiss?.cancel()
        dismiss = nil
        panel?.close()
        panel = nil
    }
}
