import SwiftUI
import AppKit

/// 設計 tokens:文字階層在深色模式下加亮(review 指出次要資訊過暗),
/// 淺色模式沿用系統語意色。所有視圖一律引用 tokens,不寫死顏色。
enum Theme {
    static let textPrimary = dynamic(light: .labelColor, darkHex: 0xE6E8EA)
    static let textSecondary = dynamic(light: .secondaryLabelColor, darkHex: 0xA8ADB2)
    static let textMuted = dynamic(light: .tertiaryLabelColor, darkHex: 0x8E9499)
    static let textDisabled = dynamic(light: .quaternaryLabelColor, darkHex: 0x6F767D)

    /// 專案佔比底條等低調強調色。
    static let accentSubtle = Color.accentColor.opacity(0.16)

    /// 字級尺標:密度不變,只統一階層。
    enum FontScale {
        static let metric = Font.title2.weight(.semibold)          // 主要數字
        static let cardTitle = Font.headline                        // 卡片標題(粗細取勝)
        static let secondaryInfo = Font.system(size: 12)            // 有意義的次要資訊
        static let tableHeader = Font.system(size: 12, weight: .semibold)
        static let note = Font.system(size: 12)                     // data-quality 註記
        static let micro = Font.system(size: 9)                     // 座標軸刻度
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
