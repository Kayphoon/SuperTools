import AppKit

private final class ScrollPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Selection frame with live feedback. A green wash flashes each time a new
/// frame is stitched in, so the user can see the capture is keeping up; when
/// the page moved but no overlap matched (scrolled too fast, or a jump), the
/// frame turns orange for a moment to warn that a slice may be missing.
private final class BorderView: NSView {
    private var flashAlpha: CGFloat = 0
    private var warningUntil: Date?
    private var feedbackTimer: Timer?

    func flashCaptured() {
        flashAlpha = 0.16
        needsDisplay = true
        runFeedbackTimer()
    }

    func showWarning() {
        warningUntil = Date().addingTimeInterval(1.2)
        needsDisplay = true
        runFeedbackTimer()
    }

    private func runFeedbackTimer() {
        guard feedbackTimer == nil else { return }
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flashAlpha = max(0, self.flashAlpha - 0.02)
                let warningActive = self.warningUntil.map { Date() < $0 } ?? false
                if !warningActive { self.warningUntil = nil }
                self.needsDisplay = true
                if self.flashAlpha == 0, !warningActive {
                    self.feedbackTimer?.invalidate()
                    self.feedbackTimer = nil
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if flashAlpha > 0 {
            NSColor.systemGreen.withAlphaComponent(flashAlpha).setFill()
            bounds.fill()
        }
        let outer = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        NSColor.black.withAlphaComponent(0.55).setStroke()
        outer.lineWidth = 3
        outer.stroke()
        let inner = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        let warning = warningUntil.map { Date() < $0 } ?? false
        (warning ? NSColor.systemOrange : NSColor.white).setStroke()
        inner.lineWidth = 1.5
        inner.stroke()
    }
}

/// Manual scroll-capture session for one fixed region.
///
/// Flow: the overlay hands over a confirmed selection, this controller hides
/// the full-screen dim panels (so the user can scroll the real window with
/// the wheel — the border panel ignores mouse events entirely), photographs
/// the region five times a second, detects each scroll delta with
/// `ScrollStitcher`, and composites the color frames into one tall image.
/// No new permission is involved: frames come from the same ScreenCaptureKit
/// path as a normal capture, and finishing routes the image through the
/// existing clipboard/OCR pipeline via `onFinish`.
@MainActor
final class ScrollCaptureController {
    var onFinish: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?

    private let selection: CGRect
    private let displayFrame: CGRect
    private let grabber = ScreenGrabber()

    private var borderPanel: ScrollPanel?
    private var borderView: BorderView?
    private var controlPanel: ScrollPanel?
    private var controlSurface: GlassSurfaceView?
    private var statusLabel: NSTextField?
    private var previewView: NSImageView?
    private var previewHeightConstraint: NSLayoutConstraint?
    private var previewWidth: CGFloat = 200
    private var panelBelowSelection = true
    private var keyMonitor: Any?
    private var timer: Timer?
    private var tickInFlight = false
    private var consecutiveFailures = 0
    private var closed = false

    // Compositing state, all in top-left-origin pixel coordinates of the region.
    private var canvasImage: CGImage?
    private var canvasTop = 0        // placement-space top of the current canvas
    private var lastFrameTop = 0     // placement-space top of the last matched frame
    private var lastGray: GrayFrame?
    private var frameWidth = 0
    private var frameHeight = 0

    private static let maxPixelCount = 64_000_000   // same budget as AnnotationRenderer
    private static let maxHeight = 24_000

    init(selection: CGRect, displayFrame: CGRect) {
        self.selection = selection
        self.displayFrame = displayFrame
    }

    func start() {
        buildPanels()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    /// Tears down UI and timers without invoking either callback.
    func invalidate() {
        closed = true
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        borderPanel?.orderOut(nil)
        controlPanel?.orderOut(nil)
        borderPanel = nil
        controlPanel = nil
        borderView = nil
        controlSurface = nil
        previewView = nil
        statusLabel = nil
    }

    func finish() {
        guard !closed else { return }
        let image = canvasImage
        invalidate()
        if let image { onFinish?(image) } else { onCancel?() }
    }

    func cancel() {
        guard !closed else { return }
        invalidate()
        onCancel?()
    }

    // MARK: - Panels

    private func buildPanels() {
        let border = ScrollPanel(contentRect: selection.insetBy(dx: -2, dy: -2),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        border.level = .screenSaver
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.hidesOnDeactivate = false
        border.isFloatingPanel = true
        border.isReleasedWhenClosed = false
        border.ignoresMouseEvents = true
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let frame = BorderView(frame: CGRect(origin: .zero, size: selection.insetBy(dx: -2, dy: -2).size))
        border.contentView = frame
        borderView = frame
        border.orderFrontRegardless()
        borderPanel = border

        let surface = GlassSurfaceView(variant: .regular, cornerRadius: 14,
                                       isInteractive: true, withinWindowBlending: true)
        controlSurface = surface
        // Live preview of the stitched canvas: the only place the user can
        // actually see which parts of the page are already captured.
        previewWidth = min(max(selection.width, 140), 300)
        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        preview.layer?.cornerRadius = 8
        preview.translatesAutoresizingMaskIntoConstraints = false
        let height = preview.heightAnchor.constraint(equalToConstant: 36)
        previewHeightConstraint = height
        previewView = preview

        let label = NSTextField(labelWithString: "滚动长截图 · 滚动页面，往回滚可撤销多截部分，点完成结束")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        statusLabel = label
        let finishButton = NSButton(title: "完成", target: self, action: #selector(finishAction))
        finishButton.applyLiquidGlassStyle(active: true)
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelAction))
        cancelButton.applyLiquidGlassStyle()
        let controls = NSStackView(views: [label, finishButton, cancelButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        let stack = NSStackView(views: [preview, controls])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: surface.contentContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: surface.contentContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: surface.contentContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: surface.contentContainer.bottomAnchor),
            preview.widthAnchor.constraint(equalToConstant: previewWidth),
            height
        ])
        surface.layoutSubtreeIfNeeded()
        let size = surface.fittingSize
        panelBelowSelection = selection.minY - size.height - 10 >= displayFrame.minY + 8
        var origin = CGPoint(x: selection.midX - size.width / 2,
                             y: panelBelowSelection ? selection.minY - size.height - 10
                                                    : selection.maxY + 10)
        origin.x = min(max(origin.x, displayFrame.minX + 8), displayFrame.maxX - size.width - 8)
        origin.y = min(origin.y, displayFrame.maxY - size.height - 8)
        let control = ScrollPanel(contentRect: CGRect(origin: origin, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        control.level = .screenSaver
        control.isOpaque = false
        control.backgroundColor = .clear
        control.hasShadow = false
        control.hidesOnDeactivate = false
        control.isFloatingPanel = true
        control.isReleasedWhenClosed = false
        control.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        control.contentView = surface
        control.orderFrontRegardless()
        control.makeKey()
        controlPanel = control

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, !self.closed, event.window === self.controlPanel else { return false }
                switch event.keyCode {
                case 53: self.cancel()
                case 36, 76: self.finish()
                default: return false
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    @objc private func finishAction() { finish() }
    @objc private func cancelAction() { cancel() }

    /// Re-fits the control panel after the preview's height changes, keeping
    /// the edge nearest the selection where it was.
    private func layoutControlPanel() {
        guard let controlPanel, let controlSurface else { return }
        controlSurface.layoutSubtreeIfNeeded()
        let size = controlSurface.fittingSize
        var origin = controlPanel.frame.origin
        origin.x = selection.midX - size.width / 2
        origin.y = panelBelowSelection ? selection.minY - size.height - 10
                                       : selection.maxY + 10
        origin.x = min(max(origin.x, displayFrame.minX + 8), displayFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, displayFrame.minY + 8), displayFrame.maxY - size.height - 8)
        controlPanel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    // MARK: - Capture loop

    private func tick() {
        guard !closed, !tickInFlight else { return }
        tickInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { tickInFlight = false }
            do {
                let frames = try await grabber.capture()
                guard !closed else { return }
                consecutiveFailures = 0
                guard let crop = cropRegion(from: frames) else { return }
                accept(crop)
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures > 12 { cancel() }
            }
        }
    }

    private func cropRegion(from frames: [DisplayFrame]) -> CGImage? {
        guard let display = frames.first(where: { $0.frame == displayFrame }) ?? frames.first else { return nil }
        let pixels = SelectionGeometry.pixels(for: selection, screen: display.frame,
                                              width: display.image.width, height: display.image.height)
        guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8 else { return nil }
        return display.image.cropping(to: pixels)
    }

    private func accept(_ frame: CGImage) {
        guard let gray = Self.grayFrame(from: frame) else { return }
        guard let lastGray else {
            canvasImage = frame
            frameWidth = frame.width
            frameHeight = frame.height
            canvasTop = 0
            lastFrameTop = 0
            self.lastGray = gray
            updateFeedback()
            return
        }
        guard frame.width == frameWidth, frame.height == frameHeight else { return }
        if ScrollStitcher.meanAbsoluteDifference(lastGray, gray) < 1.2 { return }
        guard let dy = ScrollStitcher.verticalOffset(previous: lastGray, current: gray) else {
            // The page moved but no overlap matched — a slice may be missing.
            borderView?.showWarning()
            return
        }
        guard dy != 0 else { return }

        let newTop = lastFrameTop + dy
        // Scrolling back up undoes overshoot: everything captured below the
        // current viewport's bottom edge is trimmed off the canvas, so the
        // user can back out of an unwanted tail instead of restarting.
        // Scrolling down again afterwards simply re-appends.
        if dy < 0, let canvasImage {
            let currentBottom = newTop + frameHeight
            let canvasBottom = canvasTop + canvasImage.height
            if currentBottom > canvasTop, currentBottom < canvasBottom,
               let trimmed = canvasImage.cropping(to: CGRect(x: 0, y: 0, width: frameWidth,
                                                              height: currentBottom - canvasTop)) {
                self.canvasImage = trimmed
            }
        }
        let newCanvasTop = min(canvasTop, newTop)
        let newCanvasBottom = max(canvasTop + (canvasImage?.height ?? frameHeight), newTop + frameHeight)
        let newHeight = newCanvasBottom - newCanvasTop
        guard newHeight <= Self.maxHeight, newHeight * frameWidth <= Self.maxPixelCount,
              let canvasImage,
              let context = CGContext(data: nil, width: frameWidth, height: newHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            finish()
            return
        }
        // CGContext origin is bottom-left; convert top-origin placements.
        context.draw(canvasImage, in: CGRect(x: 0, y: newHeight - (canvasTop - newCanvasTop) - canvasImage.height,
                                             width: frameWidth, height: canvasImage.height))
        context.draw(frame, in: CGRect(x: 0, y: newHeight - (newTop - newCanvasTop) - frameHeight,
                                       width: frameWidth, height: frameHeight))
        guard let merged = context.makeImage() else { return }
        self.canvasImage = merged
        canvasTop = newCanvasTop
        lastFrameTop = newTop
        self.lastGray = gray
        updateFeedback()
    }

    /// Everything the user can see about capture progress lives here: the
    /// height readout, the live preview of the stitched canvas, and the
    /// border flash confirming the frame landed.
    private func updateFeedback() {
        guard let canvasImage else { return }
        statusLabel?.stringValue = "滚动长截图 · 已捕获 \(canvasImage.height) px · 往回滚可撤销，点完成结束"
        borderView?.flashCaptured()
        guard let previewView, let thumbnail = Self.thumbnail(from: canvasImage) else { return }
        previewView.image = NSImage(cgImage: thumbnail,
                                    size: NSSize(width: thumbnail.width, height: thumbnail.height))
        // The preview is the only place the user can check the stitch, so
        // let it grow well past the old 150 pt cap — up to 480 pt — but
        // never taller than the space on the panel's side of the selection,
        // so the controls stay on screen.
        let aspectHeight = previewWidth * CGFloat(thumbnail.height) / CGFloat(thumbnail.width)
        let chrome = (controlSurface?.fittingSize.height ?? 56) - (previewHeightConstraint?.constant ?? 36)
        let room = panelBelowSelection ? selection.minY - displayFrame.minY
                                       : displayFrame.maxY - selection.maxY
        let cap = max(60, min(480, room - chrome - 26))
        let displayHeight = min(cap, max(30, aspectHeight))
        if let constraint = previewHeightConstraint, abs(constraint.constant - displayHeight) > 2 {
            constraint.constant = displayHeight
            layoutControlPanel()
        }
    }

    /// Bounded downscale of the stitched canvas for the control-bar preview;
    /// proportional, at most 600×1200 px regardless of canvas size, so the
    /// enlarged preview stays crisp on Retina displays.
    private static func thumbnail(from image: CGImage) -> CGImage? {
        let scale = min(600 / CGFloat(image.width), 1200 / CGFloat(image.height), 1)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Grayscale copy at full height (so detected offsets are exact pixel rows)
    /// with the width capped for matching speed. Row 0 is the top row.
    private static func grayFrame(from image: CGImage) -> GrayFrame? {
        let height = image.height
        let width = min(image.width, 480)
        guard width >= 8, height >= 40 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? GrayFrame(width: width, height: height, pixels: pixels) : nil
    }
}
