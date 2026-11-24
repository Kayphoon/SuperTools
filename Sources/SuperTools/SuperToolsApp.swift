import AppKit
import SuperCapture
import SuperClipboard

@main
@MainActor
enum SuperToolsApp {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
            return
        }
        let app = NSApplication.shared
        let delegate = CaptureAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: ClipboardStore?
    private var settingsStore: SettingsStore?
    private var monitor: PasteboardMonitor?
    private var overlay: OverlayWindowController?
    private var history: HistoryPanel?
    private var settingsPanel: SettingsPanel?
    private let keys = GlobalHotKeys()
    private let ocr = OCRService()
    private let notice = CopyNotice()
    private var ocrTask: Task<Void, Never>?
    private var pendingInput = Data()
    private var discardingInput = false
    private var settings = NativeSettings()
    private var captureItem: NSMenuItem?
    private var historyItem: NSMenuItem?
    private var persistenceItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var resetClear: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.log("launch: pid \(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        Diagnostics.log("launch: screens=\(NSScreen.screens.count) screenAccess=\(CGPreflightScreenCaptureAccess())")
        Diagnostics.log("launch: args=[\(CommandLine.arguments.dropFirst().joined(separator: " "))]")
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .map(\.processIdentifier)
                .filter { $0 != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                Diagnostics.log("launch: WARNING another instance running pid=\(others) — global hotkeys will collide")
            }
        }
        do {
            let settingsStore = try SettingsStore()
            self.settingsStore = settingsStore
            let hasPersistedSettings = FileManager.default.fileExists(atPath: settingsStore.fileURL.path)
            if hasPersistedSettings, let loaded = try? settingsStore.load() {
                settings = loaded
            }
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false)
            let store = try ClipboardStore(directory: caches.appendingPathComponent("com.supertools.app", isDirectory: true))
            self.store = store
            if hasPersistedSettings {
                try store.setImagePersistenceEnabled(settings.imagePersistenceEnabled)
            } else {
                settings.imagePersistenceEnabled = store.imagePersistenceEnabled
            }
            monitor = PasteboardMonitor(store: store)
            store.onError = { [weak self] error in self?.show(error) }
            monitor?.onError = { [weak self] error in self?.show(error) }
            let overlay = OverlayWindowController()
            overlay.onCapture = { [weak self] image, textOnly in self?.captured(image, textOnly: textOnly) }
            overlay.onError = { [weak self] error in self?.show(error) }
            overlay.imageKey = settings.imageKey
            overlay.textKey = settings.textKey
            self.overlay = overlay
            let history = HistoryPanel(store: store)
            history.onError = { [weak self] error in self?.show(error) }
            history.onCopied = { [weak self] kind in self?.announce(kind == .image ? "图片已复制" : "已复制") }
            history.pasteOnSelect = settings.pasteOnSelect
            history.onAutoPaste = { [weak self] target in self?.autoPaste(into: target) }
            self.history = history
            let settingsPanel = SettingsPanel(settings: settings)
            settingsPanel.onApply = { [weak self] updated in
                guard let self else { return }
                try self.applySettings(updated)
                self.emit("SUPERIU_NATIVE_SETTINGS ", self.settings)
            }
            self.settingsPanel = settingsPanel
            installMenu()
            keys.capture = { [weak self] in self?.capture() }
            keys.history = { [weak self] in self?.showHistory() }
            let hosted = CommandLine.arguments.contains("--hosted")
            if !hosted {
                do {
                    try keys.start(capture: settings.captureShortcut, history: settings.historyShortcut)
                } catch {
                    fputs("SuperTools: \(error.localizedDescription)\n", stderr)
                    announce(error.localizedDescription)
                }
            }
            monitor?.start()
            if hosted {
                FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                    let data: Data
                    do { data = try handle.read(upToCount: 4096) ?? Data() } catch {
                        fputs("SuperTools stdin: \(error.localizedDescription)\n", stderr)
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                        return
                    }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if data.isEmpty {
                            NSApp.terminate(nil)
                            return
                        }
                        self.receiveInput(data)
                    }
                }
            }
            print("SUPERIU_NATIVE_READY")
            fflush(stdout)
        } catch {
            fputs("SuperTools: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func applySettings(_ configuration: NativeSettings) throws {
        guard let store else { throw NativeSettingsError.unavailable }
        try configuration.validate()
        try keys.configure(capture: configuration.captureShortcut, history: configuration.historyShortcut) {
            try store.setImagePersistenceEnabled(configuration.imagePersistenceEnabled)
        }
        settings = configuration
        settings.imagePersistenceEnabled = store.imagePersistenceEnabled
        overlay?.imageKey = settings.imageKey
        overlay?.textKey = settings.textKey
        history?.pasteOnSelect = settings.pasteOnSelect
        try settingsStore?.save(settings)
        // Turning auto-paste on is the moment to ask: the user just expressed intent,
        // and the prompt is what puts the app into the Accessibility list at all.
        if settings.pasteOnSelect, !PasteSynthesizer.isTrusted {
            PasteSynthesizer.requestPermission()
            PasteSynthesizer.openAccessibilitySettings()
        }
        updateMenu()
        settingsPanel?.update(settings: settings)
        history?.reload()
    }

    private func receiveInput(_ data: Data) {
        for byte in data {
            if byte == 10 {
                if discardingInput {
                    discardingInput = false
                    continue
                }
                if pendingInput.last == 13 { pendingInput.removeLast() }
                let line = pendingInput
                pendingInput.removeAll(keepingCapacity: true)
                if line == Data("quit".utf8) {
                    NSApp.terminate(nil)
                    return
                }
                handleRequest(line)
            } else if !discardingInput {
                guard pendingInput.count < 8192 else {
                    pendingInput.removeAll(keepingCapacity: true)
                    discardingInput = true
                    emit("SUPERIU_NATIVE_RESPONSE ", NativeResponse(id: 0, ok: false,
                                                                   error: NativeSettingsError.lineTooLong.localizedDescription))
                    continue
                }
                pendingInput.append(byte)
            }
        }
    }

    private func handleRequest(_ data: Data) {
        let decoder = JSONDecoder()
        let id = (try? decoder.decode(NativeRequestID.self, from: data).id) ?? 0
        do {
            guard id > 0 else { throw NativeSettingsError.invalidRequest }
            let request = try decoder.decode(NativeRequest.self, from: data)
            guard let store else { throw NativeSettingsError.unavailable }
            switch request.action {
            case "getSettings":
                break
            case "configure":
                guard let configuration = request.settings else { throw NativeSettingsError.invalidRequest }
                try applySettings(configuration)
            case "clearHistory":
                try store.clear()
                resetClear?.cancel()
                clearItem?.title = "清空历史"
                history?.reload()
            default:
                throw NativeSettingsError.invalidRequest
            }
            settings.imagePersistenceEnabled = store.imagePersistenceEnabled
            emit("SUPERIU_NATIVE_RESPONSE ", NativeResponse(id: id, ok: true, settings: settings))
        } catch {
            let message = error is DecodingError ? NativeSettingsError.invalidRequest.localizedDescription
                                                : error.localizedDescription
            emit("SUPERIU_NATIVE_RESPONSE ", NativeResponse(id: id > 0 ? id : 0, ok: false, error: message))
        }
    }

    private func emit<Value: Encodable>(_ prefix: String, _ value: Value) {
        do {
            let data = try JSONEncoder().encode(value)
            print(prefix + String(decoding: data, as: UTF8.self))
            fflush(stdout)
        } catch {
            fputs("SuperTools response: \(error.localizedDescription)\n", stderr)
        }
    }

    /// 菜单栏图标：优先使用打包进 Resources 的胖扳手模板图（自动适配深浅色），缺失时回退 SF Symbol。
    private func menuBarImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            image.accessibilityDescription = "SuperTools"
            return image
        }
        return NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SuperTools") ?? NSImage()
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarImage()
        let menu = NSMenu()
        let capture = action("截图", #selector(capture))
        menu.addItem(capture)
        captureItem = capture
        let history = action("剪贴板历史", #selector(showHistory))
        menu.addItem(history)
        historyItem = history
        menu.addItem(.separator())
        let persistence = action("保存图片历史到缓存（最多 25 张 / 50 MB）", #selector(togglePersistence))
        persistence.state = store?.imagePersistenceEnabled == true ? .on : .off
        menu.addItem(persistence)
        persistenceItem = persistence
        let clear = action("清空历史", #selector(clearHistory))
        menu.addItem(clear)
        clearItem = clear
        menu.addItem(.separator())
        menu.addItem(action("打开屏幕录制权限设置…", #selector(openScreenRecordingSettings)))
        menu.addItem(.separator())
        let preferences = action("偏好设置…", #selector(showSettings))
        preferences.keyEquivalent = ","
        menu.addItem(preferences)
        menu.addItem(.separator())
        menu.addItem(action("退出 SuperTools", #selector(quit)))
        item.menu = menu
        statusItem = item
        updateMenu()
    }

    private func updateMenu() {
        captureItem?.keyEquivalent = settings.captureShortcut.keyEquivalent
        captureItem?.keyEquivalentModifierMask = settings.captureShortcut.menuModifiers
        historyItem?.keyEquivalent = settings.historyShortcut.keyEquivalent
        historyItem?.keyEquivalentModifierMask = settings.historyShortcut.menuModifiers
        persistenceItem?.state = settings.imagePersistenceEnabled ? .on : .off
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }
    @objc private func openScreenRecordingSettings() {
        Diagnostics.log("openScreenRecordingSettings: preflight=\(CGPreflightScreenCaptureAccess())")
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func capture() {
        Diagnostics.log("menu: capture")
        guard ocrTask == nil else {
            announce("正在识别文字，请稍后再截图。")
            return
        }
        notice.close()
        history?.window?.orderOut(nil)
        settingsPanel?.window?.orderOut(nil)
        guard ensureScreenRecordingPermission() else { return }
        overlay?.present()
    }

    /// Warm the capture path before the hotkey path.
    ///
    /// Screen recording is a modal TCC prompt the first time, and it is granted to
    /// the calling bundle while the app is frontmost. Requesting it lazily inside a
    /// hotkey callback (a background app) can leave the prompt unanswerable, so the
    /// menu item asks for it explicitly and points at System Settings on refusal.
    private func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        Diagnostics.log("permission: requesting screen recording access")
        NSApp.activate(ignoringOtherApps: true)
        if CGRequestScreenCaptureAccess() {
            Diagnostics.log("permission: granted")
            return true
        }
        Diagnostics.log("permission: denied")
        announce("需要屏幕录制权限。请在系统设置 → 隐私与安全性 → 屏幕与系统录音中允许 SuperTools，然后重试。")
        openScreenRecordingSettings()
        return false
    }

    @objc private func showHistory() {
        overlay?.cancel()
        // Checked before the panel takes focus, so the prompt lands on a window that
        // is actually frontmost; the panel still opens either way.
        if settings.pasteOnSelect, !PasteSynthesizer.isTrusted {
            PasteSynthesizer.requestPermission()
        }
        history?.present()
    }

    /// Shared by the history panel's auto-paste and any future caller.
    private func autoPaste(into target: NSRunningApplication?) {
        switch PasteSynthesizer.paste(into: target) {
        case .pasted:
            Diagnostics.log("paster: done")
        case .permissionRequired:
            announce("已复制。开启「辅助功能」权限后可自动粘贴，正在打开设置…")
            PasteSynthesizer.openAccessibilitySettings()
        case .failed:
            show(PasteSynthesizerError.failed)
        }
    }

    @objc private func showSettings() {
        overlay?.cancel()
        settingsPanel?.present(with: settings)
    }

    private func captured(_ image: CGImage, textOnly: Bool) {
        guard let monitor, let store else { return }
        let initialChange = NSPasteboard.general.changeCount
        let id: String?
        do {
            id = textOnly ? nil : try monitor.copyImage(image)
            if !textOnly { announce("图片已复制") }
        } catch { show(error); return }
        ocrTask = Task { [weak self] in
            guard let self else { return }
            defer { ocrTask = nil }
            do {
                let text = try await ocr.recognize(image)
                try Task.checkCancellation()
                if textOnly {
                    guard !text.isEmpty else { throw OCRFailure.empty }
                    // Never clobber a newer copy made while Vision was running.
                    guard NSPasteboard.general.changeCount == initialChange else {
                        announce("剪贴板已改变，识别结果未覆盖新内容。")
                        return
                    }
                    try monitor.copyText(text)
                    announce("文字已复制")
                } else if let id {
                    store.attachOCR(text, to: id)
                    history?.reload()
                }
            } catch is CancellationError {
                // Termination cancels the single owned OCR job.
            } catch { show(error) }
        }
    }

    @objc private func togglePersistence() {
        guard let store else { return }
        do {
            try store.setImagePersistenceEnabled(!store.imagePersistenceEnabled)
            settings.imagePersistenceEnabled = store.imagePersistenceEnabled
            try settingsStore?.save(settings)
            updateMenu()
            settingsPanel?.update(settings: settings)
            history?.reload()
            emit("SUPERIU_NATIVE_SETTINGS ", settings)
        } catch { show(error) }
    }

    @objc private func clearHistory() {
        guard let clearItem else { return }
        if clearItem.title != "确认清空历史" {
            clearItem.title = "确认清空历史"
            resetClear?.cancel()
            let reset = DispatchWorkItem { [weak self] in self?.clearItem?.title = "清空历史" }
            resetClear = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: reset)
            statusItem?.menu?.cancelTrackingWithoutAnimation()
            statusItem?.button?.performClick(nil)
            return
        }
        resetClear?.cancel()
        clearItem.title = "清空历史"
        do { try store?.clear(); history?.reload() } catch { show(error) }
    }

    private func announce(_ text: String) {
        guard let button = statusItem?.button else { return }
        button.toolTip = text
        notice.show(text)
        NSAccessibility.post(element: button, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Report an error without a blocking modal alert.
    ///
    /// A modal `NSAlert` runs a nested run loop, which deadlocks a menu bar app
    /// that has no key window: the alert can be drawn behind everything, the run
    /// loop never returns, and every later hotkey looks like it "did nothing".
    /// The HUD plus the runtime log keep the app responsive while still surfacing
    /// the failure.
    private func show(_ error: Error) {
        Diagnostics.log("error: \(error.localizedDescription)")
        announce(error.localizedDescription)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        FileHandle.standardInput.readabilityHandler = nil
        resetClear?.cancel()
        ocrTask?.cancel()
        ocrTask = nil
        overlay?.stop()
        monitor?.stop()
        keys.stop()
        history?.close()
        settingsPanel?.close()
        notice.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
