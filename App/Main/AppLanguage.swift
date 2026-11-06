import Foundation

/// The languages MacHelper ships, and how an AppleLanguages entry maps onto them.
enum AppLanguage {
    /// Codes as used by the String Catalogs, with each language's own name.
    static let all: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hant", "繁體中文"),
        ("zh-Hans", "简体中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("es", "Español"),
    ]

    static var codes: [String] { all.map(\.code) }

    /// "zh-Hant-TW", "zh-TW", "zh-HK" → zh-Hant; "zh-Hans-CN", "zh-CN", "zh-SG" → zh-Hans;
    /// "ja-JP" → ja. Nil for a language MacHelper doesn't ship.
    static func match(_ identifier: String) -> String? {
        let id = identifier.replacingOccurrences(of: "_", with: "-")
        if id == "zh" || id.hasPrefix("zh-") {
            if id.contains("Hans") || ["zh-CN", "zh-SG"].contains(where: id.hasPrefix) { return "zh-Hans" }
            return "zh-Hant"
        }
        let base = String(id.split(separator: "-").first ?? "")
        return codes.contains(base) ? base : nil
    }
}
