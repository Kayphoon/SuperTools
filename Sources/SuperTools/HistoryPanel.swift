import AppKit
import SuperCapture
import SuperClipboard

@MainActor
final class HistoryPanel: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ClipboardStore
    private let rootGlass = GlassSurfaceView(variant: .regular, cornerRadius: 16, isInteractive: true)
    private let footerGroup = GlassGroupView(spacing: 8)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let message = NSTextField(labelWithString: "")
    private var rows: [ClipboardEntry] = []
    var onError: ((Error) -> Void)?

    init(store: ClipboardStore) {
        self.store = store
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "剪贴板历史"
        panel.minSize = CGSize(width: 400, height: 320)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.configureLiquidGlassWindow()
        super.init(window: panel)

        panel.contentView = rootGlass
        let content = rootGlass.contentContainer

        search.placeholderString = "搜索文字或截图中的文字"
        search.delegate = self
        search.setAccessibilityLabel("搜索剪贴板历史")
        search.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(search)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        table.headerView = nil
        table.rowHeight = 68
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.backgroundColor = .clear
        table.style = .inset
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(copySelected)
        scroll.documentView = table
        content.addSubview(scroll)

        let copy = NSButton(title: "复制", target: self, action: #selector(copySelected))
        copy.applyLiquidGlassStyle(active: true)
        copy.keyEquivalent = "\r"
        copy.translatesAutoresizingMaskIntoConstraints = false

        footerGroup.translatesAutoresizingMaskIntoConstraints = false
        footerGroup.contentContainer.addSubview(copy)
        content.addSubview(footerGroup)

        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(message)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerGroup.topAnchor, constant: -12),
            copy.topAnchor.constraint(equalTo: footerGroup.contentContainer.topAnchor),
            copy.leadingAnchor.constraint(equalTo: footerGroup.contentContainer.leadingAnchor),
            copy.trailingAnchor.constraint(equalTo: footerGroup.contentContainer.trailingAnchor),
            copy.bottomAnchor.constraint(equalTo: footerGroup.contentContainer.bottomAnchor),
            footerGroup.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            footerGroup.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            message.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            message.trailingAnchor.constraint(lessThanOrEqualTo: footerGroup.leadingAnchor, constant: -8),
            message.centerYAnchor.constraint(equalTo: footerGroup.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        reload()
        guard let panel = window as? NSPanel else { return }
        panel.center()
        let targetFrame = panel.frame
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        panel.animateLiquidGlassEntrance(targetFrame: targetFrame)
    }

    func reload() {
        rows = store.search(search.stringValue)
        table.reloadData()
        if !rows.isEmpty, table.selectedRow == -1 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        message.stringValue = rows.isEmpty ? "暂无记录" : "\(rows.count) 条 · 双击或 Enter 复制"
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let card = GlassSurfaceView(variant: .clear, cornerRadius: 10, isInteractive: false)
        let view = NSStackView()
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 12
        view.translatesAutoresizingMaskIntoConstraints = false

        if let thumbnail = entry.thumbnail {
            let image = NSImageView()
            image.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = 6
            image.layer?.masksToBounds = true
            image.widthAnchor.constraint(equalToConstant: 52).isActive = true
            image.heightAnchor.constraint(equalToConstant: 52).isActive = true
            view.addArrangedSubview(image)
        }

        let text: String
        switch entry.kind {
        case .text: text = entry.text ?? ""
        case .image:
            let metadata = entry.ocrText?.isEmpty == false ? entry.ocrText : nil
            text = metadata ?? (entry.imageURL == nil ? "图片 · 未保存原图" : "图片")
        }

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        view.addArrangedSubview(label)

        card.contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: card.contentContainer.topAnchor, constant: 6),
            view.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor, constant: 10),
            view.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor, constant: -10),
            view.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor, constant: -6)
        ])
        card.setAccessibilityLabel(text)
        return card
    }

    @objc private func copySelected() {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        do {
            try store.copy(rows[row].id, to: .general)
            window?.orderOut(nil)
        } catch { onError?(error) }
    }
}
