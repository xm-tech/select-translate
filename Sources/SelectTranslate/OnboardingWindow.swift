import AppKit

/// 首次运行 / 未授权时展示的引导窗口。
final class OnboardingWindow: NSWindow {
    var onOpenSettings: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "开启「辅助功能」权限")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "当前状态：未授权")
    private let openButton = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let laterButton = NSButton(title: "稍后", target: nil, action: nil)

    private static let bodyText = """
    「划词翻译」只是一个常驻菜单栏的小工具。为了读取你在任何 App（浏览器、输入框、聊天窗口……）里选中的文字，macOS 要求它获得「辅助功能」权限。

    1. 点击下面的「打开系统设置」；
    2. 在「隐私与安全性 → 辅助功能」中勾选「划词翻译」；
    3. 回到这里，状态会自动变成「已授权」。

    授权后：选中文字（中文或英文都可以）→ 选区下方出现「译」按钮 → 点击查看翻译；点任意其他位置或按 Esc 关闭结果。
    """

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)
        title = "划词翻译 · 开启辅助功能"
        isReleasedWhenClosed = false
        center()
        build()
        refresh()
    }

    private func build() {
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        bodyLabel.font = NSFont.systemFont(ofSize: 13)
        bodyLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openSettingsTapped)

        laterButton.bezelStyle = .rounded
        laterButton.target = self
        laterButton.action = #selector(dismissTapped)

        for view in [titleLabel, bodyLabel, statusLabel, openButton, laterButton] as [NSView] {
            contentView?.addSubview(view)
        }

        let horizontalPadding: CGFloat = 30
        let bodyWidth = 560 - horizontalPadding * 2
        let bodyHeight = (Self.bodyText as NSString).boundingRect(
            with: NSSize(width: bodyWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).height

        let totalHeight = 28 + 26 + 14 + ceil(bodyHeight) + 18 + 18 + 24 + 32 + 26
        setContentSize(NSSize(width: 560, height: totalHeight))

        guard let content = contentView else { return }
        var top = content.bounds.height - 28

        titleLabel.frame = NSRect(x: horizontalPadding, y: top - 26, width: bodyWidth, height: 26)
        top -= 26 + 14

        bodyLabel.frame = NSRect(x: horizontalPadding, y: top - ceil(bodyHeight), width: bodyWidth, height: ceil(bodyHeight))
        bodyLabel.preferredMaxLayoutWidth = bodyWidth
        top -= ceil(bodyHeight) + 18

        statusLabel.frame = NSRect(x: horizontalPadding, y: top - 18, width: bodyWidth, height: 18)
        top -= 18 + 24

        laterButton.frame = NSRect(x: 560 - horizontalPadding - 90, y: top - 32, width: 90, height: 32)
        openButton.frame = NSRect(x: laterButton.frame.minX - 12 - 130, y: top - 32, width: 130, height: 32)
    }

    @objc private func openSettingsTapped() {
        SelectionService().promptForPermission()
        onOpenSettings?()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func dismissTapped() {
        orderOut(nil)
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        statusLabel.stringValue = trusted ? "当前状态：已授权 ✓" : "当前状态：未授权"
        statusLabel.textColor = trusted ? NSColor.systemGreen : NSColor.systemRed
        openButton.title = trusted ? "已授权" : "打开系统设置"
        if trusted { openButton.isEnabled = false }
    }
}
