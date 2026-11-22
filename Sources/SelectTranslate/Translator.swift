import Foundation

struct TranslationResult {
    let translated: String
    let provider: String
    /// 实际使用的方向（`.auto` 会在翻译前解析成具体方向）。
    let direction: TranslationDirection
}

enum TranslationError: LocalizedError {
    case emptyInput
    case allProvidersFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "没有可翻译的文本"
        case .allProvidersFailed(let detail):
            return "翻译失败：\(detail)"
        }
    }
}

struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 英 → 中翻译。默认自动串联多个免费服务，单点不可用时会自动降级。
final class Translator {
    static let shared = Translator()

    private let session: URLSession
    private var cache: [String: TranslationResult] = [:]
    private let cacheLock = NSLock()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
        session = URLSession(configuration: config)
    }

    func translate(_ raw: String,
                   preferred: ProviderChoice,
                   direction requested: TranslationDirection = .auto) async throws -> TranslationResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslationError.emptyInput }
        let direction: TranslationDirection = requested == .auto ? TranslationDirection.detect(text) : requested
        let cacheKey = "\(preferred.rawValue)|\(direction.rawValue)|\(text)"
        if let hit = cached(for: cacheKey) { return hit }

        let order: [ProviderKind]
        switch preferred {
        case .auto:
            var chain: [ProviderKind] = []
#if !NO_APPLE_TRANSLATION
            if #available(macOS 26.0, *), await AppleTranslator.isInstalled(for: direction) {
                chain.append(.apple)
            }
#endif
            chain.append(contentsOf: [.tencent, .mymemory, .google])
            order = chain
        case .apple: order = [.apple]
        case .tencent: order = [.tencent]
        case .mymemory: order = [.mymemory]
        case .google: order = [.google]
        }

        var failures: [String] = []
        for kind in order {
            do {
                let output = try await kind.translate(text, session: session, direction: direction)
                let result = TranslationResult(translated: output, provider: kind.displayName, direction: direction)
                store(result, for: cacheKey)
                Log.info("translate ok provider=\(kind.displayName) direction=\(direction.rawValue) chars=\(text.count)")
                return result
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(kind.displayName)：\(message)")
                Log.info("translate failed provider=\(kind.displayName) error=\(message)")
            }
        }
        throw TranslationError.allProvidersFailed(failures.joined(separator: "；"))
    }

    private func cached(for text: String) -> TranslationResult? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[text]
    }

    private func store(_ result: TranslationResult, for text: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache.count > 80 { cache.removeAll() }
        cache[text] = result
    }
}

// MARK: - Providers

enum ProviderKind {
    case apple
    case tencent
    case mymemory
    case google

    var displayName: String {
        switch self {
        case .apple: return "Apple 本地翻译"
        case .tencent: return "腾讯翻译"
        case .mymemory: return "MyMemory"
        case .google: return "Google"
        }
    }

    func translate(_ text: String, session: URLSession, direction: TranslationDirection) async throws -> String {
        switch self {
        case .apple:
#if NO_APPLE_TRANSLATION
            throw ProviderError(message: "当前构建未包含 Apple 本地翻译（编译时 SDK 低于 macOS 26）")
#else
            if #available(macOS 26.0, *) {
                return try await AppleTranslator.translate(text, direction: direction)
            }
            throw ProviderError(message: "需要 macOS 26 及以上系统")
#endif
        case .tencent:
            return try await translateInChunks(text, limit: 1800) { chunk in
                try await Self.tencent(chunk, session: session, direction: direction)
            }
        case .mymemory:
            return try await translateInChunks(text, limit: 420) { chunk in
                try await Self.myMemory(chunk, session: session, direction: direction)
            }
        case .google:
            return try await translateInChunks(text, limit: 1500) { chunk in
                try await Self.google(chunk, session: session, direction: direction)
            }
        }
    }

    private func translateInChunks(_ text: String,
                                   limit: Int,
                                   _ work: (String) async throws -> String) async throws -> String {
        let chunks = TextChunker.chunks(text, limit: limit)
        guard chunks.count > 1 else { return try await work(text) }
        var parts: [String] = []
        parts.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            parts.append(try await work(chunk))
        }
        let joiner = text.contains("\n") ? "\n" : ""
        return parts.joined(separator: joiner)
    }

    // 腾讯翻译（transmart）免费 Web 接口，国内直连可用。
    private static func tencent(_ text: String, session: URLSession, direction: TranslationDirection) async throws -> String {
        guard let url = URL(string: "https://transmart.qq.com/api/imt") else {
            throw ProviderError(message: "无效地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://transmart.qq.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://transmart.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "header": [
                "fn": "auto_translation",
                "client_key": "browser-chrome-110.0.0-Mac OS"
            ],
            "type": "plain",
            "model_category": "normal",
            "source": ["lang": direction.sourceLanguageCode, "text_list": [text]],
            "target": ["lang": direction.targetLanguageCode]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError(message: "返回内容无法解析")
        }
        if let header = json["header"] as? [String: Any],
           let code = header["ret_code"] as? String,
           code != "succ" {
            throw ProviderError(message: "接口返回 \(code)")
        }
        guard let list = json["auto_translation"] as? [String],
              let first = list.first,
              !first.isEmpty else {
            throw ProviderError(message: "返回为空")
        }
        return first
    }

    // MyMemory 免费接口，作为备用。
    private static func myMemory(_ text: String, session: URLSession, direction: TranslationDirection) async throws -> String {
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: direction.myMemoryPair)
        ]
        guard let url = components.url else { throw ProviderError(message: "无效地址") }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError(message: "返回内容无法解析")
        }
        guard let payload = json["responseData"] as? [String: Any],
              let translated = payload["translatedText"] as? String else {
            throw ProviderError(message: "返回为空")
        }
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper.contains("MYMEMORY WARNING") || upper.contains("QUERY LENGTH LIMIT") || upper.contains("NO QUERY SPECIFIED") {
            throw ProviderError(message: "免费额度受限")
        }
        if trimmed.isEmpty { throw ProviderError(message: "返回为空") }
        return trimmed.decodingHTMLEntities
    }

    // Google 免费接口（国内通常不可达，留作可选项）。
    private static func google(_ text: String, session: URLSession, direction: TranslationDirection) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: direction.sourceLanguageCode),
            URLQueryItem(name: "tl", value: direction.targetLanguageCode),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components.url else { throw ProviderError(message: "无效地址") }
        let (data, response) = try await session.data(from: url)
        try validate(response)
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = array.first as? [Any] else {
            throw ProviderError(message: "返回内容无法解析")
        }
        var output = ""
        for segment in segments {
            if let pair = segment as? [Any], let piece = pair.first as? String {
                output += piece
            }
        }
        guard !output.isEmpty else { throw ProviderError(message: "返回为空") }
        return output
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError(message: "网络无响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError(message: "HTTP \(http.statusCode)")
        }
    }
}

// MARK: - Text helpers

enum TextChunker {
    /// 按句子边界切块，避免把一个词切断。
    static func chunks(_ text: String, limit: Int) -> [String] {
        guard limit > 20, text.count > limit else { return [text] }

        var units: [String] = []
        var buffer = ""
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n", "；", ";"]
        for character in text {
            buffer.append(character)
            if terminators.contains(character) {
                units.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { units.append(buffer) }

        var output: [String] = []
        var current = ""
        for unit in units {
            if !current.isEmpty && current.count + unit.count > limit {
                output.append(current)
                current = ""
            }
            if unit.count > limit {
                var rest = unit
                while rest.count > limit {
                    let index = rest.index(rest.startIndex, offsetBy: limit)
                    output.append(String(rest[..<index]))
                    rest = String(rest[index...])
                }
                current += rest
            } else {
                current += unit
            }
        }
        if !current.isEmpty { output.append(current) }
        return output.isEmpty ? [text] : output
    }
}

extension String {
    var decodingHTMLEntities: String {
        var result = self
        let replacements: [(String, String)] = [
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")
        ]
        for (needle, replacement) in replacements {
            result = result.replacingOccurrences(of: needle, with: replacement)
        }
        return result
    }
}
