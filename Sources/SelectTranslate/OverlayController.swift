import AppKit

/// 无边框浮层窗口：不抢焦点、可跨 Space / 全屏 App 显示。
final class FloatingPanel: NSPanel {
    private let wantsKey: Bool

    init(wantsKey: Bool) {
        self.wantsKey = wantsKey
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }
}

/// 划词交互的中枢：轮询选区 → 浮出按钮 → 点击翻译 → 展示结果卡片 → 点击别处关闭。
final class OverlayController {
    static let shared = OverlayController()

    private let shadowMargin: CGFloat = 12
    private let buttonMargin: CGFloat = 7
    private let buttonSize = NSSize(width: 44, height: 28)

    private let selectionService = SelectionService()
    private let buttonPanel = FloatingPanel(wantsKey: false)
    private let resultPanel = FloatingPanel(wantsKey: false)
    private let resultContainer = NSView()
    private let buttonHost = NSView()
    private let translateButton: PillView
    private let resultCard = ResultCardView()

    private var lastSelection: SelectionInfo?
    private var activeSelection: SelectionInfo?
    private var dismissedSignature: String?
    private var dismissedAt: Date?
    private var pollTimer: Timer?
    private var lastMouseDownPoint: CGPoint?
    private var lastMouseDownClickCount = 0
    private var selectionCheckWork: DispatchWorkItem?
    private var translateTask: Task<Void, Never>?
    private var translationID = UUID()
    private var monitors: [Any] = []
    private var started = false
    private var translating = false

    private init() {
        translateButton = PillView(title: "译",
                                   fontSize: 14,
                                   background: NSColor(calibratedWhite: 0.10, alpha: 0.98),
                                   hoverBackground: NSColor(calibratedWhite: 0.22, alpha: 0.98))
        translateButton.borderColor = NSColor(calibratedWhite: 1, alpha: 0.28)
        translateButton.wantsLayer = true
        translateButton.layer?.shadowColor = NSColor.black.cgColor
        translateButton.layer?.shadowOpacity = 0.35
        translateButton.layer?.shadowRadius = 5
        translateButton.layer?.shadowOffset = CGSize(width: 0, height: -1)

        buttonPanel.contentView = buttonHost
        buttonHost.addSubview(translateButton)
        buttonPanel.hasShadow = false

        resultPanel.contentView = resultContainer
        resultContainer.addSubview(resultCard)

        translateButton.onClick = { [weak self] in self?.translateTapped() }
        resultCard.onClose = { [weak self] in self?.closeResult(remember: true) }
        resultCard.onRetry = { [weak self] in self?.retryTapped() }
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        installMonitors()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        let timer = Timer(timeInterval: 0.7, target: self, selector: #selector(pollTimerFired), userInfo: nil, repeats: true)
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Log.info("overlay started")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        started = false
    }

    func dismissAll(remember: Bool) {
        selectionCheckWork?.cancel()
        selectionCheckWork = nil
        if resultPanel.isVisible { closeResult(remember: remember) }
        if buttonPanel.isVisible { hideButton(remember: remember) }
    }

    // MARK: - 事件监听

    private func installMonitors() {
        let globalClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.lastMouseDownPoint = NSEvent.mouseLocation
                self?.lastMouseDownClickCount = event.clickCount
                self?.outsideMouseDown()
            }
        }
        let globalMouseUp = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                // 只有“拖选 / 双击 / 三击”才值得用 ⌘C 探测选区：
                // 普通单击只是移动光标，某些编辑器（VS Code 的 emptySelectionClipboard）
                // 在空选区下 ⌘C 会复制整行，会误弹按钮。
                let dragged = self.lastMouseDownPoint.map { start in
                    hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y)
                } ?? 0
                let allowFallback = dragged > 4 || self.lastMouseDownClickCount >= 2 || event.clickCount >= 2
                self.scheduleSelectionCheck(after: 0.12, allowClipboardFallback: allowFallback)
            }
        }
        let globalKey = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async { self?.dismissAll(remember: true) }
        }
        let localKey = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismissAll(remember: true)
            return nil
        }
        for monitor in [globalClick, globalMouseUp, globalKey, localKey].compactMap({ $0 }) {
            monitors.append(monitor)
        }
    }

    @objc private func applicationActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        dismissAll(remember: true)
    }

    @objc private func screenParametersChanged() {
        guard resultPanel.isVisible || buttonPanel.isVisible else { return }
        positionResultPanel()
    }

    private func outsideMouseDown() {
        if resultPanel.isVisible {
            closeResult(remember: true)
        } else if buttonPanel.isVisible {
            hideButton(remember: true)
        }
    }

    private func scheduleSelectionCheck(after delay: TimeInterval, allowClipboardFallback: Bool) {
        selectionCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.poll(allowClipboardFallback: allowClipboardFallback)
        }
        selectionCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 轮询 & 按钮

    @objc private func pollTimerFired() {
        poll(allowClipboardFallback: false)
    }

    private func poll(allowClipboardFallback: Bool) {
        guard Settings.enabled else {
            dismissAll(remember: false)
            return
        }
        guard selectionService.isTrusted else {
            dismissAll(remember: false)
            return
        }
        guard !resultPanel.isVisible, !translating else { return }

        guard let selection = selectionService.currentSelectionAfterMouseUp(useClipboardFallback: allowClipboardFallback) else {
            // ⌘C 兜底拿到的选区无法持续探测（AX 里没有选区信息），按钮已经弹出来了就留着，
            // 等用户点别处 / 按 Esc 再收起，否则按钮会在两次轮询之间闪一下就消失。
            if buttonPanel.isVisible, let last = lastSelection, last.usedClipboard {
                return
            }
            // 注意：这里**不**清 dismissedSignature —— AX 偶尔会有一两次探测不到选区，
            // 一清就等于把「刚被用户关掉」这件事忘了，下一轮轮询又会把按钮弹回来。
            hideButton(remember: false)
            lastSelection = nil
            return
        }

        let signature = Self.signature(for: selection)
        if signature == dismissedSignature, let at = dismissedAt, Date().timeIntervalSince(at) < 30 {
            return
        }
        if buttonPanel.isVisible,
           let current = lastSelection,
           Self.signature(for: current) == signature {
            return
        }
        lastSelection = selection
        showButton(for: selection)
    }

    private func showButton(for selection: SelectionInfo) {
        lastSelection = selection
        Log.info("show button rect=\(selection.rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil") clipboard=\(selection.usedClipboard)")
        let panelSize = NSSize(width: buttonSize.width + buttonMargin * 2,
                               height: buttonSize.height + buttonMargin * 2)
        let origin = buttonOrigin(for: selection, panelSize: panelSize)
        buttonPanel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        buttonHost.frame = NSRect(origin: .zero, size: panelSize)
        translateButton.frame = NSRect(x: buttonMargin,
                                       y: buttonMargin,
                                       width: buttonSize.width,
                                       height: buttonSize.height)
        buttonPanel.orderFrontRegardless()
    }

    private func hideButton(remember: Bool) {
        if remember, let selection = lastSelection {
            dismissedSignature = Self.signature(for: selection)
            dismissedAt = Date()
        }
        buttonPanel.orderOut(nil)
    }

    private func translateTapped() {
        guard let selection = lastSelection else { return }
        guard !translating else { return }
        // 结果卡片开着期间（以及关闭之后）都不应该再为同一段选区弹按钮，
        // 否则轮询会把「译」重新放出来，看着像关不掉。
        dismissedSignature = Self.signature(for: selection)
        dismissedAt = Date()
        buttonPanel.orderOut(nil)
        activeSelection = selection
        startTranslation(for: selection)
    }

    private func retryTapped() {
        guard let selection = activeSelection else { return }
        startTranslation(for: selection)
    }

    // MARK: - 翻译 & 结果卡片

    private func startTranslation(for selection: SelectionInfo) {
        translating = true
        let id = UUID()
        translationID = id
        let requested = Settings.direction
        let effective: TranslationDirection = requested == .auto
            ? TranslationDirection.detect(selection.text)
            : requested
        resultCard.configureLoading(appName: selection.appName, direction: effective)
        positionResultPanel()
        resultPanel.orderFrontRegardless()
        if !resultPanel.isVisible {
            resultPanel.orderFrontRegardless()
        }
        Log.info("translate start chars=\(selection.text.count) direction=\(effective.rawValue) app=\(selection.bundleID ?? selection.appName)")

        let preferred = Settings.provider
        translateTask = Task { [weak self] in
            do {
                let result = try await Translator.shared.translate(selection.text,
                                                                   preferred: preferred,
                                                                   direction: requested)
                DispatchQueue.main.async {
                    guard let self, self.translationID == id else { return }
                    self.translating = false
                    self.resultCard.configureSuccess(result: result, appName: selection.appName)
                    self.positionResultPanel()
                    Log.info("translate shown provider=\(result.provider) chars=\(result.translated.count)")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, self.translationID == id else { return }
                    self.translating = false
                    self.resultCard.configureFailure(message: message, appName: selection.appName, direction: effective)
                    self.positionResultPanel()
                    Log.info("translate show error=\(message)")
                }
            }
        }
    }

    private func closeResult(remember: Bool) {
        if remember, let selection = lastSelection ?? activeSelection {
            dismissedSignature = Self.signature(for: selection)
            dismissedAt = Date()
        }
        translationID = UUID()
        translateTask?.cancel()
        translateTask = nil
        translating = false
        resultPanel.orderOut(nil)
        buttonPanel.orderOut(nil)
        activeSelection = nil
    }

    private func positionResultPanel() {
        let cardSize = resultCard.preferredSize
        resultCard.frame = NSRect(x: shadowMargin,
                                  y: shadowMargin,
                                  width: cardSize.width,
                                  height: cardSize.height)
        let panelSize = NSSize(width: cardSize.width + shadowMargin * 2,
                               height: cardSize.height + shadowMargin * 2)
        let anchor = activeSelection
        let origin = cardOrigin(for: anchor, size: panelSize)
        resultPanel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        resultContainer.frame = NSRect(origin: .zero, size: panelSize)
        resultCard.frame = NSRect(x: shadowMargin,
                                  y: shadowMargin,
                                  width: cardSize.width,
                                  height: cardSize.height)
        resultCard.needsDisplay = true
    }

    // MARK: - 位置计算

    private func buttonOrigin(for selection: SelectionInfo, panelSize: NSSize) -> CGPoint {
        let visible = screen(for: selection).visibleFrame
        let target = selection.rect ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let gap: CGFloat = 8

        var x = target.midX - panelSize.width / 2
        var y = target.minY - gap - panelSize.height

        if y < visible.minY + 4 {
            let above = target.maxY + gap
            if above + panelSize.height <= visible.maxY - 4 {
                y = above
            } else {
                y = visible.minY + 4
            }
        }
        x = Self.clamp(x, visible.minX + 4, visible.maxX - 4 - panelSize.width)
        y = Self.clamp(y, visible.minY + 4, visible.maxY - 4 - panelSize.height)
        return CGPoint(x: x, y: y)
    }

    private func cardOrigin(for selection: SelectionInfo?, size: NSSize) -> CGPoint {
        let visible = screen(for: selection).visibleFrame
        let target = selection?.rect ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let gap: CGFloat = 10

        var x = target.midX - size.width / 2
        var y = target.minY - gap - size.height
        if y < visible.minY + 8 {
            let above = target.maxY + gap
            if above + size.height <= visible.maxY - 8 {
                y = above
            } else {
                y = visible.maxY - 8 - size.height
            }
        }
        x = Self.clamp(x, visible.minX + 8, visible.maxX - 8 - size.width)
        y = Self.clamp(y, visible.minY + 8, visible.maxY - 8 - size.height)
        return CGPoint(x: x, y: y)
    }

    private func screen(for selection: SelectionInfo?) -> NSScreen {
        if let rect = selection?.rect,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }

    /// 「同一段选区」的判定键。这里刻意**不**把选区矩形算进去：
    /// 同一个选区在两次 AX 查询之间常常会有一两个像素的抖动（多行选区尤其明显），
    /// 一旦矩形参与判定，关闭卡片后轮询就会把「译」又弹出来，看着像关不掉。
    /// 文字变了就算新选区，用户重新选别的内容时按钮会正常出现。
    private static func signature(for selection: SelectionInfo) -> String {
        let prefix = String(selection.text.prefix(160))
        return "\(selection.pid)|\(prefix)"
    }

    // MARK: - 菜单栏用

    func translateCurrentSelectionForMenu() {
        guard let selection = selectionService.currentSelection(useClipboardFallback: true) else {
            NSSound.beep()
            return
        }
        activeSelection = selection
        lastSelection = selection
        translating = true
        startTranslation(for: selection)
    }

    var isPanelVisible: Bool { resultPanel.isVisible || buttonPanel.isVisible }
}
