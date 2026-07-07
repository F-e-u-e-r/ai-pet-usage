import SwiftUI
import AppKit
import PetCore

// 選單列彩色徽章(UIUX spec P0):
//   🐶 ● CC 91% ● CX 53%
// dot = provider 身分(恆定),百分比顏色 = severity。
// MenuBarExtra 的 label 會被系統以 template 單色渲染,顏色必須先烤成
// 非 template 的 NSImage(2x)再塞回 label。

/// provider 身分小圓點(identity 色恆定,絕不隨用量改色)。
struct ProviderDot: View {
    let brand: ProviderBrand
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Color(nsColor: NSColor(hex: brand.dotColor)))
            .overlay {
                if brand.needsOutline {
                    Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1)
                }
            }
            .frame(width: size, height: size)
    }
}

/// severity → 百分比文字色;normal 回傳 nil(沿用當前文字色)。
func severityColor(_ severity: UsageSeverity) -> Color? {
    switch severity {
    case .normal: return nil
    case .warn: return Color(red: 1.0, green: 0.62, blue: 0.15)
    case .danger: return Color(red: 0.96, green: 0.32, blue: 0.30)
    }
}

/// 選單列徽章列(被烤成 NSImage 的來源視圖)。
struct MenuBarBadgeView: View {
    let petEmoji: String
    let badges: [MenuBadge]
    let showsPlaceholder: Bool
    /// 一般文字色,依選單列深淺決定(烤圖時無法用動態色)。
    let baseColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(petEmoji).font(.system(size: 13))
            if badges.isEmpty, showsPlaceholder {
                Text("—")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(baseColor.opacity(0.7))
            }
            ForEach(badges) { badge in
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: badge.dotColor)))
                        .overlay {
                            if badge.needsOutline {
                                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 0.8)
                            }
                        }
                        .frame(width: 7, height: 7)
                    Text(badge.code)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(baseColor.opacity(0.85))
                    Text("\(badge.percent)%")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(severityColor(badge.severity) ?? baseColor)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 18)
        .fixedSize()
    }
}

@MainActor
enum MenuBarBadgeRenderer {
    /// 以 2x 烤出非 template NSImage。選單列深淺以系統外觀近似
    /// (罕見的桌布淺色選單列 + 深色系統外觀組合會有對比落差,屬已知限制)。
    static func image(petEmoji: String, badges: [MenuBadge], showsPlaceholder: Bool) -> NSImage? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? Color(white: 0.98) : Color(white: 0.15)
        let renderer = ImageRenderer(content: MenuBarBadgeView(
            petEmoji: petEmoji, badges: badges,
            showsPlaceholder: showsPlaceholder, baseColor: base))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}
