import Foundation

enum ProviderChoice: String, CaseIterable {
    case auto
    case apple
    case tencent
    case mymemory
    case google

    var displayName: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .apple: return "Apple 本地翻译（离线）"
        case .tencent: return "腾讯翻译"
        case .mymemory: return "MyMemory"
        case .google: return "Google（需代理）"
        }
    }

    var shortName: String {
        switch self {
        case .auto: return "自动"
        case .apple: return "Apple 本地"
        case .tencent: return "腾讯翻译"
        case .mymemory: return "MyMemory"
        case .google: return "Google"
        }
    }
}

/// 翻译方向。`.auto` 会根据选中的文字自动判断是中译英还是英译中。
enum TranslationDirection: String, CaseIterable {
    case auto
    case enToZh
    case zhToEn

    var displayName: String {
        switch self {
        case .auto: return "自动检测（推荐）"
        case .enToZh: return "英译中"
        case .zhToEn: return "中译英"
        }
    }

    var shortName: String {
        switch self {
        case .auto: return "自动"
        case .enToZh: return "英译中"
        case .zhToEn: return "中译英"
        }
    }

    /// 结果卡片上的方向标记。
    var badge: String {
        switch self {
        case .auto: return ""
        case .enToZh: return "英 → 中"
        case .zhToEn: return "中 → 英"
        }
    }

    var sourceLanguageCode: String {
        self == .zhToEn ? "zh" : "en"
    }

    var targetLanguageCode: String {
        self == .zhToEn ? "en" : "zh"
    }

    var myMemoryPair: String {
        self == .zhToEn ? "zh-CN|en" : "en|zh-CN"
    }

    /// 简单的语言检测：中日韩字符多就当中文，否则当英文。
    /// 中英混排时中文一个字信息量更大，所以按 2:1 加权。
    static func detect(_ text: String) -> TranslationDirection {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3000...0x303F, 0xFF00...0xFFEF:
                cjk += 1
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            default:
                break
            }
        }
        if cjk == 0 { return .enToZh }
        if latin == 0 { return .zhToEn }
        return cjk * 2 >= latin ? .zhToEn : .enToZh
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// AX 读不到文字时，用模拟 ⌘C 的方式兜底（会自动还原剪贴板）。
    static var clipboardFallback: Bool {
        get { defaults.object(forKey: "clipboardFallback") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clipboardFallback") }
    }

    static var provider: ProviderChoice {
        get {
            guard let raw = defaults.string(forKey: "provider") else { return .auto }
            return ProviderChoice(rawValue: raw) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: "provider") }
    }

    static var direction: TranslationDirection {
        get {
            guard let raw = defaults.string(forKey: "direction") else { return .auto }
            return TranslationDirection(rawValue: raw) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: "direction") }
    }

    /// 单次最多翻译多少字符，防止误选整篇文档。
    static let maxCharacters = 5000
}
