import AppKit
import ApplicationServices

// 端到端验证（真实 UI）：
//   A. TextEdit 打开英文样本，AX 设置选区 → App 在选区下方浮出「译」按钮
//   B. 合成点击按钮 → 结果卡片出现
//   C. 点卡片右上「✕」→ 卡片关闭
//   D. 换一段选区再翻译 → 点「复制」→ 剪贴板内容与卡片字数一致
// 同时通过 AX 读取 App 自己的浮层窗口位置，做客观断言；每步截图。

enum E2E {
    static let workdir = FileManager.default.currentDirectoryPath + "/.tmp/e2e-zh-out"
    static var appKitHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static var logPath: String { (workdir as NSString).appendingPathComponent("app.log") }

    // MARK: - AX 工具

    static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = axValue(element, attribute) else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func role(_ element: AXUIElement) -> String {
        (axValue(element, kAXRoleAttribute) as? String) ?? ""
    }

    static func find(_ element: AXUIElement, role wanted: String, depth: Int = 0) -> AXUIElement? {
        if role(element) == wanted { return element }
        guard depth < 12 else { return nil }
        guard let children = axValue(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let hit = find(child, role: wanted, depth: depth + 1) { return hit }
        }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point)
        AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(x: point.x, y: appKitHeight - (point.y + size.height), width: size.width, height: size.height)
    }

    /// 被测 App 的可见窗口（AppKit 坐标）
    static func panels(ofPID pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = axValue(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { frame(of: $0) }
    }

    static func waitForPanel(ofPID pid: pid_t, timeout: TimeInterval, matching: @escaping (CGRect) -> Bool) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = panels(ofPID: pid).first(where: matching) { return hit }
            usleep(150_000)
        }
        return nil
    }

    // MARK: - 截图 / 点击

    static func capture(_ name: String, appKitCenter: CGPoint, size: NSSize = NSSize(width: 1000, height: 760)) {
        let path = (workdir as NSString).appendingPathComponent(name)
        let cgCenter = CGPoint(x: appKitCenter.x, y: appKitHeight - appKitCenter.y)
        let originX = Int(cgCenter.x - size.width / 2)
        let originY = Int(cgCenter.y - size.height / 2)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(originX),\(originY),\(Int(size.width)),\(Int(size.height))", path]
        try? process.run()
        process.waitUntilExit()
        print("  截图 \(name)")
    }

    static func click(appKit point: CGPoint) {
        let cgPoint = CGPoint(x: point.x, y: appKitHeight - point.y)
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: cgPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(130_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(100_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // MARK: - 选区

    static var textArea: AXUIElement?

    static func setSelection(length: Int) -> CGRect? {
        guard let textArea else { return nil }
        var range = CFRange(location: 0, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        let status = AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        guard status == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            textArea, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue as CFTypeRef, &value) == .success,
            let value
        else { return nil }
        var axRect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &axRect) else { return nil }
        return CGRect(x: axRect.minX, y: appKitHeight - axRect.maxY, width: axRect.width, height: axRect.height)
    }

    static func lastDirectionFromLog() -> String? {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n").reversed() where line.contains("translate start") {
            guard let range = line.range(of: "direction=") else { continue }
            let rest = line[range.upperBound...]
            return String(rest.prefix(while: { $0.isLetter }))
        }
        return nil
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    static func translatedCharsFromLog() -> Int? {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n").reversed() where line.contains("translate shown") {
            guard let range = line.range(of: "chars=") else { continue }
            let digits = line[range.upperBound...].prefix(while: { $0.isNumber })
            return Int(digits)
        }
        return nil
    }

    // MARK: - 主流程

    static func run() -> Int32 {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("用法：e2e <App 可执行文件路径>")
            return 2
        }
        let appBinary = arguments[1]
        try? FileManager.default.createDirectory(atPath: workdir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: logPath)
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print(condition ? "  ✅ \(message)" : "  ❌ \(message)")
            if !condition { failures += 1 }
        }

        // 1. TextEdit 打开样本
        let sample = String(repeating: "选中任意文字就能翻译，这个工具会自动判断是英译中还是中译英。", count: 3)
        let file = (workdir as NSString).appendingPathComponent("sample.txt")
        do { try sample.write(toFile: file, atomically: true, encoding: .utf8) } catch {
            print("FAIL 写样本：\(error)")
            return 1
        }
        // TextEdit 会恢复上次打开的窗口（带着旧选区），先全部关掉，避免旧选区干扰断言。
        let closer = Process()
        closer.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        closer.arguments = ["-e", "tell application \"TextEdit\" to close every document without saving"]
        try? closer.run()
        closer.waitUntilExit()
        usleep(500_000)

        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-n", "-a", "TextEdit", file]
        try? opener.run()
        opener.waitUntilExit()
        sleep(2)

        guard let front = NSWorkspace.shared.frontmostApplication else {
            print("FAIL 无前台 App")
            return 1
        }
        front.activate(options: [.activateIgnoringOtherApps])
        usleep(600_000)
        print("frontmost=\(front.localizedName ?? "?") (\(front.bundleIdentifier ?? "?"))")
        check(front.bundleIdentifier == "com.apple.TextEdit", "前台是 TextEdit")

        let targetApp = AXUIElementCreateApplication(front.processIdentifier)
        guard let window = axElement(targetApp, kAXFocusedWindowAttribute),
              let area = find(window, role: "AXTextArea") else {
            print("FAIL 找不到文本区域")
            return 1
        }
        textArea = area

        // 2. 启动被测 App
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: appBinary)
        watcher.arguments = ["--log", logPath]
        do { try watcher.run() } catch {
            print("FAIL 启动被测 App：\(error)")
            return 1
        }
        let pid = watcher.processIdentifier
        print("被测试 App pid=\(pid)")
        sleep(2)

        // 3. 选区 → 按钮
        guard let rect = setSelection(length: 60) else {
            print("FAIL 设置选区")
            return 1
        }
        print("选区=\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))")
        guard let buttonPanel = waitForPanel(ofPID: pid, timeout: 5, matching: {
            $0.width < 120 && $0.height < 90 && abs($0.midX - rect.midX) < 40
        }) else {
            print("FAIL 按钮浮层没有出现在这次选区下方")
            watcher.terminate()
            return 1
        }
        print("按钮浮层=\(Int(buttonPanel.minX)),\(Int(buttonPanel.minY)) \(Int(buttonPanel.width))×\(Int(buttonPanel.height))")
        check(abs(buttonPanel.midX - rect.midX) < 40, "按钮水平居中于选区")
        check(buttonPanel.maxY <= rect.minY + 2 && buttonPanel.maxY >= rect.minY - 14, "按钮紧贴选区下方")
        capture("1-button.png", appKitCenter: CGPoint(x: rect.midX, y: rect.midY))

        // 4. 点按钮 → 结果卡片
        click(appKit: CGPoint(x: buttonPanel.midX, y: buttonPanel.midY))
        guard let card = waitForPanel(ofPID: pid, timeout: 12, matching: { $0.width > 300 }) else {
            print("FAIL 结果卡片没有出现")
            watcher.terminate()
            return 1
        }
        print("结果卡片=\(Int(card.minX)),\(Int(card.minY)) \(Int(card.width))×\(Int(card.height))")
        check(card.width >= 400, "卡片宽度约 420（含阴影）")
        var resultChars: Int?
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, resultChars == nil {
            resultChars = translatedCharsFromLog()
            usleep(200_000)
        }
        check(resultChars != nil, "日志里有翻译结果（\(resultChars ?? -1) 字）")
        var direction: String?
        let directionDeadline = Date().addingTimeInterval(6)
        while Date() < directionDeadline, direction == nil {
            direction = lastDirectionFromLog()
            usleep(200_000)
        }
        print("检测到的方向=\(direction ?? "nil")")
        check(direction == "zhToEn", "中文选区被识别为中译英")
        capture("2-result.png", appKitCenter: CGPoint(x: card.midX, y: card.midY))

        // 5. 点卡片右上「✕」关闭
        let closePoint = CGPoint(x: card.maxX - 12 - 16 - 13, y: card.maxY - 12 - 23)
        click(appKit: closePoint)
        usleep(900_000)
        check(panels(ofPID: pid).allSatisfy { $0.width < 300 }, "点「✕」后结果卡片关闭")
        capture("3-closed-by-x.png", appKitCenter: CGPoint(x: card.midX, y: card.midY))

        // 6. 换选区 → 再翻译 → 点「复制」
        guard let rect2 = setSelection(length: 80) else {
            print("FAIL 第二次设置选区")
            watcher.terminate()
            return 1
        }
        guard let button2 = waitForPanel(ofPID: pid, timeout: 5, matching: {
            $0.width < 120 && $0.height < 90 && abs($0.midX - rect2.midX) < 40
        }) else {
            print("FAIL 第二次按钮没有出现")
            watcher.terminate()
            return 1
        }
        click(appKit: CGPoint(x: button2.midX, y: button2.midY))
        guard let card2 = waitForPanel(ofPID: pid, timeout: 12, matching: { $0.width > 300 }) else {
            for panel in panels(ofPID: pid) {
                print("  面板=\(Int(panel.minX)),\(Int(panel.minY)) \(Int(panel.width))×\(Int(panel.height))")
            }
            print("FAIL 第二次结果卡片没有出现")
            watcher.terminate()
            return 1
        }
        // 预览一下第二次的卡片
        capture("4-result-2.png", appKitCenter: CGPoint(x: card2.midX, y: card2.midY))

        let copyPoint = CGPoint(x: card2.maxX - 12 - 16 - 29, y: card2.minY + 12 + 23)
        NSPasteboard.general.clearContents()
        click(appKit: copyPoint)
        usleep(600_000)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        let expected = translatedCharsFromLog() ?? -1
        print("剪贴板=\(copied.count) 字符，日志结果=\(expected) 字符")
        check(!copied.isEmpty && copied.count == expected, "「复制」把译文写进剪贴板")
        check(!copied.isEmpty && !containsCJK(copied), "复制到的是英文译文（不含中文）")
        capture("5-copied.png", appKitCenter: CGPoint(x: card2.midX, y: card2.midY))

        // 7. 点别处关闭
        click(appKit: CGPoint(x: rect2.midX, y: rect2.minY + 300))
        usleep(900_000)
        check(panels(ofPID: pid).allSatisfy { $0.width < 300 }, "点别处后结果卡片关闭")
        capture("6-closed-by-outside.png", appKitCenter: CGPoint(x: card2.midX, y: card2.midY))

        watcher.terminate()
        print(failures == 0 ? "== 全部通过 ==" : "== 有 \(failures) 项失败 ==")
        return failures == 0 ? 0 : 1
    }
}

exit(E2E.run())
