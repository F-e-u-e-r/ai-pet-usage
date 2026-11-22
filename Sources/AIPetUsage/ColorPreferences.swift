import SwiftUI
import AppKit
import PetCore

// MARK: - Dashboard text colors

enum DashboardTextColorPreference: String, Codable, CaseIterable, Sendable {
    case system
    case highContrast
    case custom

    var displayName: String {
        switch self {
        case .system: return "System"
        case .highContrast: return "High contrast"
        case .custom: return "Custom"
        }
    }

    static func decodeTolerant<K: CodingKey>(from container: KeyedDecodingContainer<K>,
                                             forKey key: K) -> DashboardTextColorPreference {
        let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        return raw.flatMap(DashboardTextColorPreference.init(rawValue:)) ?? .system
    }
}

// MARK: - Menu bar badge ink

enum MenuBarBadgeInkPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case light
    case dark
    case custom

    var displayName: String {
        switch self {
        case .automatic: return "Match menu bar"
        case .light: return "Light"
        case .dark: return "Dark"
        case .custom: return "Custom"
        }
    }

    static func decodeTolerant<K: CodingKey>(from container: KeyedDecodingContainer<K>,
                                             forKey key: K) -> MenuBarBadgeInkPreference {
        let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        return raw.flatMap(MenuBarBadgeInkPreference.init(rawValue:)) ?? .automatic
    }

    func baseColor(systemIsDark: Bool, customHex: UInt32?) -> Color {
        switch self {
        case .automatic:
            return Color(white: MenuBarBadgeInk.baseWhite(systemIsDark: systemIsDark))
        case .light:
            return Color(white: 0.94)
        case .dark:
            return Color(white: 0.14)
        case .custom:
            guard let customHex else {
                return Color(white: MenuBarBadgeInk.baseWhite(systemIsDark: systemIsDark))
            }
            return Color(nsColor: NSColor(hex: customHex))
        }
    }
}

enum MenuBarBadgeLabelStyle: String, Codable, CaseIterable, Sendable {
    case code
    case short
    case full

    var displayName: String {
        switch self {
        case .code: return "Short codes (CC, CX)"
        case .short: return "Short names (Claude, Codex)"
        case .full: return "Full names"
        }
    }

    static func decodeTolerant<K: CodingKey>(from container: KeyedDecodingContainer<K>,
                                             forKey key: K) -> MenuBarBadgeLabelStyle {
        let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        return raw.flatMap(MenuBarBadgeLabelStyle.init(rawValue:)) ?? .code
    }
}

enum ColorHexCodec {
    static func color(from hex: UInt32?) -> Color? {
        hex.map { Color(nsColor: NSColor(hex: $0)) }
    }

    /// 在 app 的實際外觀下解析動態色;半透明色(light 的 labelColor ≈ 85% 黑、secondaryLabel ≈ 50% 黑)
    /// 先疊到視窗底色,否則只取 RGB 會把主/次文字都 seed 成純黑。
    static func hex(from color: Color) -> UInt32? {
        var result: UInt32?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let c = NSColor(color).usingColorSpace(.sRGB),
                  let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) else { return }
            result = RGBHexValue.flattened(
                red: Double(c.redComponent), green: Double(c.greenComponent),
                blue: Double(c.blueComponent), alpha: Double(c.alphaComponent),
                overRed: Double(bg.redComponent), overGreen: Double(bg.greenComponent),
                overBlue: Double(bg.blueComponent))
        }
        return result
    }
}
