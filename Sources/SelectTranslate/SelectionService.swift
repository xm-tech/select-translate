import AppKit
import ApplicationServices

struct SelectionInfo {
    let text: String
    /// AppKit 全局坐标（原点在主屏左下角）。
    let rect: CGRect?
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let usedClipboard: Bool
}

/// 通过 macOS 辅助功能（AX）API 读取“全系统当前选区”。
final class SelectionService {
    private var cachedApp: (pid: pid_t, element: AXUIElement)?
    private var lastClipboardAttempt = Date.distantPast

    /// 绝不在这些 App 里尝试“模拟复制”，避免把密码写进剪贴板。
    private static let protectedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "me.proton.pass.electron",
        "com.apple.Passwords"
    ]

    var isTrusted: Bool { AXIsProcessTrusted() }

    func promptForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 读取选区

    func currentSelection(useClipboardFallback: Bool) -> SelectionInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard app.processIdentifier != myPID else { return nil }

        let bundleID = app.bundleIdentifier
        if let bundleID, Self.protectedBundleIDs.contains(bundleID) {
            Log.info("skip protected app \(bundleID)")
            return nil
        }

        guard let focused = focusedElement(for: app) else { return nil }

        var element = focused
        var text: String?
        var rangeValue: CFTypeRef?

        // 焦点元素可能不是真正承载文字的那个，向上找最多 4 层。
        for _ in 0..<4 {
            if isSecureField(element) { return nil }

            let candidate = copyValue(element, kAXSelectedTextAttribute as CFString) as? String
            let range = copyValue(element, kAXSelectedTextRangeAttribute as CFString)

            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = candidate
                rangeValue = range
                break
            }
            if let range, let parsed = cfRange(range), parsed.length > 0 {
                // 有选区但没有文字：交给 ⌘C 兜底。
                rangeValue = range
                break
            }
            guard let parent = copyValue(element, kAXParentAttribute as CFString) else { break }
            element = unsafeBitCast(parent, to: AXUIElement.self)
        }

        if text == nil,
           useClipboardFallback,
           let range = rangeValue,
           let parsed = cfRange(range),
           parsed.length > 0,
           Date().timeIntervalSince(lastClipboardAttempt) > 0.7 {
            lastClipboardAttempt = Date()
            text = copySelectionViaPasteboard()
        }

        guard var selected = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selected.isEmpty else { return nil }

        if selected.count > Settings.maxCharacters {
            selected = String(selected.prefix(Settings.maxCharacters))
        }

        let rect = selectionBounds(element: element, rangeValue: rangeValue)
        let info = SelectionInfo(
            text: selected,
            rect: rect,
            pid: app.processIdentifier,
            appName: app.localizedName ?? "未知应用",
            bundleID: bundleID,
            usedClipboard: useClipboardFallback && text != nil
        )
        return info
    }

    /// 鼠标松开后调用：原生 App 直接读 AX；AX 读不到选区时（浏览器、Electron、终端等）
    /// 退化为模拟一次 ⌘C 探测——没选中内容时 ⌘C 不会改变剪贴板，所以不会误弹。
    /// 此时拿不到选区坐标，rect 交给上层用鼠标位置兜底。
    func currentSelectionAfterMouseUp(useClipboardFallback: Bool) -> SelectionInfo? {
        if let info = currentSelection(useClipboardFallback: false) {
            return info
        }
        guard useClipboardFallback,
              Settings.clipboardFallback,
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        if let bundleID = app.bundleIdentifier, Self.protectedBundleIDs.contains(bundleID) {
            return nil
        }
        guard Date().timeIntervalSince(lastClipboardAttempt) > 0.7 else { return nil }
        lastClipboardAttempt = Date()

        guard let copied = copySelectionViaPasteboard() else { return nil }
        var text = copied
        if text.count > Settings.maxCharacters {
            text = String(text.prefix(Settings.maxCharacters))
        }
        return SelectionInfo(
            text: text,
            rect: nil,
            pid: app.processIdentifier,
            appName: app.localizedName ?? "未知应用",
            bundleID: app.bundleIdentifier,
            usedClipboard: true
        )
    }

    private func focusedElement(for app: NSRunningApplication) -> AXUIElement? {        let appElement = axApplication(pid: app.processIdentifier)

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
           let value = ref,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var systemRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &systemRef) == .success,
           let value = systemRef,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        return nil
    }

    private func axApplication(pid: pid_t) -> AXUIElement {
        if let cached = cachedApp, cached.pid == pid { return cached.element }
        let element = AXUIElementCreateApplication(pid)
        // Chromium / Electron 默认不构建完整 AX 树；这个私有属性可以强制打开。
        _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        cachedApp = (pid, element)
        return element
    }

    private func copyValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func isSecureField(_ element: AXUIElement) -> Bool {
        if let subrole = copyValue(element, kAXSubroleAttribute as CFString) as? String,
           subrole == "AXSecureTextField" {
            return true
        }
        if let role = copyValue(element, kAXRoleAttribute as CFString) as? String,
           role == "AXSecureTextField" {
            return true
        }
        return false
    }

    private func cfRange(_ value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }

    private func selectionBounds(element: AXUIElement, rangeValue: CFTypeRef?) -> CGRect? {
        if let rangeValue {
            var output: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &output
            )
            if error == .success,
               let output,
               CFGetTypeID(output) == AXValueGetTypeID() {
                var axRect = CGRect.zero
                if AXValueGetValue(unsafeBitCast(output, to: AXValue.self), .cgRect, &axRect),
                   axRect.width > 0 || axRect.height > 0 {
                    return Self.axRectToAppKit(axRect)
                }
            }
        }

        // 退路：元素自身的 frame。只对“输入框类”元素可信——网页（AXWebArea）、
        // 文档视图的 frame 往往覆盖整个窗口，会把按钮丢到离选区很远的地方。
        let role = copyValue(element, kAXRoleAttribute as CFString) as? String ?? ""
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        guard textRoles.contains(role) else { return nil }
        guard let positionValue = copyValue(element, kAXPositionAttribute as CFString),
              let sizeValue = copyValue(element, kAXSizeAttribute as CFString) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }
        return Self.axRectToAppKit(CGRect(origin: point, size: size))
    }

    static func axRectToAppKit(_ rect: CGRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return rect }
        let height = main.frame.height
        return CGRect(
            x: rect.origin.x,
            y: height - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    // MARK: - ⌘C 兜底

    /// 暂存剪贴板 → 模拟 ⌘C → 读取文字 → 还原剪贴板。
    private func copySelectionViaPasteboard() -> String? {
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) { data[type] = value }
            }
            return data
        }

        sendCopyKeystroke()

        var copied: String?
        for _ in 0..<25 {
            usleep(20_000)
            if pasteboard.changeCount != changeCountBefore {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        if pasteboard.changeCount != changeCountBefore {
            pasteboard.clearContents()
            if !saved.isEmpty {
                let items = saved.map { entry -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in entry { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(items)
            }
        }

        let result = copied?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let result, !result.isEmpty {
            Log.info("clipboard fallback copied chars=\(result.count)")
            return result
        }
        return nil
    }

    private func sendCopyKeystroke() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyC: CGKeyCode = 0x08
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
    }
}
