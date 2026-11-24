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
    private var updater: Updater?
    private var updatePrompt: UpdatePrompt?
    private let keys = GlobalHotKeys()
    private let ocr = OCRService()
    private let notice = CopyNotice()
    private var ocrTask: Task<Void, Never>?
    private var ocrSequence = 0
    private var pendingInput = Data()
    private var discardingInput = false
    private var settings = NativeSettings()
    private var captureItem: NSMenuItem?
    private var historyItem: NSMenuItem?
    private var updateItem: NSMenuItem?

    /// Hosted mode is driven by the external desktop host over stdin/stdout;
    /// the update pipeline belongs to standalone mode only — the host owns
    /// the app bundle's lifecycle there.
    private var isHosted: Bool { CommandLine.arguments.contains("--hosted") }
    private var persistenceItem: NSMenuItem?
    private var hideMenuItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var resetClear: DispatchWorkItem?

    /// Posted by a second launch so a hidden status item can come back. A menu bar
    /// app without an icon has no other in-app way to reach its preferences.
    private static let showMenuBarRequest = Notification.Name("com.supertools.app.showMenuBar")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.log("launch: pid \(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        Diagnostics.log("launch: screens=\(NSScreen.screens.count) screenAccess=\(CGPreflightScreenCaptureAccess())")
        Diagnostics.log("launch: args=[\(CommandLine.arguments.dropFirst().joined(separator: " "))]")
        // A second launch is the only way back from a hidden menu bar icon, so it
        // asks the running instance to show the icon and exits. Starting a second copy
        // would instead collide on the same global hotkeys.
        if let id = Bundle.main.bundleIdentifier, !CommandLine.arguments.contains("--hosted") {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .map(\.processIdentifier)
                .filter { $0 != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                Diagnostics.log("launch: another instance running pid=\(others) — asking it to show the menu bar")
                DistributedNotificationCenter.default().postNotificationName(Self.showMenuBarRequest,
                                                                             object: id, userInfo: nil,
                                                                             deliverImmediately: true)
                fflush(stdout)
                exit(0)
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
            // macOS puts Vision's compiled-model cache in the bundle-id cache directory
            // (`com.supertools.app/com.apple.e5rt.e5bundlecache`), so the clipboard store
            // keeps its own subdirectory. The store deletes everything it does not own
            // when it reconciles; pointed at the parent, that used to remove the model
            // cache on every launch and make each one pay the ~13 s recogniser load.
            let cacheRoot = caches.appendingPathComponent("com.supertools.app", isDirectory: true)
            let storeDirectory = cacheRoot.appendingPathComponent("clipboard", isDirectory: true)
            Self.migrateLegacyCache(from: cacheRoot, into: storeDirectory)
            let store = try ClipboardStore(directory: storeDirectory)
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
            if !isHosted {
                let updater = Updater()
                updater.onStateChange = { [weak self] state in self?.updateStateChanged(state) }
                updater.onReadyToInstall = { [weak self] version in self?.showUpdatePrompt(version: version) }
                updater.onUpToDate = { [weak self] in self?.announce("已是最新版本") }
                updater.onCheckFailed = { [weak self] message in self?.announce(message) }
                self.updater = updater
            }
            settingsPanel.onCheckUpdates = { [weak self] in self?.updater?.checkNow(userInitiated: true) }
            installMenu()
            observeShowMenuBarRequest()
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
            updater?.start(autoCheck: settings.autoCheckUpdates, autoDownload: settings.autoDownloadUpdates)
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
            // No warm-up at launch: Vision loads its recogniser on the first image that
            // contains text, and every capture already runs a background OCR pass to
            // index the clipboard entry. Paying the load there keeps a ~30 MB model out
            // of the process for anyone who never captures a screenshot.
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
        applyMenuBarVisibility()
        updater?.preferencesChanged(check: settings.autoCheckUpdates, download: settings.autoDownloadUpdates)
        settingsPanel?.update(settings: settings)
        history?.reload()
    }

    /// History used to live directly beside macOS's own caches in the bundle-id
    /// directory. Move it into `clipboard/` once, so the store's cleanup cannot
    /// reach the Vision model cache that shares the parent directory.
    private static func migrateLegacyCache(from root: URL, into directory: URL) {
        let fileManager = FileManager.default
        let legacyIndex = root.appendingPathComponent("history.json")
        let newIndex = directory.appendingPathComponent("history.json")
        guard fileManager.fileExists(atPath: legacyIndex.path),
              !fileManager.fileExists(atPath: newIndex.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            for name in try fileManager.contentsOfDirectory(atPath: root.path) where isImageCacheName(name) {
                try fileManager.moveItem(at: root.appendingPathComponent(name),
                                         to: directory.appendingPathComponent(name))
            }
            try fileManager.moveItem(at: legacyIndex, to: newIndex)
            Diagnostics.log("store: migrated legacy cache into \(directory.lastPathComponent)")
        } catch {
            Diagnostics.log("store: legacy cache migration failed — \(error.localizedDescription)")
        }
    }

    private static func isImageCacheName(_ name: String) -> Bool {
        guard name.count == 68, name.hasSuffix(".png") else { return false }
        return name.dropLast(4).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
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
        let preferences = action("设置…", #selector(showSettings))
        preferences.keyEquivalent = ","
        menu.addItem(preferences)
        if !isHosted {
            let update = action("检查更新…", #selector(updateMenuClicked))
            menu.addItem(update)
            updateItem = update
        }
        menu.addItem(.separator())
        let hideIcon = action("隐藏菜单栏图标", #selector(toggleMenuBarIcon))
        hideIcon.state = settings.hideMenuBarIcon ? .on : .off
        menu.addItem(hideIcon)
        hideMenuItem = hideIcon
        menu.addItem(.separator())
        menu.addItem(action("退出 SuperTools", #selector(quit)))
        item.menu = menu
        statusItem = item
        updateMenu()
        applyMenuBarVisibility()
    }

    private func updateMenu() {
        captureItem?.keyEquivalent = settings.captureShortcut.keyEquivalent
        captureItem?.keyEquivalentModifierMask = settings.captureShortcut.menuModifiers
        historyItem?.keyEquivalent = settings.historyShortcut.keyEquivalent
        historyItem?.keyEquivalentModifierMask = settings.historyShortcut.menuModifiers
        persistenceItem?.state = settings.imagePersistenceEnabled ? .on : .off
        hideMenuItem?.state = settings.hideMenuBarIcon ? .on : .off
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

    /// Distribute the visibility of the status item from the persisted setting. The
    /// item stays allocated while hidden so `announce` can still post accessibility
    /// announcements through its button.
    private func applyMenuBarVisibility() {
        guard let statusItem else { return }
        let visible = !settings.hideMenuBarIcon
        guard statusItem.isVisible != visible else { return }
        statusItem.isVisible = visible
        Diagnostics.log("menu: status item visible=\(visible)")
    }

    @objc private func toggleMenuBarIcon() {
        var updated = settings
        updated.hideMenuBarIcon.toggle()
        do {
            try applySettings(updated)
            if updated.hideMenuBarIcon {
                announce("菜单栏图标已隐藏。快捷键照常可用，再次打开 SuperTools 即可恢复。")
            } else {
                announce("菜单栏图标已恢复")
            }
        } catch { show(error) }
    }

    private func observeShowMenuBarRequest() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showMenuBarRequest, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealMenuBar() }
        }
    }

    /// A second launch means the icon is hidden and the user wants it back.
    private func revealMenuBar() {
        Diagnostics.log("menu: reveal requested by a second launch")
        settings.hideMenuBarIcon = false
        try? settingsStore?.save(settings)
        updateMenu()
        applyMenuBarVisibility()
        settingsPanel?.update(settings: settings)
        showSettings()
    }

    @objc private func capture() {
        Diagnostics.log("menu: capture")
        notice.close()
        history?.window?.orderOut(nil)
        settingsPanel?.window?.orderOut(nil)
        // A hotkey now also fires while this status menu is being tracked. Dismiss
        // the menu before grabbing, or it ends up in the screenshot (and the menu
        // tracking loop keeps the overlay from taking the keyboard).
        statusItem?.menu?.cancelTrackingWithoutAnimation()
        if NSApp.isActive { NSApp.deactivate() }
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
        Task { @MainActor in
            switch await PasteSynthesizer.paste(into: target) {
            case .pasted:
                Diagnostics.log("paster: done")
            case .permissionRequired:
                announce("已复制。开启「辅助功能」权限后可自动粘贴，正在打开设置…")
                PasteSynthesizer.openAccessibilitySettings()
            case .failed:
                show(PasteSynthesizerError.failed)
            }
        }
    }

    @objc private func showSettings() {
        overlay?.cancel()
        settingsPanel?.present(with: settings)
    }

    // MARK: - Updates

    private func updateStateChanged(_ state: UpdateState) {
        Diagnostics.log("update: state=\(state)")
        guard let updateItem else { return }
        switch state {
        case .idle, .upToDate, .failed:
            updateItem.title = "检查更新…"
            updateItem.isEnabled = true
        case .checking:
            updateItem.title = "正在检查更新…"
            updateItem.isEnabled = false
        case .available(let version):
            updateItem.title = "下载新版本 \(version)…"
            updateItem.isEnabled = true
        case .downloading(let version):
            updateItem.title = "正在下载 \(version)…"
            updateItem.isEnabled = false
        case .ready(let version):
            updateItem.title = "安装新版本 \(version)…"
            updateItem.isEnabled = true
        case .installing:
            updateItem.title = "正在安装…"
            updateItem.isEnabled = false
        }
    }

    @objc private func updateMenuClicked() {
        guard let updater else { return }
        switch updater.state {
        case .ready(let version):
            showUpdatePrompt(version: version)
        case .available:
            updater.downloadNow()
        default:
            updater.checkNow(userInitiated: true)
        }
    }

    private func showUpdatePrompt(version: String) {
        if let updatePrompt {
            updatePrompt.present()
            return
        }
        let prompt = UpdatePrompt(version: version)
        prompt.onInstall = { [weak self] in self?.updater?.installReady() }
        updatePrompt = prompt
        prompt.present()
    }

    private func captured(_ image: CGImage, textOnly: Bool) {
        guard let monitor, let store else { return }
        let initialChange = NSPasteboard.general.changeCount
        let id: String?
        do {
            id = textOnly ? nil : try monitor.copyImage(image)
            if !textOnly { announce("图片已复制") }
        } catch { show(error); return }
        // One job at a time, newest wins. A screenshot taken while a previous
        // recognition was still running used to be refused outright ("正在识别文字"),
        // which read as the hotkey being dead. Cancel the older job instead: its
        // only remaining work is filling in history text, and a stale result would
        // be attached to an entry the user has already scrolled past.
        ocrTask?.cancel()
        ocrSequence += 1
        let sequence = ocrSequence
        ocrTask = Task { [weak self] in
            guard let self else { return }
            if textOnly {
                // The first request in a process pays the whole recogniser load. Say so
                // instead of leaving the user staring at the same hint for 13 s.
                let prepared = await ocr.isPrepared
                announce(prepared ? "正在识别文字…" : "首次识别需加载模型，可能要十几秒…")
            }
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
                // Superseded by a newer capture, or the app is terminating.
            } catch {
                // Indexing an image is best-effort: a picture with no text simply has
                // nothing to index, so it must not raise a visible error. Only the
                // explicit text action reports back to the user.
                if textOnly { show(error) }
            }
            // Only the newest job owns the slot; a cancelled predecessor finishing
            // later must not clear a task that is already running.
            if sequence == ocrSequence { ocrTask = nil }
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
        updater?.stop()
        updatePrompt?.close()
        history?.close()
        settingsPanel?.close()
        notice.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
