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
        case .code: return "Short codes (CC, Fb)"
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

    static func hex(from color: Color) -> UInt32? {
        guard let cg = NSColor(color).usingColorSpace(.sRGB)?.cgColor,
              let comps = cg.components, comps.count >= 3 else { return nil }
        let r = UInt32(min(255, max(0, Int(comps[0] * 255))))
        let g = UInt32(min(255, max(0, Int(comps[1] * 255))))
        let b = UInt32(min(255, max(0, Int(comps[2] * 255))))
        return (r << 16) | (g << 8) | b
    }
}