import SwiftUI

enum KmaTheme {
    static let background = Color(hex: 0xF6F5F0)
    static let surface = Color.white
    static let text = Color(hex: 0x203B34)
    static let secondary = Color(hex: 0x65736D)
    static let primary = Color(hex: 0x24594D)
    static let primaryLight = Color(hex: 0x84AA99)
    static let border = Color(hex: 0xDDE3DB)
    static let warmPaper = Color(hex: 0xEEEADD)
    static let warmAccent = Color(hex: 0xAE6548)
    static let ink = Color(hex: 0x203B34)
}

enum ReaderThemeID: String, CaseIterable, Identifiable {
    case auto
    case inkPaper = "ink-paper"
    case quietModern = "quiet-modern"
    case warmCompanion = "warm-companion"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动"
        case .inkPaper: return "墨纸"
        case .quietModern: return "现代"
        case .warmCompanion: return "温暖"
        }
    }

    var menuTitle: String {
        switch self {
        case .auto: return "自动（按资料）"
        case .inkPaper: return "墨纸"
        case .quietModern: return "现代"
        case .warmCompanion: return "温暖"
        }
    }

    static let storageKey = "peidu.reader.theme"

    static func stored() -> ReaderThemeID {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let theme = ReaderThemeID(rawValue: raw) else { return .auto }
        return theme
    }
}

enum ReaderTextSize: String, CaseIterable, Identifiable {
    case small
    case standard
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        }
    }

    var body: CGFloat {
        switch self {
        case .small: return 15
        case .standard: return 17
        case .large: return 20
        }
    }

    /// 按书籍正文字号比例缩放工程阅读里的标题和说明。标准字号保持原尺寸。
    func scaled(_ base: CGFloat) -> CGFloat {
        (base * body / 17).rounded()
    }

    static let storageKey = "peidu.reader.textSize"

    static func stored() -> ReaderTextSize {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let size = ReaderTextSize(rawValue: raw) else { return .standard }
        return size
    }
}

struct ReaderTokens {
    let background: Color
    let surface: Color
    let text: Color
    let secondary: Color
    let accent: Color
    let highlight: Color
    let lineSpacing: CGFloat

    static func resolve(_ id: ReaderThemeID, sourceType: String) -> ReaderTokens {
        switch id {
        case .auto:
            return (sourceType.lowercased() == "pdf" || sourceType.lowercased().hasSuffix(".pdf"))
                ? resolve(.quietModern, sourceType: sourceType)
                : resolve(.inkPaper, sourceType: sourceType)
        case .inkPaper:
            return ReaderTokens(
                background: Color(hex: 0xF7F3EA),
                surface: Color(hex: 0xFFFCF7),
                text: Color(hex: 0x2B2822),
                secondary: Color(hex: 0x726D61),
                accent: Color(hex: 0xAE6548),
                highlight: Color(hex: 0xF1E6D6),
                lineSpacing: 4
            )
        case .quietModern:
            return ReaderTokens(
                background: Color(hex: 0xF3F6F3),
                surface: .white,
                text: Color(hex: 0x1C2430),
                secondary: Color(hex: 0x65736D),
                accent: KmaTheme.primary,
                highlight: Color(hex: 0xE5EFE8),
                lineSpacing: 4
            )
        case .warmCompanion:
            return ReaderTokens(
                background: Color(hex: 0xFBF4EE),
                surface: Color(hex: 0xFFF9F4),
                text: Color(hex: 0x3A2E28),
                secondary: Color(hex: 0x80695D),
                accent: Color(hex: 0xAE6548),
                highlight: Color(hex: 0xF6E4D8),
                lineSpacing: 4
            )
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
