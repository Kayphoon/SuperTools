import AppKit

/// The one moment the update pipeline becomes visible: a small non-modal
/// window announcing that a new version has been downloaded and verified,
/// with the install decision left to the user. It never installs on its own
/// and closing it simply defers — the menu keeps an “安装新版本” entry while
/// the staged update exists.
///
/// Styled after the settings window's Kami paper: parchment background,
/// serif title, ink-blue primary action.
@MainActor
final class UpdatePrompt: NSWindowController {
    var onInstall: (() -> Void)?

    private let version: String

    private static let paper = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.137, green: 0.125, blue: 0.098, alpha: 1)
            : NSColor(srgbRed: 0.961, green: 0.957, blue: 0.929, alpha: 1)
    }
    private static let ink = NSColor(srgbRed: 0.106, green: 0.212, blue: 0.365, alpha: 1)

    init(version: String) {
        self.version = version
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 168),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SuperTools 更新"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Self.paper
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        setupViews(in: window)
    }

    required init?(coder: NSCoder) { nil }

    private func setupViews(in window: NSWindow) {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let title = NSTextField(labelWithString: "SuperTools \(version) 已准备好")
        title.font = NSFontManager.shared.font(withFamily: "Songti SC", traits: .boldFontMask, weight: 5, size: 15)
            ?? .systemFont(ofSize: 15, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: "新版本已经下载并通过校验。安装会替换当前应用并自动重新打开，剪贴板历史与设置不受影响。")
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5

        let later = NSButton(title: "稍后", target: self, action: #selector(laterClicked))
        later.bezelStyle = .rounded
        let install = NSButton(title: "安装并重启", target: self, action: #selector(installClicked))
        install.bezelStyle = .rounded
        install.keyEquivalent = "\r"
        install.contentTintColor = Self.ink

        let buttons = NSStackView(views: [later, install])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let head = NSStackView(views: [icon, text])
        head.orientation = .horizontal
        head.alignment = .top
        head.spacing = 12

        let stack = NSStackView(views: [head, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        head.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func installClicked() {
        close()
        onInstall?()
    }

    @objc private func laterClicked() {
        close()
    }
}
