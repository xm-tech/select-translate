import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var onboarding: OnboardingWindow?
#if !NO_APPLE_TRANSLATION
    private var appleLanguageWindow: NSWindow?
#endif
    private var permissionTimer: Timer?
    private let selectionService = SelectionService()
    private let menu = NSMenu()

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let directory = arguments[index + 1]
            SelfTest.renderSnapshots(into: directory) {
                NSApplication.shared.terminate(nil)
            }
            return
        }

        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        OverlayController.shared.start()

        if !selectionService.isTrusted {
            showOnboarding()
            startPermissionWatch()
        }
#if !NO_APPLE_TRANSLATION
        if CommandLine.arguments.contains("--applepack") {
            showAppleLanguagePack()
        }
#endif
        Log.info("launched trusted=\(selectionService.isTrusted) log=\(Log.path ?? "nil")")
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        OverlayController.shared.stop()
        Log.info("terminated")
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "划词翻译") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "译"
            }
            button.toolTip = "划词翻译：选中文字（中文或英文）后点击「译」按钮"
        }
        menu.delegate = self
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let translateItem = NSMenuItem(title: "翻译当前选中的内容",
                                       action: #selector(translateSelectionFromMenu),
                                       keyEquivalent: "")
        translateItem.target = self
        menu.addItem(translateItem)
        menu.addItem(.separator())

        let enableItem = NSMenuItem(title: "启用划词按钮",
                                    action: #selector(toggleEnabled),
                                    keyEquivalent: "")
        enableItem.target = self
        enableItem.state = Settings.enabled ? .on : .off
        menu.addItem(enableItem)

        let clipboardItem = NSMenuItem(title: "读不到文字时模拟 ⌘C（兜底）",
                                       action: #selector(toggleClipboardFallback),
                                       keyEquivalent: "")
        clipboardItem.target = self
        clipboardItem.state = Settings.clipboardFallback ? .on : .off
        menu.addItem(clipboardItem)

        let directionRoot = NSMenuItem(title: "翻译方向", action: nil, keyEquivalent: "")
        let directionMenu = NSMenu()
        for direction in TranslationDirection.allCases {
            let item = NSMenuItem(title: direction.displayName,
                                  action: #selector(selectDirection(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = direction.rawValue
            item.state = Settings.direction == direction ? .on : .off
            directionMenu.addItem(item)
        }
        directionRoot.submenu = directionMenu
        menu.addItem(directionRoot)

        let providerRoot = NSMenuItem(title: "翻译服务", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        for choice in ProviderChoice.allCases where choice.isSupportedInThisBuild {
            let item = NSMenuItem(title: choice.displayName,
                                  action: #selector(selectProvider(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = Settings.provider == choice ? .on : .off
            providerMenu.addItem(item)
        }
#if !NO_APPLE_TRANSLATION
        providerMenu.addItem(.separator())
        let applePackItem = NSMenuItem(title: "下载 Apple 本地语言包…",
                                       action: #selector(showAppleLanguagePack),
                                       keyEquivalent: "")
        applePackItem.target = self
        providerMenu.addItem(applePackItem)
#endif
        providerRoot.submenu = providerMenu
        menu.addItem(providerRoot)

        menu.addItem(.separator())

        let trusted = selectionService.isTrusted
        let permissionItem = NSMenuItem(title: trusted ? "辅助功能权限：已授权" : "开启辅助功能权限…",
                                        action: #selector(permissionAction),
                                        keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let diagnoseItem = NSMenuItem(title: "运行诊断…", action: #selector(runDiagnostics), keyEquivalent: "")
        diagnoseItem.target = self
        menu.addItem(diagnoseItem)

        let testItem = NSMenuItem(title: "测试翻译…", action: #selector(testTranslation), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        let logItem = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于划词翻译", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出划词翻译", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - 菜单动作

    @objc private func translateSelectionFromMenu() {
        NSApp.activate(ignoringOtherApps: false)
        OverlayController.shared.translateCurrentSelectionForMenu()
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        if !Settings.enabled { OverlayController.shared.dismissAll(remember: false) }
        Log.info("enabled=\(Settings.enabled)")
    }

    @objc private func toggleClipboardFallback() {
        Settings.clipboardFallback.toggle()
        Log.info("clipboardFallback=\(Settings.clipboardFallback)")
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = ProviderChoice(rawValue: raw) else { return }
        Settings.provider = choice
        Log.info("provider=\(choice.rawValue)")
    }

    @objc private func selectDirection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let direction = TranslationDirection(rawValue: raw) else { return }
        Settings.direction = direction
        Log.info("direction=\(direction.rawValue)")
    }

    @objc private func permissionAction() {
        if selectionService.isTrusted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        showOnboarding()
        startPermissionWatch()
        selectionService.promptForPermission()
    }

#if !NO_APPLE_TRANSLATION
    @objc private func showAppleLanguagePack() {
        guard #available(macOS 26.0, *) else {
            presentAlert(title: "系统版本过低", message: "Apple 本地翻译需要 macOS 26 及以上系统。")
            return
        }
        let window = appleLanguageWindow as? AppleLanguagePackWindow ?? AppleLanguagePackWindow()
        appleLanguageWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
#endif

    @objc private func openLog() {
        Log.configureDefault()
        guard let path = Log.path else { return }
        if !FileManager.default.fileExists(atPath: path) {
            try? "（暂无日志）\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        presentAlert(title: "划词翻译",
                     message: """
                     版本 1.1

                     在任意 App 中选中文字，点「译」即可翻译：
                     · 选中英文 → 中文
                     · 选中中文 → 英文
                     方向默认自动判断，可在菜单栏「翻译方向」里锁定。

                     翻译服务（菜单栏「翻译服务」）：Apple 本地（离线）→ 腾讯 → MyMemory → Google，前一个失败自动降级。
                     日志：\(Log.path ?? "unknown")
                     """)
    }

    @objc private func testTranslation() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "测试翻译"
        alert.informativeText = "输入一段文字（英文→中文，或中文→英文），用当前翻译服务（\(Settings.provider.shortName)、方向：\(Settings.direction.shortName)）试一次。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = "The quick brown fox jumps over the lazy dog."
        alert.accessoryView = field
        alert.addButton(withTitle: "翻译")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue
        Task { [weak self] in
            do {
                let result = try await Translator.shared.translate(text, preferred: Settings.provider)
                DispatchQueue.main.async {
                    self?.presentAlert(title: "翻译完成（\(result.provider)）", message: result.translated)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async {
                    self?.presentAlert(title: "翻译失败", message: message)
                }
            }
        }
    }

    @objc private func runDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)

        Task { [weak self] in
            var lines: [String] = []
            let trusted = AXIsProcessTrusted()
            lines.append("辅助功能权限：\(trusted ? "已授权" : "未授权（读不到选区）")")
            lines.append("日志文件：\(Log.path ?? "unknown")")

            if let app = NSWorkspace.shared.frontmostApplication {
                lines.append("前台 App：\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
            }

            let selection = SelectionService().currentSelection(useClipboardFallback: false)
            if let selection {
                lines.append("当前选区：\(selection.text.count) 字符（\(selection.appName)）")
                if let rect = selection.rect {
                    lines.append("选区位置：\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))")
                } else {
                    lines.append("选区位置：未取到（会退化为鼠标位置附近）")
                }
            } else {
                lines.append("当前选区：未检测到")
            }

#if NO_APPLE_TRANSLATION
            lines.append("Apple 本地翻译：当前构建未包含（编译时 SDK 低于 macOS 26）")
#else
            if #available(macOS 26.0, *) {
                lines.append("Apple 本地翻译 英→中：\(await AppleTranslator.statusDescription(for: .enToZh))")
                lines.append("Apple 本地翻译 中→英：\(await AppleTranslator.statusDescription(for: .zhToEn))")
            } else {
                lines.append("Apple 本地翻译：需要 macOS 26 及以上")
            }
#endif

            for kind in [ProviderChoice.tencent, .mymemory] {
                do {
                    let result = try await Translator.shared.translate("Hello, world.", preferred: kind)
                    lines.append("\(kind.shortName)：可用（\(result.translated)）")
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    lines.append("\(kind.shortName)：不可用（\(message)）")
                }
            }

            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "诊断结果"
                alert.informativeText = text
                alert.addButton(withTitle: "好")
                alert.addButton(withTitle: "复制")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
            }
        }
    }

    // MARK: - 授权引导

    private func showOnboarding() {
        let window = onboarding ?? OnboardingWindow()
        onboarding = window
        window.refresh()
        window.onOpenSettings = { Log.info("open accessibility settings") }
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onboarding?.refresh()
            let trusted = AXIsProcessTrusted()
            if trusted {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.onboarding?.orderOut(nil)
                Log.info("accessibility granted")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: - 工具

    private func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
