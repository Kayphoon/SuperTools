import AppKit

@MainActor
final class CanvasView: NSView {
    weak var coordinator: OverlayWindowController?
    var displayFrame = CGRect.zero
    var image: CGImage?

    private let toolbarSurface = GlassSurfaceView(
        variant: .regular,
        cornerRadius: 16,
        isInteractive: true,
        withinWindowBlending: true
    )
    private let toolbarGroup = GlassGroupView(spacing: 6)
    private let toolbar = NSStackView()
    private var toolButtons: [OverlayWindowController.Tool: NSButton] = [:]

    private let instructionSurface = GlassSurfaceView(
        variant: .clear,
        cornerRadius: 15,
        isInteractive: false,
        withinWindowBlending: true
    )
    private let instruction = NSTextField(labelWithString: "拖动框选 · Esc 取消")

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Keep the backing layer at native device scale so the Retina frame is
        // rasterised 1:1 instead of being rendered at 1x and upscaled.
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let actions: [(String, String, Selector, OverlayWindowController.Tool?)] = [
            ("选区", "V · 移动选区，拖动八个锚点调整", #selector(selectTool), .selection),
            ("矩形", "R · 矩形标注", #selector(rectangleTool), .rectangle),
            ("马赛克", "M · 马赛克", #selector(mosaicTool), .mosaic),
            ("颜色", "1 红 / 2 黄 / 3 蓝", #selector(cycleColor), nil),
            ("线宽", "[ / ] · 2 / 4 / 6 pt", #selector(cycleWidth), nil),
            ("撤销", "⌘Z", #selector(undoAnnotation), nil),
            ("长截图", "L · 滚动长截图：框选后滚动页面自动拼接", #selector(scrollCapture), nil),
            ("文字", "只识别文字并复制", #selector(copyText), nil),
            ("复制", "复制选区图片", #selector(copyImage), nil),
            ("取消", "Esc", #selector(cancel), nil)
        ]

        for (title, tooltip, action, toolKind) in actions {
            let button = NSButton(title: title, target: self, action: action)
            button.applyLiquidGlassStyle(active: toolKind == .selection)
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
            button.setContentHuggingPriority(.required, for: .horizontal)
            if let toolKind {
                toolButtons[toolKind] = button
            }
            toolbar.addArrangedSubview(button)
        }

        toolbarGroup.translatesAutoresizingMaskIntoConstraints = false
        toolbarGroup.contentContainer.addSubview(toolbar)
        toolbarSurface.contentContainer.addSubview(toolbarGroup)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: toolbarGroup.contentContainer.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: toolbarGroup.contentContainer.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: toolbarGroup.contentContainer.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: toolbarGroup.contentContainer.bottomAnchor),
            toolbarGroup.topAnchor.constraint(equalTo: toolbarSurface.contentContainer.topAnchor),
            toolbarGroup.leadingAnchor.constraint(equalTo: toolbarSurface.contentContainer.leadingAnchor),
            toolbarGroup.trailingAnchor.constraint(equalTo: toolbarSurface.contentContainer.trailingAnchor),
            toolbarGroup.bottomAnchor.constraint(equalTo: toolbarSurface.contentContainer.bottomAnchor)
        ])
        addSubview(toolbarSurface)
        toolbarSurface.isHidden = true

        instruction.font = .systemFont(ofSize: 13, weight: .medium)
        instruction.textColor = .labelColor
        instruction.alignment = .center
        instruction.translatesAutoresizingMaskIntoConstraints = false
        instructionSurface.contentContainer.addSubview(instruction)
        NSLayoutConstraint.activate([
            instruction.topAnchor.constraint(equalTo: instructionSurface.contentContainer.topAnchor, constant: 6),
            instruction.leadingAnchor.constraint(equalTo: instructionSurface.contentContainer.leadingAnchor, constant: 14),
            instruction.trailingAnchor.constraint(equalTo: instructionSurface.contentContainer.trailingAnchor, constant: -14),
            instruction.bottomAnchor.constraint(equalTo: instructionSurface.contentContainer.bottomAnchor, constant: -6)
        ])
        addSubview(instructionSurface)

        setAccessibilityLabel("截图选区。拖动框选，箭头键微调，R 矩形，M 马赛克，回车复制图片，空格识别文字，Escape 取消。")
    }

    required init?(coder: NSCoder) { nil }

    // A display can have a different scale than the main screen (or the window can
    // move), so re-sync the layer scale whenever the canvas is attached to one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncContentsScale()
    }

    private func syncContentsScale() {
        let scale = window?.backingScaleFactor
            ?? NSScreen.screens.first(where: { $0.frame == displayFrame })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        layer?.contentsScale = scale
        toolbarSurface.layer?.contentsScale = scale
        instructionSurface.layer?.contentsScale = scale
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func refresh() {
        needsDisplay = true
        guard let coordinator else { return }
        for (kind, button) in toolButtons {
            button.applyLiquidGlassStyle(active: coordinator.tool == kind)
        }

        let selection = local(coordinator.selection)
        let shouldHideToolbar = selection.isNull || !bounds.contains(selection.center) || coordinator.isDragging
        let wasHidden = toolbarSurface.isHidden
        toolbarSurface.isHidden = shouldHideToolbar
        if !shouldHideToolbar {
            toolbarSurface.layoutSubtreeIfNeeded()
            let size = toolbarSurface.fittingSize
            toolbarSurface.frame = CGRect(
                x: min(max(selection.midX - size.width / 2, 8), max(8, bounds.width - size.width - 8)),
                y: max(8, min(selection.minY - size.height - 12, bounds.height - size.height - 8)),
                width: size.width,
                height: size.height
            )
            if wasHidden && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                toolbarSurface.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    toolbarSurface.animator().alphaValue = 1
                }
            } else {
                toolbarSurface.alphaValue = 1
            }
        }

        instruction.stringValue = coordinator.statusText
        instructionSurface.layoutSubtreeIfNeeded()
        let pillSize = instructionSurface.fittingSize
        let pillWidth = min(max(pillSize.width, 160), max(160, bounds.width - 24))
        let pillHeight = max(pillSize.height, 30)
        instructionSurface.frame = CGRect(
            x: (bounds.width - pillWidth) / 2,
            y: bounds.height - pillHeight - 20,
            width: pillWidth,
            height: pillHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let image {
            // The overlay window is sized in points, but the captured frame is in
            // backing pixels. Draw it 1:1 into the pixel-sized rect so AppKit does
            // not downsample to points and then upsample back, which is what made
            // the preview (and any selection made from it) look soft.
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
            context.restoreGState()
        }
        guard let coordinator else { return }
        let selected = local(coordinator.selection)
        let mask = NSBezierPath(rect: bounds)
        if !selected.isNull { mask.appendRect(selected) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        mask.fill()
        guard !selected.isNull else { return }
        context.saveGState()
        context.clip(to: selected)
        for annotation in coordinator.visibleAnnotations {
            let rect = local(annotation.rect)
            switch annotation.kind {
            case .rectangle:
                annotation.color.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: annotation.lineWidth / 2, dy: annotation.lineWidth / 2))
                path.lineWidth = annotation.lineWidth
                path.stroke()
            case .mosaic:
                // A solid preview keeps the sensitive region hidden even while dragging.
                NSColor.black.setFill()
                rect.fill()
            }
        }
        context.restoreGState()
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: selected.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        for handle in ResizeHandle.allCases {
            let point = handle.point(in: selected)
            let square = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            square.fill()
            NSColor.black.setStroke()
            square.frame()
        }
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.isNull ? .null : rect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
    }

    private func global(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x + displayFrame.minX, y: point.y + displayFrame.minY)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, coordinator?.selection.contains(global(event)) == true {
            coordinator?.confirm(textOnly: false)
        } else {
            coordinator?.begin(at: global(event))
        }
    }
    override func mouseDragged(with event: NSEvent) { coordinator?.drag(to: global(event)) }
    override func mouseUp(with event: NSEvent) { coordinator?.end(at: global(event)) }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return }
        let command = event.modifierFlags.contains(.command)

        // Escape always cancels, before any user-configured action key is
        // consulted, so a misconfigured key can never trap the overlay.
        if event.keyCode == 53 {
            coordinator.cancel()
            return
        }

        // Arrow keys nudge the selection; Shift fast-moves but does not change the
        // action mapping, so these stay out of the configurable path too.
        switch event.keyCode {
        case 123: coordinator.nudge(dx: -1, dy: 0, fast: event.modifierFlags.contains(.shift)); return
        case 124: coordinator.nudge(dx: 1, dy: 0, fast: event.modifierFlags.contains(.shift)); return
        case 125: coordinator.nudge(dx: 0, dy: -1, fast: event.modifierFlags.contains(.shift)); return
        case 126: coordinator.nudge(dx: 0, dy: 1, fast: event.modifierFlags.contains(.shift)); return
        default: break
        }

        // User-configured confirmation keys: one copies the image, the other runs
        // OCR and copies the recognised text. Shift+Enter / Cmd+C stay as always-
        // available shortcuts for the text action.
        if coordinator.textKey.matches(event) || (event.keyCode == 36 && event.modifierFlags.contains(.shift)) {
            coordinator.confirm(textOnly: true)
            coordinator.refresh()
            return
        }
        if coordinator.imageKey.matches(event) {
            coordinator.confirm(textOnly: false)
            coordinator.refresh()
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where command:
            coordinator.confirm(textOnly: true)
        case "z" where command:
            coordinator.undo()
        case "r" where !command:
            coordinator.tool = .rectangle
        case "m" where !command:
            coordinator.tool = .mosaic
        case "v" where !command:
            coordinator.tool = .selection
        case "1" where !command:
            coordinator.colorIndex = 0
        case "2" where !command:
            coordinator.colorIndex = 1
        case "3" where !command:
            coordinator.colorIndex = 2
        case "[" where !command:
            coordinator.widthIndex = max(0, coordinator.widthIndex - 1)
        case "]" where !command:
            coordinator.widthIndex = min(2, coordinator.widthIndex + 1)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c" where command: coordinator.confirm(textOnly: true)
            case "z" where command: coordinator.undo()
            case "r": coordinator.tool = .rectangle
            case "m": coordinator.tool = .mosaic
            case "v": coordinator.tool = .selection
            case "l": coordinator.beginScrollCapture()
            case "1": coordinator.colorIndex = 0
            case "2": coordinator.colorIndex = 1
            case "3": coordinator.colorIndex = 2
            case "[": coordinator.widthIndex = max(0, coordinator.widthIndex - 1)
            case "]": coordinator.widthIndex = min(2, coordinator.widthIndex + 1)
            default: super.keyDown(with: event)
            }
        }
        coordinator.refresh()
    }

    @objc private func selectTool() { coordinator?.tool = .selection; coordinator?.refresh() }
    @objc private func rectangleTool() { coordinator?.tool = .rectangle; coordinator?.refresh() }
    @objc private func mosaicTool() { coordinator?.tool = .mosaic; coordinator?.refresh() }
    @objc private func cycleColor() {
        guard let coordinator else { return }
        coordinator.colorIndex = (coordinator.colorIndex + 1) % 3
        coordinator.refresh()
    }
    @objc private func cycleWidth() {
        guard let coordinator else { return }
        coordinator.widthIndex = (coordinator.widthIndex + 1) % 3
        coordinator.refresh()
    }
    @objc private func undoAnnotation() { coordinator?.undo() }
    @objc private func scrollCapture() { coordinator?.beginScrollCapture() }
    @objc private func copyText() { coordinator?.confirm(textOnly: true) }
    @objc private func copyImage() { coordinator?.confirm(textOnly: false) }
    @objc private func cancel() { coordinator?.cancel() }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
