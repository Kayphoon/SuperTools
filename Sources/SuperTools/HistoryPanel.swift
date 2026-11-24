import AppKit
import Carbon.HIToolbox
import SuperCapture
import SuperClipboard

@MainActor
final class HistoryPanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let quickKeyCodes: [UInt16] = [
        UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
        UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
        UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9)
    ]

    private let store: ClipboardStore
    private let rootGlass = GlassSurfaceView(variant: .regular, cornerRadius: 22, isInteractive: false)
    private let search = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let preview = HistoryPreviewView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [ClipboardEntry] = []
    /// The app the user came from. Focus moves to this panel when it opens, so the
    /// target for an auto-paste (or for handing focus back) is remembered up front.
    private var previousApp: NSRunningApplication?
    /// Invoked after a row is copied when `pasteOnSelect` is on; the host owns the
    /// permission handling so this panel stays free of Accessibility concerns.
    var onAutoPaste: ((NSRunningApplication?) -> Void)?
    var pasteOnSelect = false
    var onError: ((Error) -> Void)?
    var onCopied: ((ClipboardEntry.Kind) -> Void)?

    init(store: ClipboardStore) {
        self.store = store
        let panel = HistoryWindow(
            contentRect: CGRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "剪贴板历史"
        panel.minSize = CGSize(width: 640, height: 380)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.configureLiquidGlassWindow()
        super.init(window: panel)
        panel.delegate = self
        panel.onQuickPick = { [weak self] index in self?.copy(at: index) }
        panel.onCancel = { [weak self] in self?.dismiss() }

        panel.contentView = rootGlass
        buildLayout(in: rootGlass.contentContainer)
    }

    required init?(coder: NSCoder) { nil }

    private func buildLayout(in content: NSView) {
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(icon)

        search.placeholderString = "搜索"
        search.font = .systemFont(ofSize: 20, weight: .regular)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.usesSingleLineMode = true
        search.cell?.wraps = false
        search.cell?.isScrollable = true
        search.delegate = self
        search.setAccessibilityLabel("搜索剪贴板历史")
        search.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(search)

        let topRule = HistoryPreviewView.separator(vertical: false)
        content.addSubview(topRule)

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.refusesFirstResponder = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(copySelected)
        scroll.documentView = table
        content.addSubview(scroll)

        let middleRule = HistoryPreviewView.separator(vertical: true)
        content.addSubview(middleRule)

        preview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preview)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        let listWidth = scroll.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.42)
        listWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

            topRule.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 15),
            topRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            listWidth,
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            middleRule.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            middleRule.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            middleRule.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 6),

            preview.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: middleRule.trailingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    func present() {
        search.stringValue = ""
        reload()
        if !rows.isEmpty { select(0) }
        guard let panel = window as? NSPanel else {
            Diagnostics.log("history: present() without a window")
            return
        }
        Diagnostics.log("history: present() rows=\(rows.count) visible=\(panel.isVisible) active=\(NSApp.isActive)")
        // Capture the target before taking focus; afterwards the frontmost app is us.
        if !panel.isVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        let targetFrame = Self.frame(for: panel.frame.size)
        panel.setFrame(targetFrame, display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        panel.animateLiquidGlassEntrance(targetFrame: targetFrame)
        // A `.accessory` menu bar app cannot pull a window above the active app, so the
        // panel would be ordered in and stay hidden behind it. Activating fixes that.
        NSApp.activate(ignoringOtherApps: true)
        Diagnostics.log("history: after orderFront visible=\(panel.isVisible) key=\(panel.isKeyWindow) active=\(NSApp.isActive)")
    }

    /// Clicking another app already moved focus there, so only hide.
    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }

    func reload() {
        let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        rows = store.search(search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        table.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            select(index)
        } else if !rows.isEmpty {
            select(0)
        }
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = search.stringValue.isEmpty ? "还没有剪贴板记录" : "无结果"
        updatePreview()
    }

    // MARK: - Keyboard

    func controlTextDidChange(_ obj: Notification) {
        reload()
        if !rows.isEmpty { select(0) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            copySelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if search.stringValue.isEmpty { dismiss() } else { search.stringValue = ""; reload() }
            return true
        default:
            return false
        }
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = table.selectedRow
        let next = current < 0 ? 0 : min(max(current + delta, 0), rows.count - 1)
        select(next)
    }

    private func select(_ index: Int) {
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("HistoryRow")
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? HistoryRowView { return view }
        let view = HistoryRowView()
        view.identifier = identifier
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HistoryCellView ?? {
            let view = HistoryCellView()
            view.identifier = identifier
            return view
        }()
        cell.configure(with: rows[row], shortcut: row < Self.quickKeyCodes.count ? row + 1 : nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }

    private func updatePreview() {
        preview.show(rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil)
    }

    // MARK: - Actions

    @objc private func copySelected() {
        copy(at: table.selectedRow)
    }

    private func copy(at row: Int) {
        guard rows.indices.contains(row) else { NSSound.beep(); return }
        let entry = rows[row]
        do {
            try store.copy(entry.id, to: .general)
            // Copy first, always: the value is on the pasteboard even if the keystroke
            // cannot be delivered, so a denied permission never costs the user the copy.
            if pasteOnSelect {
                let target = previousApp
                dismiss(restoreFocus: false)
                onAutoPaste?(target)
            } else {
                dismiss(restoreFocus: true)
                onCopied?(entry.kind)
            }
        } catch { onError?(error) }
    }

    private func dismiss(restoreFocus: Bool = true) {
        let target = previousApp
        previousApp = nil
        guard window?.isVisible == true else { return }
        window?.orderOut(nil)
        // Opening the panel activated this app; hand focus back to where the user was.
        if restoreFocus, NSApp.isActive, let target,
           target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target.activate(options: [])
        }
    }

    // MARK: - Helpers

    private static func frame(for size: CGSize) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return CGRect(origin: .zero, size: size) }
        let width = min(size.width, visible.width - 40)
        let height = min(size.height, visible.height - 40)
        let x = visible.midX - width / 2
        let y = min(visible.minY + visible.height * 0.62 - height / 2, visible.maxY - height - 20)
        return CGRect(x: x.rounded(), y: max(y, visible.minY + 20).rounded(), width: width, height: height)
    }

    static func quickPickIndex(for event: NSEvent) -> Int? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return nil }
        return quickKeyCodes.firstIndex(of: event.keyCode)
    }
}

/// Key-capable floating panel that routes ⌘1–⌘9 and Escape to the history list.
private final class HistoryWindow: NSPanel {
    var onQuickPick: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let index = HistoryPanel.quickPickIndex(for: event) {
            onQuickPick?(index)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Menu-style selection: a solid accent capsule with white content, the same
/// treatment AppKit uses for highlighted menu items and Spotlight results.
private final class HistoryRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }

    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

private final class HistoryCellView: NSTableCellView {
    private let symbol = NSImageView()
    private let thumbnail = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        symbol.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbol)

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 3
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnail)

        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        shortcut.font = .systemFont(ofSize: 12)
        shortcut.alignment = .right
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcut)

        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.centerXAnchor.constraint(equalTo: symbol.centerXAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 20),
            thumbnail.heightAnchor.constraint(equalToConstant: 20),

            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -10),

            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .white : .labelColor
        shortcut.textColor = selected ? NSColor.white.withAlphaComponent(0.7) : .tertiaryLabelColor
        symbol.contentTintColor = selected ? .white : .secondaryLabelColor
    }

    func configure(with entry: ClipboardEntry, shortcut index: Int?) {
        let primary: String
        switch entry.kind {
        case .text:
            let text = entry.text ?? ""
            primary = EntryFormat.condensed(text)
            symbol.image = NSImage(systemSymbolName: EntryFormat.isLink(text) ? "link" : "doc.plaintext",
                                   accessibilityDescription: nil)
            thumbnail.image = nil
        case .image:
            primary = entry.ocrText.map(EntryFormat.condensed).flatMap { $0.isEmpty ? nil : $0 } ?? "图片"
            if let image = entry.thumbnail {
                thumbnail.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                symbol.image = nil
            } else {
                thumbnail.image = nil
                symbol.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            }
        }
        title.stringValue = primary.isEmpty ? " " : primary
        shortcut.stringValue = index.map { "⌘\($0)" } ?? ""
        applyColors()
        setAccessibilityLabel(index.map { "\(primary)，快捷键 Command \($0)" } ?? primary)
    }
}

/// Right-hand pane: the full content on top, a compact Get Info–style table below.
private final class HistoryPreviewView: NSView {
    private let textScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { textScroll.documentView as! NSTextView }
    private let imageView = NSImageView()
    private let info = NSGridView()
    private let sourceIcon = NSImageView()
    private let sourceName = NSTextField(labelWithString: "")
    private let kindValue = NSTextField(labelWithString: "")
    private let sizeValue = NSTextField(labelWithString: "")
    private let timeValue = NSTextField(labelWithString: "")
    private var shownID: String?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.scrollerStyle = .overlay
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textScroll)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        let rule = Self.separator(vertical: false)
        addSubview(rule)

        sourceIcon.imageScaling = .scaleProportionallyUpOrDown
        sourceIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sourceIcon.widthAnchor.constraint(equalToConstant: 16),
            sourceIcon.heightAnchor.constraint(equalToConstant: 16)
        ])
        let source = NSStackView(views: [sourceIcon, sourceName])
        source.spacing = 6

        info.rowSpacing = 7
        info.columnSpacing = 14
        info.translatesAutoresizingMaskIntoConstraints = false
        for (label, value) in [("来源", source as NSView), ("类型", kindValue), ("大小", sizeValue), ("时间", timeValue)] {
            let key = NSTextField(labelWithString: label)
            key.font = .systemFont(ofSize: 11)
            key.textColor = .secondaryLabelColor
            key.alignment = .right
            info.addRow(with: [key, value])
        }
        for field in [sourceName, kindValue, sizeValue, timeValue] {
            field.font = .systemFont(ofSize: 12)
            field.textColor = .labelColor
            field.lineBreakMode = .byTruncatingTail
        }
        info.column(at: 0).xPlacement = .trailing
        info.rowAlignment = .none
        info.yPlacement = .center
        info.setContentHuggingPriority(.required, for: .vertical)
        info.setContentCompressionResistancePriority(.required, for: .vertical)
        textScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(info)

        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: rule.topAnchor),

            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            imageView.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -18),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            rule.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -14),

            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            info.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            info.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        show(nil)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ entry: ClipboardEntry?) {
        guard let entry else {
            shownID = nil
            isHidden = true
            return
        }
        isHidden = false
        // Reload stays cheap: the original image is read from disk once per selection.
        guard entry.id != shownID else { return }
        shownID = entry.id

        let app = SourceApp.lookup(entry.sourceBundleID)
        sourceIcon.image = app.icon
        sourceName.stringValue = app.name
        timeValue.stringValue = Self.timeFormatter.string(from: entry.createdAt)

        switch entry.kind {
        case .text:
            let text = entry.text ?? ""
            textScroll.isHidden = false
            imageView.isHidden = true
            imageView.image = nil
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
            textView.scroll(.zero)
            kindValue.stringValue = EntryFormat.isLink(text) ? "链接" : "文本"
            let lines = text.split(whereSeparator: \.isNewline).count
            sizeValue.stringValue = lines > 1 ? "\(text.count) 个字符，\(lines) 行" : "\(text.count) 个字符"
        case .image:
            textScroll.isHidden = true
            imageView.isHidden = false
            kindValue.stringValue = "图片"
            if let url = entry.imageURL, let original = NSImage(contentsOf: url) {
                imageView.image = original
                let rep = original.representations.first
                sizeValue.stringValue = rep.map { "\($0.pixelsWide) × \($0.pixelsHigh)" } ?? "—"
            } else if let thumbnail = entry.thumbnail {
                imageView.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
                sizeValue.stringValue = "未保存原图"
            } else {
                imageView.image = nil
                sizeValue.stringValue = "未保存原图"
            }
        }
    }

    static func separator(vertical: Bool) -> NSView {
        let line = SeparatorLine()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = vertical
        line.heightAnchor.constraint(equalToConstant: 1).isActive = !vertical
        return line
    }
}

private final class SeparatorLine: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
}

/// Resolves a recorded bundle identifier to the installed app's name and icon.
@MainActor
private enum SourceApp {
    private static var cache: [String: (name: String, icon: NSImage)] = [:]

    static func lookup(_ bundleID: String?) -> (name: String, icon: NSImage) {
        let fallbackIcon = NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
        guard let bundleID else { return ("未知", fallbackIcon) }
        if let hit = cache[bundleID] { return hit }
        let result: (name: String, icon: NSImage)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            result = (name, NSWorkspace.shared.icon(forFile: url.path))
        } else {
            result = (bundleID, fallbackIcon)
        }
        cache[bundleID] = result
        return result
    }
}

private enum EntryFormat {
    static func condensed(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(300))
    }

    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
