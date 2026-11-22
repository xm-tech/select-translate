#!/bin/bash
# 重新给「划词翻译」授予辅助功能权限。
#
# 为什么需要它：App 用 ad-hoc 签名，每次重新构建 cdhash 都会变，
# macOS 会保留「设备控制与数据访问（辅助功能）」列表里的旧条目并继续显示为开启，
# 但实际授权已失效（App 日志出现 launched trusted=false，划词不出按钮）。
# 单纯关掉再打开开关不生效，必须先「移除」旧条目，再让 App 重新申请。
#
# 用法： ./scripts/regrant.sh

set -euo pipefail

APP="$HOME/Applications/SelectTranslate.app"
BIN="$APP/Contents/MacOS/SelectTranslate"
LOG="$HOME/Library/Logs/SelectTranslate.log"
PROBE="$(dirname "$0")/../.tmp/regrant-probe"

if [[ ! -x "$BIN" ]]; then
  echo "找不到 $BIN，请先运行 scripts/install.sh" >&2
  exit 1
fi

mkdir -p "$(dirname "$PROBE")"

# 小工具：定位 / 点击 System Settings 里的开关
cat > "${PROBE}.swift" <<'SWIFT'
import AppKit
import ApplicationServices

let args = CommandLine.arguments
let action = args.count > 1 ? args[1] : "value"
let wantID = args.count > 2 ? args[2] : "SelectTranslate_Toggle"

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
    print("NO_SETTINGS")
    exit(2)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)

func attr(_ el: AXUIElement, _ name: String) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return (v as? String) ?? ""
}

func find(_ el: AXUIElement, _ depth: Int, id: String) -> AXUIElement? {
    if attr(el, kAXIdentifierAttribute) == id { return el }
    guard depth < 14 else { return nil }
    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
    for child in (children as? [AXUIElement]) ?? [] {
        if let hit = find(child, depth + 1, id: id) { return hit }
    }
    return nil
}

func frame(_ el: AXUIElement) -> CGRect {
    var p: CFTypeRef?, s: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p)
    AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s)
    var pt = CGPoint.zero, sz = CGSize.zero
    if let p { AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &pt) }
    if let s { AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &sz) }
    return CGRect(origin: pt, size: sz)
}

func click(_ point: CGPoint) {
    app.activate(options: [.activateIgnoringOtherApps])
    usleep(600_000)
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(180_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(700_000)
}

var windows: CFTypeRef?
AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windows)
let roots = (windows as? [AXUIElement]) ?? []

// 找列表里的「移除」按钮（辅助功能面板底部 +/- 两个小圆钮）
func findButton(_ label: String) -> AXUIElement? {
    for root in roots {
        var stack = [root]
        while let el = stack.popLast() {
            if attr(el, kAXRoleAttribute) == "AXButton", attr(el, kAXDescriptionAttribute) == label {
                return el
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            stack.append(contentsOf: (children as? [AXUIElement]) ?? [])
        }
    }
    return nil
}

switch action {
case "value":
    for root in roots {
        if let toggle = find(root, 0, id: wantID) {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(toggle, kAXValueAttribute as CFString, &v)
            print((v as? NSNumber)?.intValue ?? -1)
            exit(0)
        }
    }
    print("MISSING")

case "toggle":
    for root in roots {
        if let toggle = find(root, 0, id: wantID) {
            let box = frame(toggle)
            click(CGPoint(x: box.midX, y: box.midY))
            print("TOGGLED")
            exit(0)
        }
    }
    print("MISSING")

case "remove":
    // 先点一下那一行把列表选中，再点「移除」
    guard let rowTitle = roots.compactMap({ find($0, 0, id: "\(wantID.replacingOccurrences(of: "_Toggle", with: "_Title"))") }).first else {
        print("MISSING")
        exit(0)
    }
    let box = frame(rowTitle)
    click(CGPoint(x: box.minX + 40, y: box.midY))
    if let removeButton = findButton("移除") {
        let rbox = frame(removeButton)
        click(CGPoint(x: rbox.midX, y: rbox.midY))
        print("REMOVED")
    } else {
        print("NO_REMOVE_BUTTON")
    }

default:
    print("unknown action")
}
SWIFT

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "$(dirname "$0")/../.tmp/modcache" \
  "${PROBE}.swift" -o "$PROBE" || { echo "编译探测工具失败" >&2; exit 1; }

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
sleep 2

# 1) 如果存在旧条目，先移除（旧的 cdhash 授权不会因为开关重开而生效）
STATE=$("$PROBE" value)
if [[ "$STATE" != "MISSING" ]]; then
  echo "发现旧授权条目（state=${STATE}），移除它…"
  "$PROBE" remove
  sleep 1
fi

# 2) 重新启动 App，让它向系统申请权限、重新出现条目
pkill -f "SelectTranslate.app/Contents/MacOS/SelectTranslate" || true
sleep 1
open "$APP"
sleep 3

# 3) 打开开关
for attempt in 1 2 3; do
  if [[ "$("$PROBE" value)" != "MISSING" ]]; then
    "$PROBE" toggle
    sleep 1
    break
  fi
  sleep 2
done

# 4) 校验
pkill -f "SelectTranslate.app/Contents/MacOS/SelectTranslate" || true
sleep 1
open "$APP"
sleep 3

if tail -5 "$LOG" | grep -q "launched trusted=true"; then
  echo "✅ 已重新授权：划词按钮应该恢复了（菜单栏图标 → 试试选中一段文字）"
else
  echo "⚠️ 授权看起来还没生效，请手动检查：系统设置 → 隐私与安全性 → 设备控制与数据访问 → 划词翻译"
  exit 1
fi
