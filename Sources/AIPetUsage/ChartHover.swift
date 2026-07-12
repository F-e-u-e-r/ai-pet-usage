import SwiftUI

// 圖表游標 tooltip 共用元件(A4/A9/A10;D9 定案):
//   - 單一 plot-area hover:整個圖面一個 onContinuousHover,由座標反推 bucket
//     (消除逐 bar hover 在 1px gap 斷線的問題);
//   - tooltip 以隱藏量測取得真實尺寸後,錨在游標 (12,12) 偏移,近右/下緣翻轉,
//     夾在容器內;不攔截點擊;
//   - 視覺樣式沿 Theme(recessive 底、細邊、text token 上色 — 不吃 series 色)。

/// 把 tooltip 疊在游標旁;`content` 為 tooltip 內容,`cursor` 為容器座標系內的游標點。
struct CursorTooltip<Content: View>: View {
    let cursor: CGPoint
    let container: CGSize
    @ViewBuilder var content: Content

    /// nil = 尚未量到真實尺寸 → 先隱藏一幀,避免以猜測尺寸定位後跳位(grok P3-1)。
    @State private var measured: CGSize?

    var body: some View {
        content
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .background(GeometryReader { geo in
                Color.clear.onAppear { measured = geo.size }
                    .onChange(of: geo.size) { _, s in measured = s }
            })
            .opacity(measured == nil ? 0 : 1)
            .position(clampedCenter)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// 游標右下 (12,12);右/下放不下 → 翻到左/上;最後夾進容器。
    private var clampedCenter: CGPoint {
        let m = measured ?? CGSize(width: 180, height: 70)
        let pad: CGFloat = 12
        var x = cursor.x + pad + m.width / 2
        if cursor.x + pad + m.width > container.width {
            x = cursor.x - pad - m.width / 2
        }
        var y = cursor.y + pad + m.height / 2
        if cursor.y + pad + m.height > container.height {
            y = cursor.y - pad - m.height / 2
        }
        x = min(max(x, m.width / 2), max(container.width - m.width / 2, m.width / 2))
        y = min(max(y, m.height / 2), max(container.height - m.height / 2, m.height / 2))
        return CGPoint(x: x, y: y)
    }
}

/// 好看刻度上限(1/2/5 × 10ⁿ;HourlyChart 與 Trends 日圖共用)。
func niceCeiling(_ value: Double) -> Double {
    guard value > 0 else { return 1 }
    let power = pow(10, floor(log10(value)))
    for mult in [1.0, 2.0, 5.0, 10.0] where power * mult >= value {
        return power * mult
    }
    return value
}
