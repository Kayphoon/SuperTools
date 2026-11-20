import AppKit
import SuperCapture

@MainActor
final class SettingsPanel: NSWindowController, NSWindowDelegate {
    private enum RecordingTarget {
        case capture
        case history
    }

    private var settings: NativeSettings
    private var recordingTarget: RecordingTarget?
    private var keyMonitor: Any?

    private let rootGlass = GlassSurfaceView(variant: .regular, cornerRadius: 16, isInteractive: true)
    private let controlsGroup = GlassGroupView(spacing: 10)
    private let captureBadge = GlassSurfaceView(variant: .clear, cornerRadius: 8, isInteractive: false)
    private let historyBadge = GlassSurfaceView(variant: .clear, cornerRadius: 8, isInteractive: false)
    private let captureValueLabel = NSTextField(labelWithString: "")
    private let historyValueLabel = NSTextField(labelWithString: "")
    private let recordCaptureButton = NSButton(title: "录制快捷键", target: nil, action: nil)
    private let recordHistoryButton = NSButton(title: "录制快捷键", target: nil, action: nil)
    private let restoreDefaultButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let persistenceCheckbox = NSButton(
        checkboxWithTitle: "保存图片历史到磁盘缓存（最多 25 张 / 50 MB）",
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    var onApply: ((NativeSettings) throws -> Void)?

    init(settings: NativeSettings = NativeSettings()) {
        self.settings = settings
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 248),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "SuperTools 设置"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.configureLiquidGlassWindow()
        super.init(window: panel)
        panel.delegate = self
        setupViews(in: panel)
        refreshUI()
    }

    required init?(coder: NSCoder) { nil }

    private func setupViews(in panel: NSPanel) {
        panel.contentView = rootGlass
        let content = rootGlass.contentContainer

        let captureTitleLabel = NSTextField(labelWithString: "截图快捷键")
        captureTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        captureValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        captureValueLabel.alignment = .center
        captureValueLabel.translatesAutoresizingMaskIntoConstraints = false
        captureBadge.contentContainer.addSubview(captureValueLabel)
        NSLayoutConstraint.activate([
            captureValueLabel.topAnchor.constraint(equalTo: captureBadge.contentContainer.topAnchor, constant: 4),
            captureValueLabel.leadingAnchor.constraint(equalTo: captureBadge.contentContainer.leadingAnchor, constant: 10),
            captureValueLabel.trailingAnchor.constraint(equalTo: captureBadge.contentContainer.trailingAnchor, constant: -10),
            captureValueLabel.bottomAnchor.constraint(equalTo: captureBadge.contentContainer.bottomAnchor, constant: -4),
            captureBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])

        recordCaptureButton.target = self
        recordCaptureButton.action = #selector(recordCaptureShortcut)
        recordCaptureButton.applyLiquidGlassStyle()

        let captureSpacer = NSView()
        let captureRow = NSStackView(views: [captureTitleLabel, captureSpacer, captureBadge, recordCaptureButton])
        captureRow.orientation = .horizontal
        captureRow.spacing = 10
        captureRow.alignment = .centerY

        let historyTitleLabel = NSTextField(labelWithString: "剪贴板历史快捷键")
        historyTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        historyValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        historyValueLabel.alignment = .center
        historyValueLabel.translatesAutoresizingMaskIntoConstraints = false
        historyBadge.contentContainer.addSubview(historyValueLabel)
        NSLayoutConstraint.activate([
            historyValueLabel.topAnchor.constraint(equalTo: historyBadge.contentContainer.topAnchor, constant: 4),
            historyValueLabel.leadingAnchor.constraint(equalTo: historyBadge.contentContainer.leadingAnchor, constant: 10),
            historyValueLabel.trailingAnchor.constraint(equalTo: historyBadge.contentContainer.trailingAnchor, constant: -10),
            historyValueLabel.bottomAnchor.constraint(equalTo: historyBadge.contentContainer.bottomAnchor, constant: -4),
            historyBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])

        recordHistoryButton.target = self
        recordHistoryButton.action = #selector(recordHistoryShortcut)
        recordHistoryButton.applyLiquidGlassStyle()

        let historySpacer = NSView()
        let historyRow = NSStackView(views: [historyTitleLabel, historySpacer, historyBadge, recordHistoryButton])
        historyRow.orientation = .horizontal
        historyRow.spacing = 10
        historyRow.alignment = .centerY

        restoreDefaultButton.target = self
        restoreDefaultButton.action = #selector(restoreDefaults)
        restoreDefaultButton.applyLiquidGlassStyle()

        let restoreRow = NSStackView(views: [NSView(), restoreDefaultButton])
        restoreRow.orientation = .horizontal

        let divider = NSBox()
        divider.boxType = .separator

        persistenceCheckbox.target = self
        persistenceCheckbox.action = #selector(togglePersistence)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            captureRow,
            historyRow,
            restoreRow,
            divider,
            persistenceCheckbox,
            statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        controlsGroup.translatesAutoresizingMaskIntoConstraints = false
        controlsGroup.contentContainer.addSubview(stack)
        content.addSubview(controlsGroup)

        NSLayoutConstraint.activate([
            controlsGroup.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            controlsGroup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            controlsGroup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            controlsGroup.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: controlsGroup.contentContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: controlsGroup.contentContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controlsGroup.contentContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: controlsGroup.contentContainer.bottomAnchor),
            captureRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            restoreRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recordCaptureButton.widthAnchor.constraint(equalToConstant: 110),
            recordHistoryButton.widthAnchor.constraint(equalToConstant: 110)
        ])
    }

    func present(with currentSettings: NativeSettings) {
        stopRecording()
        settings = currentSettings
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        refreshUI()
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = window as? NSPanel else { return }
        panel.center()
        let targetFrame = panel.frame
        panel.makeKeyAndOrderFront(nil)
        panel.animateLiquidGlassEntrance(targetFrame: targetFrame)
    }

    func update(settings currentSettings: NativeSettings) {
        settings = currentSettings
        refreshUI()
    }

    private func refreshUI() {
        captureValueLabel.stringValue = settings.captureShortcut.displayString
        historyValueLabel.stringValue = settings.historyShortcut.displayString
        recordCaptureButton.title = recordingTarget == .capture ? "按下快捷键…" : "录制快捷键"
        recordHistoryButton.title = recordingTarget == .history ? "按下快捷键…" : "录制快捷键"
        recordCaptureButton.applyLiquidGlassStyle(active: recordingTarget == .capture)
        recordHistoryButton.applyLiquidGlassStyle(active: recordingTarget == .history)
        persistenceCheckbox.state = settings.imagePersistenceEnabled ? .on : .off
    }

    @objc private func recordCaptureShortcut() {
        if recordingTarget == .capture {
            stopRecording()
            statusLabel.stringValue = ""
            refreshUI()
        } else {
            startRecording(.capture)
        }
    }

    @objc private func recordHistoryShortcut() {
        if recordingTarget == .history {
            stopRecording()
            statusLabel.stringValue = ""
            refreshUI()
        } else {
            startRecording(.history)
        }
    }

    @objc private func restoreDefaults() {
        stopRecording()
        var updated = settings
        updated.captureShortcut = .capture
        updated.historyShortcut = .history
        applyUpdatedSettings(updated, message: "已恢复默认快捷键")
    }

    @objc private func togglePersistence() {
        stopRecording()
        var updated = settings
        updated.imagePersistenceEnabled = (persistenceCheckbox.state == .on)
        applyUpdatedSettings(updated, message: "")
    }

    private func applyUpdatedSettings(_ updated: NativeSettings, message: String) {
        do {
            try updated.validate()
            try onApply?(updated)
            settings = updated
            refreshUI()
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = message
        } catch {
            refreshUI()
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func startRecording(_ target: RecordingTarget) {
        stopRecording()
        recordingTarget = target
        refreshUI()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "请按下包含 Command / Option / Control 的组合键（Esc 取消）"
        window?.makeFirstResponder(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let activeTarget = self.recordingTarget,
                      event.window === self.window else { return false }
                if event.keyCode == 53 {
                    self.stopRecording()
                    self.statusLabel.stringValue = ""
                    self.refreshUI()
                    return true
                }
                let shortcut = NativeShortcut(keyCode: Int(event.keyCode), modifierFlags: event.modifierFlags)
                var updated = self.settings
                switch activeTarget {
                case .capture: updated.captureShortcut = shortcut
                case .history: updated.historyShortcut = shortcut
                }
                self.stopRecording()
                self.applyUpdatedSettings(updated, message: "快捷键已更新")
                return true
            }
            return consumed ? nil : event
        }
    }

    func stopRecording() {
        recordingTarget = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    override func close() {
        stopRecording()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        refreshUI()
    }

    func windowDidResignKey(_ notification: Notification) {
        if recordingTarget != nil {
            stopRecording()
            statusLabel.stringValue = ""
            refreshUI()
        }
    }
}
