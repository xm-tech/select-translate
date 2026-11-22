import Foundation
import Translation

/// macOS 内置的本地翻译（离线、免费、无需账号）。
/// 会话对象只能在 macOS 26 及以上直接创建，更早的系统请在菜单里看提示。
@available(macOS 26.0, *)
@MainActor
enum AppleTranslator {
    static let english = Locale.Language(identifier: "en")
    static let simplifiedChinese = Locale.Language(identifier: "zh-Hans")

    private static var statusCache: [TranslationDirection: (status: LanguageAvailability.Status, at: Date)] = [:]
    private static let cacheLifetime: TimeInterval = 3

    private static func languages(for direction: TranslationDirection) -> (Locale.Language, Locale.Language) {
        switch direction {
        case .zhToEn: return (simplifiedChinese, english)
        default: return (english, simplifiedChinese)
        }
    }

    /// 指定方向的语言包状态：.installed 已下载 / .supported 可下载 / .unsupported 不支持。
    static func status(for direction: TranslationDirection,
                       forceRefresh: Bool = false) async -> LanguageAvailability.Status {
        let resolved: TranslationDirection = direction == .zhToEn ? .zhToEn : .enToZh
        if !forceRefresh,
           let cached = statusCache[resolved],
           Date().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.status
        }
        let (source, target) = languages(for: resolved)
        let status = await LanguageAvailability().status(from: source, to: target)
        statusCache[resolved] = (status, Date())
        return status
    }

    static func isInstalled(for direction: TranslationDirection = .enToZh) async -> Bool {
        await status(for: direction) == .installed
    }

    static func invalidateStatusCache() {
        statusCache.removeAll()
    }

    static func statusDescription(for direction: TranslationDirection) async -> String {
        let resolved: TranslationDirection = direction == .zhToEn ? .zhToEn : .enToZh
        switch await status(for: resolved, forceRefresh: true) {
        case .installed: return "已下载（离线可用）"
        case .supported: return "未下载（可下载）"
        case .unsupported: return "当前系统不支持\(resolved.badge)"
        @unknown default: return "状态未知"
        }
    }

    /// 两个方向都可用时为 true —— 「自动」链路用它决定是否优先走本地。
    static func isReadyForAuto() async -> Bool {
        let enToZhReady = await isInstalled(for: .enToZh)
        guard enToZhReady else { return false }
        return await isInstalled(for: .zhToEn)
    }

    static func translate(_ text: String, direction: TranslationDirection) async throws -> String {
        let resolved: TranslationDirection = direction == .zhToEn ? .zhToEn : .enToZh
        guard await status(for: resolved) == .installed else {
            throw ProviderError(message: "\(resolved.badge) 的语言包未下载（菜单栏 → 翻译服务 → 下载 Apple 本地语言包…）")
        }
        let (source, target) = languages(for: resolved)
        let session = TranslationSession(installedSource: source, target: target)
        let chunks = TextChunker.chunks(text, limit: 1200)
        var parts: [String] = []
        parts.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            let response = try await session.translate(chunk)
            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else {
                throw ProviderError(message: "返回为空")
            }
            parts.append(translated)
        }
        let joiner = text.contains("\n") ? "\n" : ""
        return parts.joined(separator: joiner)
    }
}
