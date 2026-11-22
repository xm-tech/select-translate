import AppKit
import SwiftUI
import Translation

@available(macOS 26.0, *)
@MainActor
final class M: ObservableObject {
    @Published var cfg: TranslationSession.Configuration?
    @Published var status = "点击按钮开始"
    func go() {
        status = "请求下载…"
        cfg = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        )
    }
    func run(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            status = "prepareTranslation 返回成功"
        } catch {
            status = "失败：\(error)"
        }
    }
}

@available(macOS 26.0, *)
struct V: View {
    @ObservedObject var m: M
    var body: some View {
        VStack(spacing: 10) {
            Text(m.status).font(.system(size: 13))
            Button("请求下载中文语言包") { m.go() }
        }
        .frame(width: 320, height: 110)
        .task { }
        .translationTask(m.cfg) { s in await m.run(s) }
    }
}

if #available(macOS 26.0, *) {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 110),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Translation Probe"
        window.center()
        window.contentView = NSHostingView(rootView: V(m: M()))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
} else {
    print("macOS 26+ required")
}
