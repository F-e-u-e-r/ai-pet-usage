import SwiftUI

// 圖表游標 tooltip 共用元件(A4/A9/A10;R4 修訂):
//   - 單一 plot-area hover:整個圖面一個 onContinuousHover,由座標反推 bucket;
//   - 定位 = **恆在指標右側**(+14pt),僅在容器極右緣夾回、不左右翻轉
//     (R4 三方裁定:右側固定較可預期;垂直置中於游標、上下夾限);
//   - 內容一律水平 fixedSize(不換行、動態寬 — 修「文字被截/擠壓換行」);
//   - 以隱藏量測取真實尺寸後才顯示;不攔截點擊;樣式沿 Theme。

/// 把 tooltip 疊在游標右側;`cursor` 為容器座標系內的游標點。
struct CursorTooltip<Content: View>: View {
    let cursor: CGPoint
    let container: CGSize
    @ViewBuilder var content: Content

    /// nil = 尚未量到真實尺寸 → 先隱藏一幀,避免以猜測尺寸定位後跳位。
    @State private var measured: CGSize?

    var body: some View {
        content
            .fixedSize(horizontal: true, vertical: false)   // 不換行;寬 = 最長行
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .background(GeometryReader { geo in
                Color.clear.onAppear { measured = geo.size }
                    .onChange(of: geo.size) { _, s in measured = s }
            })
            .opacity(measured == nil ? 0 : 1)
            .position(trailingAnchored)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// 恆右 +14pt、垂直置中於游標;僅夾限(極右緣往左收、上下緣內收),不翻轉。
    private var trailingAnchored: CGPoint {
        let m = measured ?? CGSize(width: 200, height: 70)
        var x = cursor.x + 14 + m.width / 2
        x = min(x, container.width - m.width / 2)
        x = max(x, m.width / 2)
        var y = cursor.y
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
