import AppKit
import SuperCapture

/// Settings window in the shape of a macOS Settings page — sidebar on the
/// left, one calm page per section — dressed in the Kami （紙） design
/// language (tw93/kami): a warm parchment canvas, ink-blue (#1B365D) as the
/// single accent, serif display type for headings, hairline rules and
/// generous whitespace instead of shadows and glass. Dark mode keeps the
/// same idea on a warm charcoal paper.
///
/// The controller keeps its original contract with the app delegate:
/// `present(with:)`, `update(settings:)`, `onApply`, `close()`. All settings
/// still live in `NativeSettings`; this file is presentation only.
@MainActor
final class SettingsPanel: NSWindowController, NSWindowDelegate {
    private enum Section: Int, CaseIterable {
        case general, shortcuts, clipboard, about

        var title: String {
            switch self {
            case .general: return "通用"
            case .shortcuts: return "快捷键"
            case .clipboard: return "剪贴板"
            case .about: return "关于"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "keyboard"
            case .clipboard: return "doc.on.clipboard"
            case .about: return "info.circle"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "菜单栏图标与选中历史后的行为。"
            case .shortcuts: return "全局快捷键与截图后的确认键，都可以重新录制。"
            case .clipboard: return "图片历史的磁盘缓存。默认关闭，历史只留在内存里。"
            case .about: return ""
            }
        }
    }

    private enum RecordingTarget {
        case capture
        case history
        case imageKey
        case textKey
    }

    // MARK: - Kami palette

    private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Warm parchment canvas (Kami paper #F5F4ED); warm charcoal when dark.
    private static let paper = dynamicColor(light: srgb(0xF5F4ED), dark: srgb(0x232019))
    /// Sidebar: one step deeper than the canvas.
    private static let sidebarPaper = dynamicColor(light: srgb(0xEDEAE0), dark: srgb(0x1C1A15))
    /// Card surface: near-white warm paper; a lifted warm gray when dark.
    private static let card = dynamicColor(light: srgb(0xFDFCF9), dark: srgb(0x2C2921))
    /// Warm hairline (yellow-brown undertone gray, per Kami).
    private static let hairline = dynamicColor(light: srgb(0xDCD6C6), dark: srgb(0x454034))
    /// Ink blue, the single accent.
    private static let ink = dynamicColor(light: srgb(0x1B365D), dark: srgb(0x8FB0DC))
    private static let inkFill = srgb(0x1B365D)
    /// Keycap fill.
    private static let keycap = dynamicColor(light: srgb(0xEFECDF), dark: srgb(0x3A362B))

    private static func serifFont(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        // Songti SC is the system serif for Simplified Chinese; Kami's Chinese
        // face is a Kai/serif, so headings set in Songti keep the paper feel
        // without bundling a font.
        let traits: NSFontTraitMask = weight == .bold ? .boldFontMask : []
        if let songti = NSFontManager.shared.font(withFamily: "Songti SC", traits: traits, weight: 5, size: size) {
            return songti
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// Layer-backed view whose fill/stroke are re-resolved in `updateLayer`,
    /// so the dynamic Kami colors follow light/dark appearance changes
    /// instead of freezing at the value they had when first set.
    private final class PaperView: NSView {
        var fill: NSColor = .clear { didSet { needsDisplay = true } }
        var stroke: NSColor? { didSet { needsDisplay = true } }
        var corner: CGFloat = 0 { didSet { needsDisplay = true } }
        var onAppearanceChange: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = stroke?.cgColor
            layer?.borderWidth = stroke == nil ? 0 : 1
            layer?.cornerRadius = corner
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onAppearanceChange?()
        }
    }

    /// One sidebar entry with hand-placed contents — a selection pill, the
    /// symbol in a fixed 16 pt slot, the label at a fixed offset — so every
    /// row lines up exactly. (An `NSButton` positions its image and title
    /// with its own internal insets, which is what made the old sidebar
    /// rows look scattered.)
    private final class SidebarRowView: NSView {
        let section: Section
        var onSelect: ((Section) -> Void)?
        var selectedFill: NSColor = .clear
        private let pill = PaperView()
        private let iconView = NSImageView()
        private let titleLabel = NSTextField(labelWithString: "")

        init(section: Section) {
            self.section = section
            super.init(frame: .zero)
            pill.corner = 7
            pill.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pill)
            iconView.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.stringValue = section.title
            titleLabel.font = .systemFont(ofSize: 13)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            addSubview(titleLabel)
            NSLayoutConstraint.activate([
                pill.topAnchor.constraint(equalTo: topAnchor),
                pill.leadingAnchor.constraint(equalTo: leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: trailingAnchor),
                pill.bottomAnchor.constraint(equalTo: bottomAnchor),
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 30)
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(section.title)
        }

        required init?(coder: NSCoder) { nil }

        func setSelected(_ selected: Bool) {
            pill.fill = selected ? selectedFill : .clear
            let color: NSColor = selected ? .white : .labelColor
            titleLabel.textColor = color
            iconView.contentTintColor = color
        }

        override func mouseDown(with event: NSEvent) {
            onSelect?(section)
        }
    }

    // MARK: - State

    private var settings: NativeSettings
    private var recordingTarget: RecordingTarget?
    private var keyMonitor: Any?
    private var currentSection: Section = .general

    // MARK: - Views

    private var sectionRows: [Section: SidebarRowView] = [:]
    private var sectionPages: [Section: NSView] = [:]
    private let contentContainer = NSView()

    private let captureValueLabel = NSTextField(labelWithString: "")
    private let historyValueLabel = NSTextField(labelWithString: "")
    private let imageKeyValueLabel = NSTextField(labelWithString: "")
    private let textKeyValueLabel = NSTextField(labelWithString: "")
    private let recordCaptureButton = NSButton(title: "录制", target: nil, action: nil)
    private let recordHistoryButton = NSButton(title: "录制", target: nil, action: nil)
    private let recordImageKeyButton = NSButton(title: "录制", target: nil, action: nil)
    private let recordTextKeyButton = NSButton(title: "录制", target: nil, action: nil)
    private let menuBarSwitch = NSSwitch()
    private let pasteSwitch = NSSwitch()
    private let autoCheckSwitch = NSSwitch()
    private let autoDownloadSwitch = NSSwitch()
    private let persistenceSwitch = NSSwitch()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    var onApply: ((NativeSettings) throws -> Void)?
    /// Wired by the app delegate to the updater's manual check.
    var onCheckUpdates: (() -> Void)?

    init(settings: NativeSettings = NativeSettings()) {
        self.settings = settings
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SuperTools 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        setupViews(in: window)
        refreshUI()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Layout

    private func setupViews(in window: NSWindow) {
        let root = PaperView()
        root.fill = Self.paper
        root.onAppearanceChange = { [weak self] in self?.refreshTheme() }
        window.contentView = root

        let sidebar = buildSidebar()
        root.addSubview(sidebar)
        root.addSubview(contentContainer)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 178),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        for section in Section.allCases {
            let page = buildPage(for: section)
            page.isHidden = section != currentSection
            contentContainer.addSubview(page)
            page.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                page.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
            sectionPages[section] = page
        }

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -28),
            statusLabel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -16)
        ])
        selectSection(.general)
    }

    private func buildSidebar() -> NSView {
        let sidebar = PaperView()
        sidebar.fill = Self.sidebarPaper

        // Header and menu rows share one leading edge: app icon, then the
        // name and version stacked beside it, left-aligned like the rows.
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let name = NSTextField(labelWithString: "SuperTools")
        name.font = Self.serifFont(size: 15, weight: .bold)
        let versionText = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .map { "版本 \($0)" } ?? ""
        let version = NSTextField(labelWithString: versionText)
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor

        let nameStack = NSStackView(views: [name, version])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 1

        let header = NSStackView(views: [icon, nameStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9

        var rows: [NSView] = []
        for section in Section.allCases {
            let row = SidebarRowView(section: section)
            row.selectedFill = Self.inkFill
            row.onSelect = { [weak self] selected in self?.selectSection(selected) }
            sectionRows[section] = row
            rows.append(row)
        }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3
        for row in rows {
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: [header, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            // Same top line as the page titles; clears the traffic lights.
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14)
        ])
        return sidebar
    }

    /// One section page: serif title, quiet subtitle, then paper cards.
    private func buildPage(for section: Section) -> NSView {
        let page = NSView()
        let title = NSTextField(labelWithString: section.title)
        title.font = Self.serifFont(size: 20, weight: .bold)
        var views: [NSView] = [title]
        if !section.subtitle.isEmpty {
            let subtitle = NSTextField(wrappingLabelWithString: section.subtitle)
            subtitle.font = .systemFont(ofSize: 12)
            subtitle.textColor = .secondaryLabelColor
            views.append(subtitle)
        }
        switch section {
        case .general: views.append(buildGeneralCard())
        case .shortcuts: views.append(contentsOf: buildShortcutCards())
        case .clipboard: views.append(buildClipboardCard())
        case .about: views.append(buildAboutCard())
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(6, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -28)
        ])
        for view in views where view !== title {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return page
    }

    // MARK: - Card & row helpers

    /// A paper card: warm surface, one hairline border, rows split by hairlines.
    private func card(rows: [NSView]) -> NSView {
        let container = PaperView()
        container.fill = Self.card
        container.stroke = Self.hairline
        container.corner = 10

        var children: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rule = PaperView()
                rule.fill = Self.hairline
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
                children.append(rule)
            }
            children.append(row)
        }
        let stack = NSStackView(views: children)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        for child in children {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return container
    }

    /// Secondary 11 pt text with loosened line height, for the footnotes
    /// under row labels and the About credit. Chinese sentences at the
    /// default leading read cramped once they wrap to a second line; ~1.3x
    /// gives the lines room without changing the font size.
    private func footnoteLabel(_ text: String) -> NSTextField {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.3
        let label = NSTextField(wrappingLabelWithString: text)
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: style])
        return label
    }

    /// Label on the left, control on the right, optional quiet footnote under
    /// the label. This is the only row shape the window uses. Every row gets
    /// the same vertical padding and minimum height, so controls sit on a
    /// regular rhythm instead of wherever a wrapped footnote leaves them.
    private func row(label: String, footnote: String? = nil, control: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13)
        var leftViews: [NSView] = [title]
        if let footnote {
            leftViews.append(footnoteLabel(footnote))
        }
        let left = NSStackView(views: leftViews)
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        left.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        // No horizontal stack view on purpose: its hugging arbitration let
        // the control (an NSSwitch especially) drift with the footnote's
        // length instead of pinning to the trailing edge — visible in the
        // offscreen renders as switches floating at four different x
        // positions. Explicit constraints put every control on the card's
        // right edge, whatever the label's length.
        let container = NSView()
        container.addSubview(left)
        container.addSubview(control)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
            left.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 46)
        ])
        return container
    }

    private func keycap(_ label: NSTextField) -> NSView {
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        let cap = PaperView()
        cap.fill = Self.keycap
        cap.stroke = Self.hairline
        cap.corner = 6
        label.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -9),
            cap.heightAnchor.constraint(equalToConstant: 24),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        return cap
    }

    /// A real rounded-bezel button: the system owns its insets and title
    /// baseline, which the previous hand-layered borderless buttons got
    /// subtly wrong. The bezel color carries the Kami keycap tone instead.
    private func recordButton(_ button: NSButton, action: Selector) -> NSView {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        button.bezelColor = Self.keycap
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return button
    }

    private func keyRow(label: String, footnote: String?, value: NSTextField, button: NSButton, action: Selector) -> NSView {
        let controls = NSStackView(views: [keycap(value), recordButton(button, action: action)])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        return row(label: label, footnote: footnote, control: controls)
    }

    // MARK: - Sections

    private func buildGeneralCard() -> NSView {
        menuBarSwitch.target = self
        menuBarSwitch.action = #selector(toggleMenuBarIcon)
        pasteSwitch.target = self
        pasteSwitch.action = #selector(togglePasteOnSelect)
        autoCheckSwitch.target = self
        autoCheckSwitch.action = #selector(toggleAutoCheck)
        autoDownloadSwitch.target = self
        autoDownloadSwitch.action = #selector(toggleAutoDownload)
        return card(rows: [
            row(label: "显示菜单栏图标",
                footnote: "关掉后快捷键照常可用；再次打开 SuperTools 即可恢复图标并打开设置。",
                control: menuBarSwitch),
            row(label: "选中历史后直接粘贴",
                footnote: "把选中的历史条目粘贴回原窗口，需要辅助功能权限。",
                control: pasteSwitch),
            row(label: "自动检查更新",
                footnote: "启动时与每天一次，向 GitHub 查询是否有新版本发布。",
                control: autoCheckSwitch),
            row(label: "自动下载更新",
                footnote: "发现新版本后在后台下载并校验完整性；安装永远等你手动确认。",
                control: autoDownloadSwitch)
        ])
    }

    private func buildShortcutCards() -> [NSView] {
        let global = card(rows: [
            keyRow(label: "截图", footnote: nil, value: captureValueLabel,
                   button: recordCaptureButton, action: #selector(recordCaptureShortcut)),
            keyRow(label: "剪贴板历史", footnote: nil, value: historyValueLabel,
                   button: recordHistoryButton, action: #selector(recordHistoryShortcut))
        ])
        let actions = card(rows: [
            keyRow(label: "截图后 · 复制图片", footnote: "默认 ↵，在选区内按一下即可（双击选区效果相同）。",
                   value: imageKeyValueLabel, button: recordImageKeyButton, action: #selector(recordImageKey)),
            keyRow(label: "截图后 · 识别文字", footnote: "默认空格，只识别并复制文字（⇧↵ / ⌘C 同样可用）。",
                   value: textKeyValueLabel, button: recordTextKeyButton, action: #selector(recordTextKey))
        ])
        let restore = NSButton(title: "恢复默认按键", target: self, action: #selector(restoreDefaults))
        restore.bezelStyle = .rounded
        restore.font = .systemFont(ofSize: 12)
        restore.bezelColor = Self.keycap
        restore.contentTintColor = Self.ink
        restore.translatesAutoresizingMaskIntoConstraints = false
        let restoreRow = NSStackView(views: [NSView(), restore])
        restoreRow.orientation = .horizontal
        return [global, actions, restoreRow]
    }

    private func buildClipboardCard() -> NSView {
        persistenceSwitch.target = self
        persistenceSwitch.action = #selector(togglePersistence)
        return card(rows: [
            row(label: "保存图片历史到磁盘缓存",
                footnote: "最多 25 张 / 7 天 / 50 MB，缓存目录权限 0700。关闭后立即删除缓存；不开启时内存里只保留 128 px 缩略图与识别文本。",
                control: persistenceSwitch),
            row(label: "隐私",
                footnote: "被标记为隐藏或临时类型的复制内容（例如来自密码管理器）不会进入历史。剪贴板内容不离开这台 Mac。",
                control: NSView())
        ])
    }

    private func buildAboutCard() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "SuperTools")
        name.font = Self.serifFont(size: 17, weight: .bold)
        let tagline = NSTextField(wrappingLabelWithString: "截图、标注、文字识别与剪贴板历史，全部在这台 Mac 上本地完成。")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor

        let repo = NSButton(title: "github.com/Kayphoon/SuperTools", target: self, action: #selector(openRepository))
        repo.bezelStyle = .inline
        repo.isBordered = false
        repo.font = .systemFont(ofSize: 12)
        repo.contentTintColor = Self.ink

        let check = NSButton(title: "检查更新…", target: self, action: #selector(checkUpdatesClicked))
        check.bezelStyle = .inline
        check.isBordered = false
        check.font = .systemFont(ofSize: 12)
        check.contentTintColor = Self.ink

        let text = NSStackView(views: [name, tagline, repo, check])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5

        let head = NSStackView(views: [icon, text])
        head.orientation = .horizontal
        head.alignment = .top
        head.spacing = 14

        let credit = footnoteLabel("界面取 Kami（紙）的纸面与墨蓝：暖纸底、单一墨蓝强调、细线分隔。")

        let container = PaperView()
        container.fill = Self.card
        container.stroke = Self.hairline
        container.corner = 10
        let rule = PaperView()
        rule.fill = Self.hairline
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let stack = NSStackView(views: [head, rule, credit])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            credit.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return container
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Kayphoon/SuperTools")!)
    }

    @objc private func checkUpdatesClicked() {
        onCheckUpdates?()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "正在检查更新，结果会通过菜单与提示窗口告知。"
    }

    /// Hook for the offscreen render harness on the screenshot branch.
    func selectSectionForRender(_ index: Int) {
        selectSection(Section(rawValue: index) ?? .general)
    }

    private func selectSection(_ section: Section) {
        currentSection = section
        stopRecording()
        statusLabel.stringValue = ""
        for (key, page) in sectionPages { page.isHidden = key != section }
        for (key, row) in sectionRows { row.setSelected(key == section) }
    }

    /// Re-apply the colors that live on button layers (snapshots of the
    /// dynamic palette) after a light/dark appearance change. PaperViews
    /// re-resolve themselves through `updateLayer`.
    private func refreshTheme() {
        selectSection(currentSection)
        refreshUI()
    }

    // MARK: - Presentation & state

    func present(with currentSettings: NativeSettings) {
        stopRecording()
        settings = currentSettings
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        refreshUI()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
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
        recordCaptureButton.title = recordingTarget == .capture ? "按下…" : "录制"
        recordHistoryButton.title = recordingTarget == .history ? "按下…" : "录制"
        recordImageKeyButton.title = recordingTarget == .imageKey ? "按下…" : "录制"
        recordTextKeyButton.title = recordingTarget == .textKey ? "按下…" : "录制"
        styleRecordButton(recordCaptureButton, active: recordingTarget == .capture)
        styleRecordButton(recordHistoryButton, active: recordingTarget == .history)
        styleRecordButton(recordImageKeyButton, active: recordingTarget == .imageKey)
        styleRecordButton(recordTextKeyButton, active: recordingTarget == .textKey)
        // The switch reads as the positive form: on = icon shown.
        menuBarSwitch.state = settings.hideMenuBarIcon ? .off : .on
        pasteSwitch.state = settings.pasteOnSelect ? .on : .off
        autoCheckSwitch.state = settings.autoCheckUpdates ? .on : .off
        autoDownloadSwitch.state = settings.autoDownloadUpdates ? .on : .off
        autoDownloadSwitch.isEnabled = settings.autoCheckUpdates
        persistenceSwitch.state = settings.imagePersistenceEnabled ? .on : .off
    }

    private func styleRecordButton(_ button: NSButton, active: Bool) {
        button.bezelColor = active ? Self.inkFill : Self.keycap
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.foregroundColor: active ? NSColor.white : NSColor.labelColor,
                         .font: NSFont.systemFont(ofSize: 12)])
    }

    // MARK: - Actions

    @objc private func toggleMenuBarIcon() {
        stopRecording()
        var updated = settings
        updated.hideMenuBarIcon = (menuBarSwitch.state == .off)
        applyUpdatedSettings(updated, message: updated.hideMenuBarIcon
                             ? "菜单栏图标已隐藏，再次打开 SuperTools 可恢复。"
                             : "菜单栏图标已恢复")
    }

    @objc private func togglePasteOnSelect() {
        stopRecording()
        var updated = settings
        updated.pasteOnSelect = (pasteSwitch.state == .on)
        applyUpdatedSettings(updated, message: updated.pasteOnSelect ? "选中历史后将直接粘贴" : "")
    }

    @objc private func togglePersistence() {
        stopRecording()
        var updated = settings
        updated.imagePersistenceEnabled = (persistenceSwitch.state == .on)
        applyUpdatedSettings(updated, message: "")
    }

    @objc private func toggleAutoCheck() {
        stopRecording()
        var updated = settings
        updated.autoCheckUpdates = (autoCheckSwitch.state == .on)
        applyUpdatedSettings(updated, message: updated.autoCheckUpdates ? "" : "已关闭自动检查更新")
    }

    @objc private func toggleAutoDownload() {
        stopRecording()
        var updated = settings
        updated.autoDownloadUpdates = (autoDownloadSwitch.state == .on)
        applyUpdatedSettings(updated, message: "")
    }

    @objc private func recordCaptureShortcut() {
        recordingTarget == .capture ? cancelRecording() : startRecording(.capture)
    }

    @objc private func recordHistoryShortcut() {
        recordingTarget == .history ? cancelRecording() : startRecording(.history)
    }

    @objc private func recordImageKey() {
        recordingTarget == .imageKey ? cancelRecording() : startRecording(.imageKey)
    }

    @objc private func recordTextKey() {
        recordingTarget == .textKey ? cancelRecording() : startRecording(.textKey)
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

    // MARK: - Key recording

    private func cancelRecording() {
        stopRecording()
        statusLabel.stringValue = ""
        refreshUI()
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
