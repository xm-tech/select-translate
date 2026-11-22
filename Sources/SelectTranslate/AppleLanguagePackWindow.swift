import AppKit
import SwiftUI
import Translation

/// 一个只干一件事的小窗口：检查 / 下载 Apple 本地翻译的英中语言包（两个方向）。
@available(macOS 26.0, *)
final class AppleLanguagePackWindow: NSWindow {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 292),
                  styleMask: [.titled, .closable],
                  backing: .buffered,
                  defer: false)
        title = "Apple 本地翻译"
        isReleasedWhenClosed = false
        center()
        contentView = NSHostingView(rootView: AppleLanguagePackView(model: AppleLanguagePackModel()))
        Log.info("apple language pack window opened")
    }
}

/// 没有 @State 可用（本机 Command Line Tools 没带 SwiftUI 宏插件），
/// 所以用 ObservableObject 承载全部可观察状态。
@available(macOS 26.0, *)
@MainActor
final class AppleLanguagePackModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published var busy = false
    @Published var enToZhText = "英 → 中：检查中…"
    @Published var zhToEnText = "中 → 英：检查中…"
    @Published var enToZhInstalled = false
    @Published var zhToEnInstalled = false
    @Published var message = ""

    var allInstalled: Bool { enToZhInstalled && zhToEnInstalled }

    /// .translationTask 在视图出现时会先以「空配置」调用一次，这里用来区分
    /// 「系统自动回调」和「用户真的点了下载」。
    private var downloadRequested = false
    private var pending: [TranslationDirection] = []

    func refresh(force: Bool) async {
        enToZhInstalled = await AppleTranslator.isInstalled(for: .enToZh)
        zhToEnInstalled = await AppleTranslator.isInstalled(for: .zhToEn)
        enToZhText = "英 → 中：\(enToZhInstalled ? "已下载，离线可用" : "尚未下载")"
        zhToEnText = "中 → 英：\(zhToEnInstalled ? "已下载，离线可用" : "尚未下载")"
        if force { busy = false }
    }

    func startDownload() {
        // prepareTranslation 会在本窗口上弹系统下载确认，前提是 App 处于前台。
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Apple 本地翻译" }?.makeKeyAndOrderFront(nil)
        downloadRequested = true
        busy = true
        message = "等待系统确认下载…"

        var queue: [TranslationDirection] = []
        if !enToZhInstalled { queue.append(.enToZh) }
        if !zhToEnInstalled { queue.append(.zhToEn) }
        pending = queue
        startNext()
    }

    private func startNext() {
        guard let next = pending.first else {
            busy = false
            message = allInstalled ? "语言包已就绪" : ""
            return
        }
        let (source, target): (Locale.Language, Locale.Language) = next == .zhToEn
            ? (AppleTranslator.simplifiedChinese, AppleTranslator.english)
            : (AppleTranslator.english, AppleTranslator.simplifiedChinese)
        configuration = TranslationSession.Configuration(source: source, target: target)
    }

    func prepare(_ session: TranslationSession) async {
        guard downloadRequested, let next = pending.first else { return }
        Log.info("apple language pack prepare started direction=\(next.rawValue)")
        do {
            try await session.prepareTranslation()
        } catch {
            message = "下载未完成：\(error.localizedDescription)"
            busy = false
            pending.removeAll()
            Log.info("apple language pack prepare failed: \(error)")
            return
        }
        // prepareTranslation 只是「发起」，真正的下载在系统侧异步进行，
        // 所以这里轮询语言包状态，直到 installed 或超时。
        AppleTranslator.invalidateStatusCache()
        for _ in 0..<1800 {
            if await AppleTranslator.isInstalled(for: next) {
                pending.removeFirst()
                await refresh(force: true)
                if pending.isEmpty {
                    message = "语言包已就绪"
                    busy = false
                    Log.info("apple language pack ready")
                    return
                }
                message = "继续下载另一个方向…"
                startNext()
                return
            }
            message = "系统正在下载语言包…（也可以关掉本窗口，稍后再打开查看）"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { break }
        }
        busy = false
        message = "还没下载完，稍后再打开这个窗口看看"
    }
}

@available(macOS 26.0, *)
struct AppleLanguagePackView: View {
    @ObservedObject var model: AppleLanguagePackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("英文 ⇄ 简体中文，全部在本机完成")
                .font(.system(size: 15, weight: .semibold))

            Text("不联网、不需要账号，速度通常比在线服务快一个数量级。首次使用需要下载系统语言包（每个方向约 100–300 MB），由 macOS 负责下载与校验。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                statusRow(text: model.enToZhText, installed: model.enToZhInstalled)
                statusRow(text: model.zhToEnText, installed: model.zhToEnInstalled)
            }

            HStack(spacing: 10) {
                Button(model.busy ? "正在准备…" : (model.allInstalled ? "重新检查" : "下载语言包")) {
                    if model.allInstalled {
                        Task { await model.refresh(force: true) }
                    } else {
                        model.startDownload()
                    }
                }
                .disabled(model.busy)

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            Text("下载完成后，菜单栏「翻译服务 → 自动（推荐）」会在两个方向上都优先使用 Apple 本地翻译。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .task { await model.refresh(force: true) }
        .translationTask(model.configuration) { session in
            await model.prepare(session)
        }
    }

    @ViewBuilder
    private func statusRow(text: String, installed: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(installed ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(installed ? Color.green : Color.secondary)
            Spacer()
        }
    }
}
