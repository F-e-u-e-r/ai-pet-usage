import SwiftUI
import AppKit

// MARK: - Font preferences (settings.json, GUI-only)

enum FontDesignPreference: String, Codable, CaseIterable, Sendable {
    case system, rounded, serif, monospaced

    var displayName: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .monospaced: return "Monospaced"
        }
    }

    var swiftUIDesign: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }

    static func decodeTolerant<K: CodingKey>(from container: KeyedDecodingContainer<K>,
                                             forKey key: K) -> FontDesignPreference {
        let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        return raw.flatMap(FontDesignPreference.init(rawValue:)) ?? .system
    }
}

enum FontSizePreference: String, Codable, CaseIterable, Sendable {
    case small, standard, large

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.9
        case .standard: return 1.0
        case .large: return 1.14
        }
    }

    static func decodeTolerant<K: CodingKey>(from container: KeyedDecodingContainer<K>,
                                             forKey key: K) -> FontSizePreference {
        let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        return raw.flatMap(FontSizePreference.init(rawValue:)) ?? .standard
    }
}

/// 設計 tokens:文字階層在深色模式下加亮(review 指出次要資訊過暗),
/// 淺色模式沿用系統語意色。所有視圖一律引用 tokens,不寫死顏色。
enum Theme {
    private static let defaultPrimary = dynamic(light: .labelColor, darkHex: 0xE6E8EA)
    private static let defaultSecondary = dynamic(light: .secondaryLabelColor, darkHex: 0xA8ADB2)
    private static let defaultMuted = dynamic(light: .tertiaryLabelColor, darkHex: 0x8E9499)
    private static let defaultDisabled = dynamic(light: .quaternaryLabelColor, darkHex: 0x6F767D)
    private static let highContrastPrimary = dynamic(light: .black, darkHex: 0xF2F4F6)
    private static let highContrastSecondary = dynamic(light: NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),
                                                       darkHex: 0xD0D4D9)
    private static let highContrastMuted = dynamic(light: NSColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1),
                                                   darkHex: 0xA8ADB2)

    private(set) static var textColorPreference: DashboardTextColorPreference = .system
    private(set) static var customTextPrimaryHex: UInt32?
    private(set) static var customTextSecondaryHex: UInt32?

    static var textPrimary: Color { resolvedPrimary() }
    static var textSecondary: Color { resolvedSecondary() }
    static var textMuted: Color { resolvedMuted() }
    static var textDisabled: Color { defaultDisabled }

    static func applyTextColors(preference: DashboardTextColorPreference,
                                primaryHex: UInt32?, secondaryHex: UInt32?) {
        textColorPreference = preference
        customTextPrimaryHex = primaryHex
        customTextSecondaryHex = secondaryHex
    }

    private static func resolvedPrimary() -> Color {
        switch textColorPreference {
        case .system: return defaultPrimary
        case .highContrast: return highContrastPrimary
        case .custom:
            if let customTextPrimaryHex, let c = ColorHexCodec.color(from: customTextPrimaryHex) { return c }
            return defaultPrimary
        }
    }

    private static func resolvedSecondary() -> Color {
        switch textColorPreference {
        case .system: return defaultSecondary
        case .highContrast: return highContrastSecondary
        case .custom:
            if let customTextSecondaryHex, let c = ColorHexCodec.color(from: customTextSecondaryHex) { return c }
            if let customTextPrimaryHex, let c = ColorHexCodec.color(from: customTextPrimaryHex) { return c.opacity(0.82) }
            return defaultSecondary
        }
    }

    private static func resolvedMuted() -> Color {
        switch textColorPreference {
        case .system: return defaultMuted
        case .highContrast: return highContrastMuted
        case .custom:
            return resolvedSecondary().opacity(0.78)
        }
    }

    /// 專案佔比底條等低調強調色。
    static let accentSubtle = Color.accentColor.opacity(0.16)

    /// User-chosen typeface design & scale (Settings → General). Dashboard / Limits read via `FontScale`.
    private(set) static var fontDesign: Font.Design = .default
    private(set) static var fontSizeScale: CGFloat = 1.0

    static func applyFontStyle(design: FontDesignPreference, size: FontSizePreference) {
        fontDesign = design.swiftUIDesign
        fontSizeScale = size.scale
    }

    private static func sized(_ points: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: points * fontSizeScale, weight: weight, design: fontDesign)
    }

    /// 字級尺標:密度不變,只統一階層。
    enum FontScale {
        static var metric: Font { Theme.sized(22, weight: .semibold) }
        static var cardTitle: Font { Theme.sized(13, weight: .semibold) }
        static var secondaryInfo: Font { Theme.sized(12) }
        static var tableHeader: Font { Theme.sized(12, weight: .semibold) }
        static var note: Font { Theme.sized(12) }
        static var micro: Font { Theme.sized(9) }
    }

    private static func dynamic(light: NSColor, darkHex: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(hex: darkHex) : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
