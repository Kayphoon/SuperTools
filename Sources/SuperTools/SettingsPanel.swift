import AppKit
import SuperCapture

/// A settings window that can take the keyboard. The recording feature matches
/// incoming events against `event.window`, and a panel that never becomes key
/// silently drops every keystroke, so this cannot use `.nonactivatingPanel`.
private final class SettingsWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SettingsPanel: NSWindowController, NSWindowDelegate {
    private enum RecordingTarget {
        case capture
        case history
        case imageKey
        case textKey
    }

    private var settings: NativeSettings
    private var recordingTarget: RecordingTarget?
    private var keyMonitor: Any?

    private let rootGlass = GlassSurfaceView(variant: .regular, cornerRadius: 16, isInteractive: true)
    private let controlsGroup = GlassGroupView(spacing: 10)
    private let captureBadge = GlassSurfaceView(variant: .clear, cornerRadius: 8, isInteractive: false)
    private let historyBadge = GlassSurfaceView(variant: .clear, cornerRadius: 8, isInteractive: false)
    private let imageKeyBadge = GlassSurfaceView(variant: .clear, cornerRadius: 8, isInteractive: false)
    private let textKeyBadge = GlassSurfaceView(variant: .clear, cornerRadius: 8, isInteractive: false)
    private let captureValueLabel = NSTextField(labelWithString: "")
    private let historyValueLabel = NSTextField(labelWithString: "")
    private let imageKeyValueLabel = NSTextField(labelWithString: "")
    private let textKeyValueLabel = NSTextField(labelWithString: "")
    private let recordCaptureButton = NSButton(title: "录制快捷键", target: nil, action: nil)
    private let recordHistoryButton = NSButton(title: "录制快捷键", target: nil, action: nil)
    private let recordImageKeyButton = NSButton(title: "录制按键", target: nil, action: nil)
    private let recordTextKeyButton = NSButton(title: "录制按键", target: nil, action: nil)
    private let restoreDefaultButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let persistenceCheckbox = NSButton(
        checkboxWithTitle: "保存图片历史到磁盘缓存（最多 25 张 / 50 MB）",
        target: nil,
        action: nil
    )
    private let pasteCheckbox = NSButton(
        checkboxWithTitle: "选中历史后直接粘贴到原窗口（需要辅助功能权限）",
        target: nil,
        action: nil
    )
    private let hideMenuBarCheckbox = NSButton(
        checkboxWithTitle: "隐藏菜单栏图标（快捷键照常可用，再次打开 SuperTools 可恢复）",
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    var onApply: ((NativeSettings) throws -> Void)?

    init(settings: NativeSettings = NativeSettings()) {
        self.settings = settings
        let panel = SettingsWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 424),
            styleMask: [.titled, .closable, .fullSizeContentView],
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

        // Action keys: read only while the capture overlay owns the keyboard, so a
        // bare Return / Space is legitimate here (unlike a global hotkey).
        let imageKeyTitleLabel = NSTextField(labelWithString: "截图后 · 复制图片")
        imageKeyTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        imageKeyTitleLabel.toolTip = "默认 ↵：在选区内按一下就复制图片（双击选区效果相同）。"
        imageKeyValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        imageKeyValueLabel.alignment = .center
        imageKeyValueLabel.translatesAutoresizingMaskIntoConstraints = false
        imageKeyBadge.contentContainer.addSubview(imageKeyValueLabel)
        NSLayoutConstraint.activate([
            imageKeyValueLabel.topAnchor.constraint(equalTo: imageKeyBadge.contentContainer.topAnchor, constant: 4),
            imageKeyValueLabel.leadingAnchor.constraint(equalTo: imageKeyBadge.contentContainer.leadingAnchor, constant: 10),
            imageKeyValueLabel.trailingAnchor.constraint(equalTo: imageKeyBadge.contentContainer.trailingAnchor, constant: -10),
            imageKeyValueLabel.bottomAnchor.constraint(equalTo: imageKeyBadge.contentContainer.bottomAnchor, constant: -4),
            imageKeyBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])
        recordImageKeyButton.target = self
        recordImageKeyButton.action = #selector(recordImageKey)
        recordImageKeyButton.applyLiquidGlassStyle()
        let imageKeyRow = NSStackView(views: [imageKeyTitleLabel, NSView(), imageKeyBadge, recordImageKeyButton])
        imageKeyRow.orientation = .horizontal
        imageKeyRow.spacing = 10
        imageKeyRow.alignment = .centerY

        let textKeyTitleLabel = NSTextField(labelWithString: "截图后 · 识别文字")
        textKeyTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        textKeyTitleLabel.toolTip = "默认空格：在选区内按一下就只识别并复制文字（⇧↵ / ⌘C 同样可用）。"
        textKeyValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        textKeyValueLabel.alignment = .center
        textKeyValueLabel.translatesAutoresizingMaskIntoConstraints = false
        textKeyBadge.contentContainer.addSubview(textKeyValueLabel)
        NSLayoutConstraint.activate([
            textKeyValueLabel.topAnchor.constraint(equalTo: textKeyBadge.contentContainer.topAnchor, constant: 4),
            textKeyValueLabel.leadingAnchor.constraint(equalTo: textKeyBadge.contentContainer.leadingAnchor, constant: 10),
            textKeyValueLabel.trailingAnchor.constraint(equalTo: textKeyBadge.contentContainer.trailingAnchor, constant: -10),
            textKeyValueLabel.bottomAnchor.constraint(equalTo: textKeyBadge.contentContainer.bottomAnchor, constant: -4),
            textKeyBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])
        recordTextKeyButton.target = self
        recordTextKeyButton.action = #selector(recordTextKey)
        recordTextKeyButton.applyLiquidGlassStyle()
        let textKeyRow = NSStackView(views: [textKeyTitleLabel, NSView(), textKeyBadge, recordTextKeyButton])
        textKeyRow.orientation = .horizontal
        textKeyRow.spacing = 10
        textKeyRow.alignment = .centerY

        restoreDefaultButton.target = self
        restoreDefaultButton.action = #selector(restoreDefaults)
        restoreDefaultButton.applyLiquidGlassStyle()

        let restoreRow = NSStackView(views: [NSView(), restoreDefaultButton])
        restoreRow.orientation = .horizontal

        let divider = NSBox()
        divider.boxType = .separator

        persistenceCheckbox.target = self
        persistenceCheckbox.action = #selector(togglePersistence)

        pasteCheckbox.target = self
        pasteCheckbox.action = #selector(togglePasteOnSelect)

        hideMenuBarCheckbox.target = self
        hideMenuBarCheckbox.action = #selector(toggleHideMenuBarIcon)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let divider2 = NSBox()
        divider2.boxType = .separator

        let stack = NSStackView(views: [
            captureRow,
            historyRow,
            restoreRow,
            divider,
            imageKeyRow,
            textKeyRow,
            divider2,
            persistenceCheckbox,
            pasteCheckbox,
            hideMenuBarCheckbox,
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
            divider2.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageKeyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textKeyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recordCaptureButton.widthAnchor.constraint(equalToConstant: 110),
            recordHistoryButton.widthAnchor.constraint(equalToConstant: 110),
            recordImageKeyButton.widthAnchor.constraint(equalToConstant: 110),
            recordTextKeyButton.widthAnchor.constraint(equalToConstant: 110)
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
        imageKeyValueLabel.stringValue = settings.imageKey.displayString
        textKeyValueLabel.stringValue = settings.textKey.displayString
        recordCaptureButton.title = recordingTarget == .capture ? "按下快捷键…" : "录制快捷键"
        recordHistoryButton.title = recordingTarget == .history ? "按下快捷键…" : "录制快捷键"
        recordImageKeyButton.title = recordingTarget == .imageKey ? "按下按键…" : "录制按键"
        recordTextKeyButton.title = recordingTarget == .textKey ? "按下按键…" : "录制按键"
        recordCaptureButton.applyLiquidGlassStyle(active: recordingTarget == .capture)
        recordHistoryButton.applyLiquidGlassStyle(active: recordingTarget == .history)
        recordImageKeyButton.applyLiquidGlassStyle(active: recordingTarget == .imageKey)
        recordTextKeyButton.applyLiquidGlassStyle(active: recordingTarget == .textKey)
        persistenceCheckbox.state = settings.imagePersistenceEnabled ? .on : .off
        pasteCheckbox.state = settings.pasteOnSelect ? .on : .off
        hideMenuBarCheckbox.state = settings.hideMenuBarIcon ? .on : .off
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

    @objc private func togglePasteOnSelect() {
        stopRecording()
        var updated = settings
        updated.pasteOnSelect = (pasteCheckbox.state == .on)
        applyUpdatedSettings(updated, message: updated.pasteOnSelect ? "选中历史后将直接粘贴" : "")
    }

    @objc private func toggleHideMenuBarIcon() {
        stopRecording()
        var updated = settings
        updated.hideMenuBarIcon = (hideMenuBarCheckbox.state == .on)
        applyUpdatedSettings(updated, message: updated.hideMenuBarIcon
                             ? "菜单栏图标已隐藏，再点一次或重新打开 SuperTools 可恢复。"
                             : "菜单栏图标已恢复")
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

    @objc private func recordImageKey() {
        if recordingTarget == .imageKey {
            stopRecording()
            statusLabel.stringValue = ""
            refreshUI()
        } else {
            startRecording(.imageKey)
        }
    }

    @objc private func recordTextKey() {
        if recordingTarget == .textKey {
            stopRecording()
            statusLabel.stringValue = ""
            refreshUI()
        } else {
            startRecording(.textKey)
        }
    }

    @objc private func restoreDefaults() {
        stopRecording()
        var updated = settings
        updated.captureShortcut = .capture
        updated.historyShortcut = .history
        updated.imageKey = .imageDefault
        updated.textKey = .textDefault
        applyUpdatedSettings(updated, message: "已恢复默认按键")
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
        switch target {
        case .capture, .history:
            statusLabel.stringValue = "请按下包含 Command / Option / Control 的组合键（Esc 取消）"
        case .imageKey, .textKey:
            statusLabel.stringValue = "请按下截图后要用的确认键，可用回车、空格等普通键（Esc 取消）"
        }
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
                var updated = self.settings
                do {
                    switch activeTarget {
                    case .capture, .history:
                        let shortcut = NativeShortcut(keyCode: Int(event.keyCode),
                                                      modifierFlags: event.modifierFlags)
                        try shortcut.validate()
                        if activeTarget == .capture { updated.captureShortcut = shortcut }
                        else { updated.historyShortcut = shortcut }
                    case .imageKey, .textKey:
                        let key = ActionKey(keyCode: Int(event.keyCode),
                                            modifierFlags: event.modifierFlags)
                        try key.validate()
                        if activeTarget == .imageKey { updated.imageKey = key }
                        else { updated.textKey = key }
                    }
                    self.stopRecording()
                    self.applyUpdatedSettings(updated, message: "按键已更新")
                } catch {
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = error.localizedDescription
                }
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
