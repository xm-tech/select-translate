import AppKit
import ApplicationServices

// VS Code（Electron）端到端验证：
// 验证「AX 拿不到选区 → 鼠标松开后模拟 ⌘C 探测」这条兜底链路。
//   1. 启动被测 App
//   2. VS Code 打开本地英文样本
//   3. 在编辑器正文里按住拖动选中一段 → 松开
//   4. 断言「译」按钮出现在松开位置附近（日志里应出现 clipboard fallback copied chars=）
//   5. 点按钮 → 结果卡片、译文
//   6. 点别处 → 浮层关闭

enum VSCodeE2E {
    static let workdir = FileManager.default.currentDirectoryPath + "/.tmp/e2e-vscode-out"
    static var appKitHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static var logPath: String { (workdir as NSString).appendingPathComponent("app.log") }

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
        if self.role(element) == wanted { return element }
        guard depth < 15 else { return nil }
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

    static func capture(_ name: String, appKitCenter: CGPoint, size: NSSize = NSSize(width: 1100, height: 800)) {
        let path = (workdir as NSString).appendingPathComponent(name)
        let cgCenter = CGPoint(x: appKitCenter.x, y: appKitHeight - appKitCenter.y)
        let originX = Int(cgCenter.x - size.width / 2)
        let originY = Int(cgCenter.y - size.height / 2)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(originX),\(originY),\(Int(size.width)),\(Int(size.height))", path]
        try? process.run()
        process.waitUntilExit()
    }

    static func cgPoint(_ appKit: CGPoint) -> CGPoint {
        CGPoint(x: appKit.x, y: appKitHeight - appKit.y)
    }

    static func click(appKit point: CGPoint) {
        let cg = cgPoint(point)
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(120_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: cg, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(90_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: cg, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// 按住从 from 拖到 to，模拟人类拖选文字。
    static func drag(from: CGPoint, to: CGPoint, steps: Int = 24) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let start = cgPoint(from)
        let end = cgPoint(to)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(150_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(120_000)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(12_000)
        }
        usleep(80_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func dumpPanels(ofPID pid: pid_t) {
        print("  当前该 App 的 AX 窗口：")
        for panel in panels(ofPID: pid) {
            print("    \(Int(panel.minX)),\(Int(panel.minY)) \(Int(panel.width))×\(Int(panel.height))")
        }
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

    static func run() -> Int32 {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("用法：e2e-chrome <App 可执行文件路径>")
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

        // 1. 启动被测 App
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

        // 2. 打开本地文件
        let sample = """
        Selecting text anywhere on a Mac should be enough to get a translation.
        This sentence is intentionally long so that dragging across it produces a
        comfortable selection target for the floating translate button.
        """
        let page = (workdir as NSString).appendingPathComponent("sample.txt")
        do { try sample.write(toFile: page, atomically: true, encoding: .utf8) } catch {
            print("FAIL 写样本：\(error)")
            watcher.terminate()
            return 1
        }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Visual Studio Code", page]
        try? opener.run()
        opener.waitUntilExit()
        sleep(3)

        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode").first else {
            print("FAIL 找不到 VS Code")
            watcher.terminate()
            return 1
        }
        chrome.activate(options: [.activateIgnoringOtherApps])
        usleep(900_000)
        check(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.VSCode", "前台是 VS Code")

        let chromeApp = AXUIElementCreateApplication(chrome.processIdentifier)
        guard let window = axElement(chromeApp, kAXFocusedWindowAttribute), var windowFrame = frame(of: window) else {
            print("FAIL 读不到 VS Code 窗口")
            watcher.terminate()
            return 1
        }
        print("VS Code 窗口=\(Int(windowFrame.minX)),\(Int(windowFrame.minY)) \(Int(windowFrame.width))×\(Int(windowFrame.height))")

        // 编辑器区域：跳过左侧活动栏/资源管理器，从窗口左上角内缩估算。
        windowFrame.origin.x += 320
        windowFrame.size.width -= 340
        windowFrame.origin.y += 60
        windowFrame.size.height -= 100
        print("编辑器估算区=\(Int(windowFrame.minX)),\(Int(windowFrame.minY)) \(Int(windowFrame.width))×\(Int(windowFrame.height))")

        // 3. 拖选正文第一行文字
        let start = CGPoint(x: windowFrame.minX + 120, y: windowFrame.maxY - 40)
        let end = CGPoint(x: windowFrame.minX + 720, y: windowFrame.maxY - 40)
        drag(from: start, to: end)
        print("拖选 \(Int(start.x)),\(Int(start.y)) → \(Int(end.x)),\(Int(end.y))")
        usleep(300_000)
        capture("0-selection.png", appKitCenter: CGPoint(x: (start.x + end.x) / 2, y: start.y))

        // 4. 按钮应该出现在松开位置附近
        guard let buttonPanel = waitForPanel(ofPID: pid, timeout: 6, matching: { $0.width < 120 && $0.height < 90 }) else {
            print("FAIL 按钮浮层没有出现（⌘C 兜底没读到选区）")
            dumpPanels(ofPID: pid)
            if let content = try? String(contentsOfFile: logPath, encoding: .utf8) {
                print("--- app.log ---\n\(content.suffix(1200))")
            }
            watcher.terminate()
            return 1
        }
        print("按钮浮层=\(Int(buttonPanel.minX)),\(Int(buttonPanel.minY)) \(Int(buttonPanel.width))×\(Int(buttonPanel.height))")
        check(abs(buttonPanel.midX - end.x) < 80, "按钮在松开位置水平附近（拖动终点 x=\(Int(end.x))）")
        check(buttonPanel.maxY <= end.y + 4, "按钮在松开位置下方")
        capture("1-button.png", appKitCenter: CGPoint(x: buttonPanel.midX, y: buttonPanel.midY))

        // 5. 点按钮 → 结果卡片
        click(appKit: CGPoint(x: buttonPanel.midX, y: buttonPanel.midY))
        guard let card = waitForPanel(ofPID: pid, timeout: 12, matching: { $0.width > 300 }) else {
            print("FAIL 结果卡片没有出现")
            watcher.terminate()
            return 1
        }
        print("结果卡片=\(Int(card.minX)),\(Int(card.minY)) \(Int(card.width))×\(Int(card.height))")
        var resultChars: Int?
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, resultChars == nil {
            resultChars = translatedCharsFromLog()
            usleep(200_000)
        }
        check((resultChars ?? 0) > 0, "日志里有译文（\(resultChars ?? -1) 字）")
        capture("2-result.png", appKitCenter: CGPoint(x: card.midX, y: card.midY))

        // 6. 点别处关闭
        click(appKit: CGPoint(x: card.minX - 120, y: card.minY - 160))
        usleep(900_000)
        check(panels(ofPID: pid).isEmpty, "点别处后浮层全部关闭")
        capture("3-closed.png", appKitCenter: CGPoint(x: card.midX, y: card.midY))

        watcher.terminate()
        print(failures == 0 ? "== VS Code 全部通过 ==" : "== VS Code 有 \(failures) 项失败 ==")
        return failures == 0 ? 0 : 1
    }
}

exit(VSCodeE2E.run())
