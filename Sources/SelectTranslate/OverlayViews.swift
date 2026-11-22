import AppKit

/// 自绘的小胶囊按钮：深色底、悬停高亮、支持非激活窗口下直接点击。
final class PillView: NSView {
    var title: String { didSet { needsDisplay = true } }
    var fontSize: CGFloat { didSet { needsDisplay = true } }
    var fontWeight: NSFont.Weight = .semibold { didSet { needsDisplay = true } }
    var textColor: NSColor = .white { didSet { needsDisplay = true } }
    var background: NSColor { didSet { needsDisplay = true } }
    var hoverBackground: NSColor
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    private var pressing = false { didSet { needsDisplay = true } }
    private var trackingAreaRef: NSTrackingArea?

    init(title: String,
         fontSize: CGFloat = 12,
         background: NSColor,
         hoverBackground: NSColor) {
        self.title = title
        self.fontSize = fontSize
        self.background = background
        self.hoverBackground = hoverBackground
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressing = false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        pressing = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inside = bounds.contains(point)
        pressing = false
        if inside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 1, rect.height > 1 else { return }
        let radius = cornerRadius > 0 ? min(cornerRadius, rect.height / 2) : rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        let fill: NSColor
        if pressing {
            fill = hoverBackground
        } else if hovering {
            fill = hoverBackground
        } else {
            fill = background
        }
        fill.setFill()
        path.fill()

        if let borderColor {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        let origin = NSPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2)
        text.draw(at: origin)
    }
}

/// 翻译结果卡片（不含窗口阴影边距，由外层容器留白）。
final class ResultCardView: NSView {
    static let contentWidth: CGFloat = 420
    static let headerHeight: CGFloat = 46
    static let footerHeight: CGFloat = 46
    static let padding: CGFloat = 16
    static let bodyGap: CGFloat = 12
    static let maxBodyHeight: CGFloat = 300

    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "翻译")
    private let directionLabel = NSTextField(labelWithString: "")
    private let appNameLabel = NSTextField(labelWithString: "")
    private let closeButton: PillView
    private let separator = NSView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let providerLabel = NSTextField(labelWithString: "")
    private let copyButton: PillView
    private let retryButton: PillView

    private var bodyHeight: CGFloat = 56
    private var contentHeight: CGFloat = 0
    private var plainText = ""
    private var copyResetWork: DispatchWorkItem?

    private let bodyFont = NSFont.systemFont(ofSize: 14.5)
    private let normalTextColor = NSColor(calibratedWhite: 0.95, alpha: 1)
    private let errorTextColor = NSColor(calibratedRed: 1.0, green: 0.56, blue: 0.52, alpha: 1)

    override init(frame frameRect: NSRect) {
        let subtle = NSColor(calibratedWhite: 1, alpha: 0.10)
        let subtleHover = NSColor(calibratedWhite: 1, alpha: 0.20)
        closeButton = PillView(title: "✕", fontSize: 12, background: .clear, hoverBackground: NSColor(calibratedWhite: 1, alpha: 0.14))
        copyButton = PillView(title: "复制", fontSize: 11.5, background: subtle, hoverBackground: subtleHover)
        retryButton = PillView(title: "重试", fontSize: 11.5, background: subtle, hoverBackground: subtleHover)
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var isFlipped: Bool { false }

    var preferredSize: NSSize {
        NSSize(width: Self.contentWidth,
               height: Self.headerHeight + Self.footerHeight + bodyHeight + Self.bodyGap * 2)
    }

    // MARK: - 对外状态

    func configureLoading(appName: String, direction: TranslationDirection = .enToZh) {
        appNameLabel.stringValue = appName
        updateDirection(direction)
        statusLabel.stringValue = "正在翻译…"
        plainText = ""
        contentHeight = 0
        bodyHeight = 54
        scrollView.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusLabel.isHidden = false
        providerLabel.stringValue = ""
        providerLabel.isHidden = true
        copyButton.isHidden = true
        retryButton.isHidden = true
        layoutCard()
        needsDisplay = true
    }

    func configureSuccess(result: TranslationResult, appName: String) {
        appNameLabel.stringValue = appName
        updateDirection(result.direction)
        plainText = result.translated
        providerLabel.stringValue = result.provider
        providerLabel.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.isHidden = true
        retryButton.isHidden = true
        copyButton.isHidden = false
        copyButton.title = "复制"
        scrollView.isHidden = false
        applyText(plainText, color: normalTextColor)
        needsDisplay = true
    }

    func configureFailure(message: String, appName: String, direction: TranslationDirection = .enToZh) {
        appNameLabel.stringValue = appName
        updateDirection(direction)
        plainText = ""
        providerLabel.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.isHidden = true
        copyButton.isHidden = true
        retryButton.isHidden = false
        scrollView.isHidden = false
        applyText(message, color: errorTextColor)
        needsDisplay = true
    }

    private func updateDirection(_ direction: TranslationDirection) {
        let badge = direction.badge
        directionLabel.stringValue = badge
        directionLabel.isHidden = badge.isEmpty
        layoutCard()
    }

    // MARK: - 构建

    private func setup() {
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        titleLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)

        directionLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        directionLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        directionLabel.isHidden = true

        appNameLabel.font = NSFont.systemFont(ofSize: 11)
        appNameLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.45)
        appNameLabel.alignment = .right
        appNameLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = NSFont.systemFont(ofSize: 12.5)
        statusLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.7)

        providerLabel.font = NSFont.systemFont(ofSize: 11)
        providerLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.45)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.09).cgColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.isHidden = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.font = bodyFont
        textView.textColor = normalTextColor
        scrollView.documentView = textView

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)

        closeButton.onClick = { [weak self] in self?.onClose?() }
        copyButton.onClick = { [weak self] in self?.copyTranslated() }
        retryButton.onClick = { [weak self] in self?.onRetry?() }

        for view in [titleLabel, directionLabel, appNameLabel, closeButton, separator, scrollView, spinner, statusLabel, providerLabel, copyButton, retryButton] {
            addSubview(view)
        }
    }

    private func applyText(_ text: String, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textView.textColor = color

        let width = Self.contentWidth - Self.padding * 2
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).height
        contentHeight = max(ceil(measured) + 8, 24)
        bodyHeight = min(max(contentHeight, 44), Self.maxBodyHeight)
        layoutCard()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCard()
    }

    private func layoutCard() {
        guard bounds.width > 1 else { return }
        let width = bounds.width
        let textWidth = width - Self.padding * 2
        let footerMidY = Self.footerHeight / 2
        let bodyBottom = Self.footerHeight + Self.bodyGap
        let headerBottom = bodyBottom + bodyHeight + Self.bodyGap
        let headerMidY = headerBottom + Self.headerHeight / 2

        titleLabel.sizeToFit()
        titleLabel.setFrameOrigin(NSPoint(x: Self.padding,
                                          y: headerMidY - titleLabel.frame.height / 2))

        directionLabel.sizeToFit()
        let badgeGap: CGFloat = directionLabel.isHidden ? 0 : 7
        directionLabel.setFrameOrigin(NSPoint(x: titleLabel.frame.maxX + badgeGap,
                                              y: headerMidY - directionLabel.frame.height / 2))

        closeButton.frame = NSRect(x: width - Self.padding - 26,
                                   y: headerMidY - 13,
                                   width: 26,
                                   height: 26)

        appNameLabel.sizeToFit()
        let appWidth = min(appNameLabel.frame.width, 170)
        appNameLabel.frame = NSRect(x: closeButton.frame.minX - 10 - appWidth,
                                    y: headerMidY - appNameLabel.frame.height / 2,
                                    width: appWidth,
                                    height: appNameLabel.frame.height)

        separator.frame = NSRect(x: Self.padding, y: headerBottom, width: textWidth, height: 1)

        scrollView.frame = NSRect(x: Self.padding, y: bodyBottom, width: textWidth, height: bodyHeight)
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(contentHeight, bodyHeight))

        let bodyMidY = bodyBottom + bodyHeight / 2
        spinner.frame = NSRect(x: 0, y: bodyMidY - 8, width: 16, height: 16)
        statusLabel.sizeToFit()
        let groupWidth = 16 + 9 + statusLabel.frame.width
        let groupX = (width - groupWidth) / 2
        spinner.setFrameOrigin(NSPoint(x: groupX, y: bodyMidY - 8))
        statusLabel.setFrameOrigin(NSPoint(x: groupX + 25,
                                           y: bodyMidY - statusLabel.frame.height / 2))

        providerLabel.sizeToFit()
        providerLabel.setFrameOrigin(NSPoint(x: Self.padding,
                                             y: footerMidY - providerLabel.frame.height / 2))

        retryButton.frame = NSRect(x: Self.padding, y: footerMidY - 13, width: 54, height: 26)
        copyButton.frame = NSRect(x: width - Self.padding - 58, y: footerMidY - 13, width: 58, height: 26)
    }

    private func copyTranslated() {
        guard !plainText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
        copyButton.title = "已复制"
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copyButton.title = "复制" }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.09, alpha: 0.98).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
