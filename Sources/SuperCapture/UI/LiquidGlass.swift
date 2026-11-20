import AppKit
import QuartzCore

@MainActor
public final class GlassSurfaceView: NSView {
    public enum Variant: Sendable {
        case regular
        case clear
    }

    public let contentContainer = NSView()
    private var backingView: NSView?

    public var cornerRadius: CGFloat {
        didSet { updateAppearance() }
    }

    public var tintColor: NSColor? {
        didSet { updateAppearance() }
    }

    public var isInteractive: Bool {
        didSet { updateAppearance() }
    }

    public let variant: Variant
    public let withinWindowBlending: Bool

    public init(
        variant: Variant = .regular,
        cornerRadius: CGFloat = 16,
        tintColor: NSColor? = nil,
        isInteractive: Bool = false,
        withinWindowBlending: Bool = false
    ) {
        self.variant = variant
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.isInteractive = isInteractive
        self.withinWindowBlending = withinWindowBlending
        super.init(frame: .zero)
        setup()
    }

    public required init?(coder: NSCoder) { nil }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = contentContainer
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
                contentContainer.topAnchor.constraint(equalTo: glass.topAnchor),
                contentContainer.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                contentContainer.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                contentContainer.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
            ])
            backingView = glass
            updateAppearance()
            return
        }
        #endif

        let visual = NSVisualEffectView()
        visual.translatesAutoresizingMaskIntoConstraints = false
        visual.state = .active
        visual.blendingMode = withinWindowBlending ? .withinWindow : .behindWindow
        visual.material = variant == .clear ? .hudWindow : .popover
        visual.wantsLayer = true
        visual.addSubview(contentContainer)
        addSubview(visual)
        NSLayoutConstraint.activate([
            visual.topAnchor.constraint(equalTo: topAnchor),
            visual.leadingAnchor.constraint(equalTo: leadingAnchor),
            visual.trailingAnchor.constraint(equalTo: trailingAnchor),
            visual.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.topAnchor.constraint(equalTo: visual.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: visual.bottomAnchor)
        ])
        backingView = visual
        updateAppearance()
    }

    private func updateAppearance() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backingView as? NSGlassEffectView {
            glass.style = (variant == .clear) ? .clear : .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = isInteractive
            }
            return
        }
        #endif

        if let visual = backingView as? NSVisualEffectView {
            visual.material = variant == .clear ? .hudWindow : .popover
            visual.layer?.cornerRadius = cornerRadius
            visual.layer?.masksToBounds = true
            visual.layer?.backgroundColor = tintColor?.cgColor
        }
    }
}

@MainActor
public final class GlassGroupView: NSView {
    public let contentContainer = NSView()
    private var backingView: NSView?

    public var spacing: CGFloat {
        didSet { updateSpacing() }
    }

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
        super.init(frame: .zero)
        setup()
    }

    public required init?(coder: NSCoder) { nil }

    private func setup() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.spacing = spacing
            container.contentView = contentContainer
            addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: topAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
                contentContainer.topAnchor.constraint(equalTo: container.topAnchor),
                contentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                contentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                contentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            backingView = container
            return
        }
        #endif

        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func updateSpacing() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let container = backingView as? NSGlassEffectContainerView {
            container.spacing = spacing
        }
        #endif
    }
}

@MainActor
public extension NSButton {
    func applyLiquidGlassStyle(active: Bool = false, accentColor: NSColor? = nil) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            bezelStyle = .glass
            bezelColor = active ? (accentColor ?? .controlAccentColor) : accentColor
            contentTintColor = active ? .labelColor : nil
            return
        }
        #endif
        bezelStyle = .rounded
        bezelColor = active ? (accentColor ?? .controlAccentColor) : accentColor
    }
}

@MainActor
public extension NSPanel {
    func configureLiquidGlassWindow() {
        if styleMask.contains(.titled) {
            styleMask.insert(.fullSizeContentView)
            titlebarAppearsTransparent = true
        }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
    }

    func animateLiquidGlassEntrance( targetFrame: CGRect? = nil) {
        let finalFrame = targetFrame ?? frame
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if let targetFrame { setFrame(targetFrame, display: true) }
            alphaValue = 1
            return
        }
        var startFrame = finalFrame
        startFrame.origin.y -= 8
        setFrame(startFrame, display: false)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(finalFrame, display: true)
        }
    }
}
