import AppKit
import ApplicationServices

enum SelfTest {
    // MARK: - 翻译链路自测（命令行）

    static func runTranslationCLI() {
        print("== 划词翻译 · 链路自测 ==")

        let samples = [
            "Hello world, this is a test.",
            "Select any text anywhere on your Mac and translate it into Chinese."
        ]
        for sample in samples {
            for choice in [ProviderChoice.tencent, .mymemory, .google] {
                print("[\(choice.shortName) · 英译中] \(sample)")
                print("    → \(runSync(timeout: 25) { try await Translator.shared.translate(sample, preferred: choice, direction: .enToZh) })")
            }
        }

        let chineseSamples = [
            "选中任意文字就能翻译，这个工具默认会自动判断中英文方向。",
            "请确保发票在开具之日起 30 天内结清。"
        ]
        for sample in chineseSamples {
            for choice in [ProviderChoice.tencent, .mymemory, .google] {
                print("[\(choice.shortName) · 中译英] \(sample)")
                print("    → \(runSync(timeout: 25) { try await Translator.shared.translate(sample, preferred: choice, direction: .zhToEn) })")
            }
        }

        print("[自动方向检测] ")
        for probe in ["Hello world, this is a test.", "这是一个自动检测方向的测试。", "用 Swift 写一个 macOS App"] {
            print("    \(probe) → \(TranslationDirection.detect(probe).shortName)")
        }

        let longText = String(repeating: "This is a long sentence used for chunk testing. ", count: 60)
        print("[长文 \(longText.count) 字符 · 腾讯]")
        print("    → \(runSync(timeout: 45) { try await Translator.shared.translate(longText, preferred: .tencent, direction: .enToZh) })")
        print("== 自测结束 ==")
    }

    private static func runSync(timeout: TimeInterval,
                                _ work: @escaping () async throws -> TranslationResult) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do {
                let result = try await work()
                box.value = "OK(\(result.provider)) \(trimmed(result.translated))"
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                box.value = "FAIL \(message)"
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return "TIMEOUT(\(Int(timeout))s)"
        }
        return box.value
    }

    private static func trimmed(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > 100 ? String(single.prefix(100)) + "…" : single
    }

    private final class ResultBox {
        var value = "UNKNOWN"
    }

    // MARK: - 辅助功能探针（命令行）

    static func runAccessibilityProbe() {
        print("== 辅助功能探针 ==")
        print("trusted=\(AXIsProcessTrusted())")
        if let app = NSWorkspace.shared.frontmostApplication {
            print("frontmost=\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) pid=\(app.processIdentifier)")
        }
        let service = SelectionService()
        guard let selection = service.currentSelection(useClipboardFallback: true) else {
            print("selection=nil（没检测到选中文字）")
            return
        }
        print("selection chars=\(selection.text.count) app=\(selection.appName) pid=\(selection.pid) clipboard=\(selection.usedClipboard)")
        print("text=\(selection.text.prefix(200))")
        if let rect = selection.rect {
            print("rect=x\(Int(rect.minX)) y\(Int(rect.minY)) w\(Int(rect.width)) h\(Int(rect.height))")
        } else {
            print("rect=nil")
        }
    }

    // MARK: - 生成 App 图标

    static func renderAppIcon(to path: String) -> Bool {
        let side: CGFloat = 1024
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset: CGFloat = 44
            let body = rect.insetBy(dx: inset, dy: inset)
            let radius = body.width * 0.225
            let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            let gradient = NSGradient(starting: NSColor(calibratedRed: 0.29, green: 0.55, blue: 1.0, alpha: 1),
                                      ending: NSColor(calibratedRed: 0.09, green: 0.26, blue: 0.82, alpha: 1))
            gradient?.draw(in: shape, angle: -90)

            let glyph = NSAttributedString(string: "译", attributes: [
                .font: NSFont.systemFont(ofSize: 520, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            let glyphSize = glyph.size()
            glyph.draw(at: NSPoint(x: (rect.width - glyphSize.width) / 2,
                                   y: (rect.height - glyphSize.height) / 2 + 10))
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - 浮层截图（用来自检界面效果）

    static func renderSnapshots(into directory: String, completion: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let card = ResultCardView(frame: .zero)
        let cardSize = card.preferredSize
        let canvasWidth = cardSize.width + 48
        let canvasHeight = cardSize.height + 150

        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1).cgColor

        let button = PillView(title: "译",
                              fontSize: 14,
                              background: NSColor(calibratedWhite: 0.10, alpha: 0.98),
                              hoverBackground: NSColor(calibratedWhite: 0.22, alpha: 0.98))
        button.borderColor = NSColor(calibratedWhite: 1, alpha: 0.28)
        button.frame = NSRect(x: 24, y: canvasHeight - 66, width: 44, height: 28)
        canvas.addSubview(button)

        card.frame = NSRect(x: 24, y: 24, width: cardSize.width, height: cardSize.height)
        canvas.addSubview(card)

        let window = NSWindow(contentRect: canvas.frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.contentView = canvas
        window.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        window.isOpaque = true
        window.orderFrontRegardless()

        func capture(_ name: String, _ done: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                canvas.displayIfNeeded()
                if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                    canvas.cacheDisplay(in: canvas.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let path = (directory as NSString).appendingPathComponent(name)
                        try? data.write(to: URL(fileURLWithPath: path))
                        print("snapshot: \(path)")
                    }
                }
                done()
            }
        }

        card.configureSuccess(
            result: TranslationResult(
                translated: "速度快、安全，而且随取随用。无论你是在浏览器里选中一段英文，还是在聊天窗口、邮件或终端里选中文字，都可以一键查看中文释义。",
                provider: "腾讯翻译",
                direction: .enToZh
            ),
            appName: "Safari"
        )
        card.frame = NSRect(x: 24, y: 24, width: cardSize.width, height: card.preferredSize.height)
        capture("result-success.png") {
            card.configureLoading(appName: "Google Chrome")
            card.frame = NSRect(x: 24, y: 24, width: cardSize.width, height: card.preferredSize.height)
            capture("result-loading.png") {
                card.configureFailure(
                    message: "翻译失败：腾讯翻译：网络无响应；MyMemory：免费额度受限",
                    appName: "Notes"
                )
                card.frame = NSRect(x: 24, y: 24, width: cardSize.width, height: card.preferredSize.height)
                capture("result-error.png") {
                    window.orderOut(nil)
                    completion()
                }
            }
        }
    }
    // MARK: - Apple 本地翻译探针

    /// `--appletest`：打印 Apple 本地翻译的语言包状态，已安装则实测一句。
    static func runAppleTranslationTest() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            print("TIMEOUT")
            exit(2)
        }

        Task { @MainActor in
            guard #available(macOS 26.0, *) else {
                print("apple translation requires macOS 26 or newer")
                exit(1)
            }
            print("apple en→zh: \(await AppleTranslator.statusDescription(for: .enToZh))")
            print("apple zh→en: \(await AppleTranslator.statusDescription(for: .zhToEn))")
            guard await AppleTranslator.isInstalled(for: .enToZh),
                  await AppleTranslator.isInstalled(for: .zhToEn) else {
                print("apple language pack not installed")
                exit(0)
            }
            do {
                let sample = "The committee has not yet decided whether the proposal should be submitted before the end of the quarter."
                let start = Date()
                let output = try await AppleTranslator.translate(sample, direction: .enToZh)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                print("apple en→zh in \(ms)ms: \(output)")

                let chinese = "这是一个用于测试中译英的句子。"
                let start2 = Date()
                let back = try await AppleTranslator.translate(chinese, direction: .zhToEn)
                let ms2 = Int(Date().timeIntervalSince(start2) * 1000)
                print("apple zh→en in \(ms2)ms: \(back)")

                let short = try await AppleTranslator.translate("你好，世界。", direction: .zhToEn)
                print("apple short zh→en: \(short)")
            } catch {
                print("apple failed: \(error)")
                exit(1)
            }
            exit(0)
        }

        app.run()
    }
}
