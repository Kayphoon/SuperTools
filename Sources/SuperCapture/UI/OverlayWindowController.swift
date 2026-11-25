import AppKit

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class OverlayWindowController {
    enum Tool { case selection, rectangle, mosaic }
    private enum Gesture {
        case create(CGPoint), move(CGPoint, CGRect), resize(ResizeHandle, CGRect), annotate(CGPoint)
    }

    private var panels: [CapturePanel] = []
    private var frames: [DisplayFrame] = []
    private var captureTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var gesture: Gesture?
    private var annotations: [CaptureAnnotation] = []
    private var pendingAnnotation: CaptureAnnotation?
    private var scrollCapture: ScrollCaptureController?
    private var generation = 0
    private var isPresented = false
    private let grabber = ScreenGrabber()
    private let colors: [NSColor] = [.systemRed, .systemYellow, .systemBlue]
    private let widths: [CGFloat] = [2, 4, 6]
    var selection = CGRect.null
    var tool: Tool = .selection
    var colorIndex = 0
    var widthIndex = 0
    /// Confirmation keys, configured by the host and read only while the overlay
    /// owns the keyboard. Defaults: Return copies the image, Space copies OCR text.
    public var imageKey = ActionKey.imageDefault
    public var textKey = ActionKey.textDefault
    var isDragging: Bool { gesture != nil }
    var visibleAnnotations: [CaptureAnnotation] { annotations + (pendingAnnotation.map { [$0] } ?? []) }
    var statusText: String {
        if isPresented && frames.isEmpty { return "正在读取屏幕 · Esc 取消" }
        let toolName: String
        switch tool {
        case .selection: toolName = "选区"
        case .rectangle: toolName = "矩形"
        case .mosaic: toolName = "马赛克"
        }
        let colorName = ["红", "黄", "蓝"][colorIndex]
        return selection.isNull ? "拖动框选 · Esc 取消" :
            "\(Int(selection.width)) × \(Int(selection.height)) · \(toolName) · \(colorName) · \(Int(widths[widthIndex])) pt · \(imageKey.displayString) 复制 · \(textKey.displayString) 取字 · L 长截图 · Esc 取消"
    }

    public var onCapture: ((CGImage, Bool) -> Void)?
    public var onError: ((Error) -> Void)?

    public init() {
        preparePanels()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // This notification fires for changes that do not alter the capture
                // geometry (the Dock appearing when the activation policy changes is one
                // of them). Rebuilding the panels then would tear down a live overlay.
                let current = NSScreen.screens.map(\.frame)
                let prepared = self.panels.map(\.frame)
                Diagnostics.log("overlay: screen parameters changed, prepared=\(prepared.count) current=\(current.count) same=\(prepared == current)")
                guard prepared != current else { return }
                self.cancel()
                self.preparePanels()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isPresented else { return false }
                let isOurPanel = event.window.map { window in self.panels.contains { $0 === window } } ?? false
                Diagnostics.log("overlay: keyDown \(event.keyCode) window=OURS:\(isOurPanel) active=\(NSApp.isActive)")
                guard event.keyCode != 48, isOurPanel,
                      let canvas = event.window?.contentView as? CanvasView else { return false }
                canvas.keyDown(with: event)
                return true
            }
            return consumed ? nil : event
        }
    }

    public func present() {
        Diagnostics.log("overlay: present() captureTaskNil=\(captureTask == nil) isPresented=\(isPresented) panels=\(panels.count)")
        guard captureTask == nil, !isPresented else {
            Diagnostics.log("overlay: present() ignored — already presenting")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            Diagnostics.log("overlay: no screen recording permission — requesting")
            CGRequestScreenCaptureAccess()
            onError?(CaptureError.permissionRequired)
            return
        }
        Diagnostics.log("overlay: permission OK, capturing \(panels.count) panel(s)")
        generation += 1
        let token = generation
        selection = .null
        annotations.removeAll()
        tool = .selection
        isPresented = true
        // Capture before anything is shown or activated. Taking focus first makes the
        // system redraw the menu bar for this process, and grabbing mid-redraw froze
        // a half-drawn menu bar into the screenshot. The overlays are excluded from
        // the filter anyway, so they do not need to be on screen for the grab.
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let images = try await grabber.capture()
                try Task.checkCancellation()
                guard token == generation else {
                    Diagnostics.log("overlay: capture superseded (token \(token) != \(self.generation))")
                    return
                }
                frames = images
                Diagnostics.log("overlay: captured \(images.count) frame(s)")
                for (panel, display) in zip(panels, images) {
                    guard let canvas = panel.contentView as? CanvasView else { continue }
                    canvas.displayFrame = display.frame
                    canvas.image = display.image
                    panel.setFrame(display.frame, display: false)
                    canvas.refresh()
                }
                present(images.count)
            } catch is CancellationError {
                Diagnostics.log("overlay: capture cancelled")
            } catch {
                Diagnostics.log("overlay: capture failed — \(error.localizedDescription)")
                if token == generation {
                    cancel()
                    onError?(error)
                }
            }
            if token == generation { captureTask = nil }
        }
    }

    /// Put the already-grabbed frames on screen and take the keyboard.
    ///
    /// Deliberately does not change the activation policy: promoting to `.regular`
    /// makes the system draw a Dock tile and a real menu bar for this process, which
    /// flickered whenever the overlay opened. An `.accessory` process can still own
    /// the key window, so activation plus `makeKey` is enough.
    private func present(_ frameCount: Int) {
        // Activate first and hold the panels back until activation has
        // landed. Showing the frozen frames immediately and letting the
        // activation (and its menu bar swap on every display) land
        // ~400 ms later made each trigger two staggered visual events,
        // which read as a whole-screen shake; other capture tools, which
        // present as one transition, do not do this. The grab is already
        // complete at this point, so activating now cannot contaminate it
        // the way activating before the grab did.
        NSApp.activate(ignoringOtherApps: true)
        showPanels(frameCount, attempt: 0)
    }

    /// Order the panels front once the app is active, so the frozen frame,
    /// the dim and the menu bar change arrive as a single transition. Falls
    /// back to showing anyway after ~400 ms so a stuck activation can never
    /// leave a capture session invisible.
    private func showPanels(_ frameCount: Int, attempt: Int) {
        guard isPresented else { return }
        if !NSApp.isActive && attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.showPanels(frameCount, attempt: attempt + 1)
            }
            return
        }
        for panel in panels {
            (panel.contentView as? CanvasView)?.refresh()
            // Re-assert the level: a window that was ordered out and back can come
            // back at the default floating level, hidden behind full-screen apps.
            panel.level = .screenSaver
            panel.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let activePanel = panels.first(where: { $0.frame.contains(mouse) }) ?? panels.first
        activePanel?.makeKeyAndOrderFront(nil)
        activePanel?.makeFirstResponder(activePanel?.contentView)
        // Activation lands a few hundred milliseconds later and clears the key window
        // on the way, so the panel has to be re-keyed until it sticks.
        settleKeyWindow(activePanel)
        Diagnostics.log("overlay: shown frames=\(frameCount) active=\(NSApp.isActive) key=\(activePanel?.isKeyWindow == true) policy=\(NSApp.activationPolicy().rawValue) waited=\(attempt * 20)ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            Diagnostics.log("overlay: +400ms active=\(NSApp.isActive) key=\(activePanel?.isKeyWindow == true)")
        }
    }

    /// Re-assert key-window status until activation has settled.
    ///
    /// Activation is asynchronous and clears the key window on the way, so a single
    /// `makeKey` right after `activate` is always overwritten a moment later. Retry
    /// for as long as the overlay is up and the panel still is not the key window.
    /// Re-activating on each retry matters: when the request was made while another
    /// process owned the menu (a status menu being tracked), macOS drops it, and
    /// `makeKey` alone can never fix an application that was never activated.
    private func settleKeyWindow(_ panel: CapturePanel?, attempt: Int = 0) {
        guard isPresented, let panel else { return }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !panel.isKeyWindow {
            panel.makeKey()
            panel.makeFirstResponder(panel.contentView)
        }
        // Settled past the activation landing (~400 ms): stop instead of
        // waking every 100 ms for the full two seconds — a stray
        // re-activation mid-session swaps the menu bar for no benefit.
        if attempt >= 8, NSApp.isActive, panel.isKeyWindow { return }
        guard attempt < 20 else {
            Diagnostics.log("overlay: settleKey end active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
            return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.settleKeyWindow(panel, attempt: attempt + 1)
        }
    }

    private func preparePanels() {
        for panel in panels { panel.close() }
        panels = NSScreen.screens.map { screen in
            // A plain borderless panel, not `.nonactivatingPanel`: the non-activating
            // style refuses to become the key window, so the overlay would show but
            // swallow no keystrokes (Return/Space/Esc all silently ignored).
            let panel = CapturePanel(contentRect: screen.frame, styleMask: [.borderless],
                                     backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            // `isFloatingPanel` forces the window back to .floating, so the level
            // must be assigned after it (and never through the property at all).
            panel.level = .screenSaver
            let view = CanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.displayFrame = screen.frame
            view.coordinator = self
            panel.contentView = view
            return panel
        }
    }

    private var desktop: CGRect { frames.reduce(CGRect.null) { $0.union($1.frame) } }

    func refresh() {
        for panel in panels { (panel.contentView as? CanvasView)?.refresh() }
    }

    func begin(at point: CGPoint) {
        guard isPresented, !frames.isEmpty else { return }
        if tool != .selection, selection.contains(point), annotations.count < 200 {
            gesture = .annotate(point)
        } else if !selection.isNull,
                  let handle = ResizeHandle.allCases.first(where: {
                      let p = $0.point(in: selection)
                      return abs(p.x - point.x) <= 10 && abs(p.y - point.y) <= 10
                  }) {
            gesture = .resize(handle, selection)
        } else if selection.contains(point) {
            gesture = .move(point, selection)
        } else {
            annotations.removeAll()
            selection = .null
            gesture = .create(point)
        }
        refresh()
    }

    func drag(to point: CGPoint) {
        guard let gesture else { return }
        switch gesture {
        case .create(let start):
            selection = SelectionGeometry.rectangle(from: start, to: point, within: desktop)
        case .move(let start, let original):
            // Marks stay attached to their original desktop pixels when selection changes.
            selection = SelectionGeometry.moved(original, by: CGSize(width: point.x - start.x, height: point.y - start.y),
                                                within: desktop)
        case .resize(let handle, let original):
            selection = handle.resized(original, to: point, within: desktop)
        case .annotate(let start):
            let rect = SelectionGeometry.rectangle(from: start, to: point, within: selection)
            pendingAnnotation = CaptureAnnotation(kind: tool == .mosaic ? .mosaic : .rectangle, rect: rect,
                                                  color: colors[colorIndex], lineWidth: widths[widthIndex])
        }
        refresh()
    }

    func end(at point: CGPoint) {
        drag(to: point)
        if let pendingAnnotation, pendingAnnotation.rect.width >= 1, pendingAnnotation.rect.height >= 1 {
            annotations.append(pendingAnnotation)
        }
        pendingAnnotation = nil
        gesture = nil
        if selection.width < 1 || selection.height < 1 { selection = .null }
        refresh()
    }

    func nudge(dx: CGFloat, dy: CGFloat, fast: Bool) {
        guard !selection.isNull else { return }
        let step: CGFloat = fast ? 10 : 1
        selection = SelectionGeometry.moved(selection, by: CGSize(width: dx * step, height: dy * step), within: desktop)
        refresh()
    }

    func undo() {
        if !annotations.isEmpty { annotations.removeLast() }
        refresh()
    }

    /// Hands the current selection to a manual scroll-capture session.
    ///
    /// The dim panels order out so wheel events reach the window underneath;
    /// the session shows only a mouse-transparent frame plus a small control
    /// bar. Finishing delivers the stitched image through the normal
    /// `onCapture` path (image only — annotations do not apply to a region
    /// whose content moves).
    func beginScrollCapture() {
        guard isPresented, !frames.isEmpty, gesture == nil, scrollCapture == nil,
              !selection.isNull, selection.width >= 40, selection.height >= 40 else { return }
        guard let display = frames.first(where: { $0.frame.contains(selection) }) else {
            onError?(CaptureError.scrollNeedsSingleDisplay)
            return
        }
        let session = ScrollCaptureController(selection: selection, displayFrame: display.frame)
        session.onFinish = { [weak self] image in
            guard let self else { return }
            scrollCapture = nil
            cancel()
            onCapture?(image, false)
        }
        session.onCancel = { [weak self] in
            guard let self else { return }
            scrollCapture = nil
            cancel()
        }
        scrollCapture = session
        for panel in panels { panel.orderOut(nil) }
        session.start()
    }

    func confirm(textOnly: Bool) {
        guard isPresented, !frames.isEmpty, gesture == nil else { return }
        do {
            let image = try AnnotationRenderer.render(frames: frames, selection: selection, annotations: annotations)
            cancel()
            onCapture?(image, textOnly)
        } catch {
            onError?(error)
        }
    }

    public func cancel() {
        if let scrollCapture {
            self.scrollCapture = nil
            scrollCapture.invalidate()
        }
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        isPresented = false
        for panel in panels {
            panel.orderOut(nil)
            (panel.contentView as? CanvasView)?.image = nil
            panel.contentView?.layer?.contents = nil
            panel.contentView?.needsDisplay = true
        }
        frames.removeAll()
        annotations.removeAll()
        pendingAnnotation = nil
        gesture = nil
        selection = .null
        // Back to a menu bar app once the capture finishes so no Dock icon or
        // app-switcher entry lingers after the overlay closes.
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    public func stop() {
        cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for panel in panels { panel.close() }
        panels.removeAll()
    }
}
