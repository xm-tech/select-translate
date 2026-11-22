import AppKit
import ApplicationServices

// 验证 Chrome / Electron 这类 Chromium App 的 AX 选区读取：
// 激活 Chrome → 合成 ⌘A 选中页面文字 → 按 SelectionService 相同路径读选区。

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axValue(element, attribute) else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

func selectedText(app pid: pid_t) -> (String, CGRect?)? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var element = axElement(app, kAXFocusedUIElementAttribute)
        ?? axElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    var depth = 0
    while let current = element, depth < 4 {
        if let text = axValue(current, kAXSelectedTextAttribute) as? String, !text.isEmpty {
            var rect: CGRect?
            if let rangeValue = axValue(current, kAXSelectedTextRangeAttribute) {
                var value: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    current,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    rangeValue as CFTypeRef,
                    &value) == .success, let value {
                    var r = CGRect.zero
                    if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &r) { rect = r }
                }
            }
            return (text, rect)
        }
        element = axElement(current, kAXParentAttribute)
        depth += 1
    }
    return nil
}

guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else {
    print("Chrome 没在运行")
    exit(1)
}
chrome.activate(options: [.activateIgnoringOtherApps])
usleep(900_000)
print("frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

func key(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(60_000)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

// 先点一下页面确保焦点在网页内容上（Chrome 窗口中心附近）
if let window = axElement(AXUIElementCreateApplication(chrome.processIdentifier), kAXFocusedWindowAttribute),
   let positionValue = axValue(window, kAXPositionAttribute),
   let sizeValue = axValue(window, kAXSizeAttribute) {
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point)
    AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    let clickPoint = CGPoint(x: point.x + size.width / 2,
                             y: screenHeight - (point.y + size.height / 2) - 40)
    let source = CGEventSource(stateID: .combinedSessionState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: clickPoint, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(90_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(400_000)
}

key(0, flags: .maskCommand)   // ⌘A
usleep(800_000)

if let (text, rect) = selectedText(app: chrome.processIdentifier) {
    print("Chrome 选区=\(text.count) 字符")
    print("片段=\(text.prefix(80).replacingOccurrences(of: "\n", with: " "))")
    if let rect { print("坐标(AX)=\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))") }
    exit(0)
} else {
    print("Chrome 读不到选区")
    exit(1)
}
