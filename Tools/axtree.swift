import AppKit
import ApplicationServices

// 打印指定 App 的 AX 树摘要：role、是否有选区文本/选区 range、以及文本片段。

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axValue(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String {
    (axValue(element, kAXRoleAttribute) as? String) ?? "?"
}

func describe(_ element: AXUIElement, depth: Int) {
    let pad = String(repeating: "  ", count: depth)
    let roleName = role(element)
    let title = (axValue(element, kAXTitleAttribute) as? String)
        ?? (axValue(element, "AXDescription") as? String)
        ?? ""
    var notes: [String] = []
    if let value = axValue(element, kAXSelectedTextRangeAttribute) {
        var range = CFRange(location: 0, length: 0)
        if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) {
            notes.append("range=\(range.location)+\(range.length)")
        }
    }
    if let text = axValue(element, kAXSelectedTextAttribute) as? String {
        notes.append("selText=\(text.count)字")
    }
    if let value = axValue(element, kAXValueAttribute) as? String, !value.isEmpty {
        notes.append("value=\(value.prefix(40).replacingOccurrences(of: "\n", with: " "))")
    }
    print("\(pad)\(roleName) \(title.isEmpty ? "" : "[\(title.prefix(40))]") \(notes.joined(separator: " "))")
    guard depth < 5 else { return }
    for child in axChildren(element).prefix(12) {
        describe(child, depth: depth + 1)
    }
}

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.google.Chrome"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("没在运行：\(bundleID)")
    exit(1)
}
app.activate(options: [.activateIgnoringOtherApps])
usleep(600_000)

let axApp = AXUIElementCreateApplication(app.processIdentifier)
print("AXManualAccessibility=\(AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue)")
print("AXEnhancedUserInterface=\(AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)")
usleep(700_000)

if let window = axValue(axApp, kAXFocusedWindowAttribute) {
    describe(unsafeBitCast(window, to: AXUIElement.self), depth: 0)
} else {
    print("没有 focused window；列窗口：")
    for window in (axValue(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        describe(window, depth: 0)
    }
}
