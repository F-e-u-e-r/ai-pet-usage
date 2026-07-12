import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PetCore

// `aipet sprites`:像素寵物驗收工具(Pixel Pet spec 的 acceptance loop)。
// 把每個 species × state × frame 以 nearest-neighbor 畫成 PNG contact sheet:
//   - 100%(≈ App 內實際尺寸,6pt/cell)
//   - 50%(縮小辨識測試)
//   - grayscale(灰階辨識測試:貓不得只靠綠眼辨識)
// 全部合成在實際 dashboard 深色背景上,附 index.html 供人工檢視。

enum SpriteExport {

    /// 近似 App 深色介面的三層背景(hex 對應 Theme.swift 的深色視覺;
    /// CLI 無法取用 AppKit 動態色,故寫死近似值)。
    static let backgrounds: [(name: String, hex: UInt32)] = [
        ("dashboard", 0x1E2126),
        ("card", 0x2A2E34),
        ("hover", 0x353A41),
    ]

    static func run(outPath: String?) {
        let outURL = URL(fileURLWithPath: outPath ?? "dist/sprite-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        var html = htmlHeader
        for species in PetSpecies.allCases {
            let sprite = PixelPets.sprite(for: species)
            html += "<h1>\(species.emoji) \(species.displayName)</h1>\n"

            // 依 enum 順序匯出「實際有定義幀」的狀態(fallback 到 idle 的不重複輸出)
            for state in PixelAnimState.allCases {
                guard sprite.animations[state] != nil else { continue }
                let frames = sprite.frames(for: state)
                html += section(species: species, label: "state: \(state.rawValue)",
                                slug: "\(species.rawValue)-\(state.rawValue)",
                                frames: frames, fps: PixelPets.fps(for: state),
                                sprite: sprite, outURL: outURL)
            }

            // micro-animation 幀(不在 animations dict 內)
            var seenMicro = Set<String>()
            for state in PixelAnimState.allCases {
                for micro in PixelPets.microAnimations(species: species, state: state)
                where !seenMicro.contains(micro.name) {
                    seenMicro.insert(micro.name)
                    html += section(species: species, label: "micro: \(micro.name) (every \(Int(micro.interval.lowerBound))–\(Int(micro.interval.upperBound))s)",
                                    slug: "\(species.rawValue)-micro-\(micro.name)",
                                    frames: micro.frames, fps: micro.fps,
                                    sprite: sprite, outURL: outURL)
                }
            }
        }

        // EngineV2 packs(E2a):附 palette 的 pack 也進同一個 preview 頁。
        // 狗/貓 pack 幀與 legacy 完全相同(遷移 golden 釘住),不重複輸出,只列鳥。
        html += packSection(pack: SpeciesPacks.birdPack(), emoji: "🐦", outURL: outURL)

        html += htmlFooter

        let indexURL = outURL.appendingPathComponent("index.html")
        try? html.data(using: .utf8)?.write(to: indexURL)
        print("sprite preview written: \(indexURL.path)")
    }

    // MARK: - 單一區段(一個 state 的三種變體 strip)

    private static func section(species: PetSpecies, label: String, slug: String,
                                frames: [[String]], fps: Double,
                                sprite: PixelSprite, outURL: URL) -> String {
        var imgs = ""
        for (variant, cell, gray) in [("100", 6, false), ("50", 3, false), ("gray", 6, true)] {
            let name = "\(slug)-\(variant).png"
            if let image = renderStrip(frames: frames, sprite: sprite, cell: cell,
                                       grayscale: gray, backgroundHex: backgrounds[0].hex) {
                writePNG(image, to: outURL.appendingPathComponent(name))
                imgs += "<figure><img src=\"\(name)\" alt=\"\(slug) \(variant)\"><figcaption>\(variant == "gray" ? "grayscale" : variant + "%")</figcaption></figure>\n"
            }
        }
        return """
        <section>
        <h2>\(label) · \(frames.count) frame(s) · \(String(format: "%.1f", fps)) fps</h2>
        <div class="strips">\(imgs)</div>
        </section>\n
        """
    }

    // MARK: - EngineV2 pack 區段(G1:鳥 idle/fly 真 sheets;動作依固定順序)

    private static func packSection(pack: SpeciesPack, emoji: String, outURL: URL) -> String {
        var html = "<h1>\(emoji) \(pack.displayName) — EngineV2 pack</h1>\n"
        html += """
        <div class="checklist">
        <strong>G1 驗收清單(藍鳥)</strong>
        <ul>
        <li>50% 尺寸下仍可辨識為鳥(藍身、橘喙、奶白腹)</li>
        <li>灰階下剪影可辨:喙(深框)、翅(暗階)、尾(腳間暗楔)</li>
        <li>外框在深色背景不融入;idle 兩幀呼吸、flyFlap 四相翅位清晰</li>
        <li>drag 驚訝白瞪眼、working 低頭打字可讀</li>
        </ul>
        </div>\n
        """
        let order: [PetActionID] = [.idle, .flyFlap, .glide, .drag, .working1]
        let fps = 1.0 / EngineLoop.frameDuration
        for action in order {
            guard let frames = pack.frames[action], !frames.isEmpty else { continue }
            let rowFrames = frames.map { $0.components(separatedBy: "\n") }
            html += gridSection(label: "action: \(action.rawValue)",
                                slug: "pack-\(pack.id)-\(action.rawValue)",
                                frames: rowFrames, fps: fps,
                                palette: pack.palette, gridWidth: pack.gridWidth,
                                gridHeight: pack.gridHeight, outURL: outURL)
        }
        return html
    }

    /// 泛化區段:任意 (palette, grid) 的三變體 strip(legacy sprite 與 V2 pack 共用)。
    private static func gridSection(label: String, slug: String, frames: [[String]], fps: Double,
                                    palette: [Character: UInt32], gridWidth: Int, gridHeight: Int,
                                    outURL: URL) -> String {
        var imgs = ""
        for (variant, cell, gray) in [("100", 6, false), ("50", 3, false), ("gray", 6, true)] {
            let name = "\(slug)-\(variant).png"
            if let image = renderStrip(frames: frames, palette: palette,
                                       gridWidth: gridWidth, gridHeight: gridHeight,
                                       cell: cell, grayscale: gray, backgroundHex: backgrounds[0].hex) {
                writePNG(image, to: outURL.appendingPathComponent(name))
                imgs += "<figure><img src=\"\(name)\" alt=\"\(slug) \(variant)\"><figcaption>\(variant == "gray" ? "grayscale" : variant + "%")</figcaption></figure>\n"
            }
        }
        return """
        <section>
        <h2>\(label) · \(frames.count) frame(s) · \(String(format: "%.1f", fps)) fps</h2>
        <div class="strips">\(imgs)</div>
        </section>\n
        """
    }

    // MARK: - CoreGraphics 渲染(整數 cell、無反鋸齒 = nearest-neighbor)

    private static func renderStrip(frames: [[String]], sprite: PixelSprite, cell: Int,
                                    grayscale: Bool, backgroundHex: UInt32) -> CGImage? {
        renderStrip(frames: frames, palette: sprite.palette,
                    gridWidth: sprite.width, gridHeight: sprite.height,
                    cell: cell, grayscale: grayscale, backgroundHex: backgroundHex)
    }

    private static func renderStrip(frames: [[String]], palette: [Character: UInt32],
                                    gridWidth: Int, gridHeight: Int, cell: Int,
                                    grayscale: Bool, backgroundHex: UInt32) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        let pad = 8, gap = 8
        let frameW = gridWidth * cell
        let frameH = gridHeight * cell
        let width = pad * 2 + frames.count * frameW + (frames.count - 1) * gap
        let height = pad * 2 + frameH

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none

        fill(ctx, hex: backgroundHex, rect: CGRect(x: 0, y: 0, width: width, height: height))

        for (fi, frame) in frames.enumerated() {
            let originX = pad + fi * (frameW + gap)
            for (ri, row) in frame.enumerated() {
                for (ci, ch) in row.enumerated() where ch != "." {
                    guard var rgb = palette[ch] else { continue }
                    if grayscale { rgb = luma(rgb) }
                    // CG 原點在左下,列由上往下 → y 需翻轉
                    let rect = CGRect(x: originX + ci * cell,
                                      y: height - pad - (ri + 1) * cell,
                                      width: cell, height: cell)
                    fill(ctx, hex: rgb, rect: rect)
                }
            }
        }
        return ctx.makeImage()
    }

    private static func fill(_ ctx: CGContext, hex: UInt32, rect: CGRect) {
        ctx.setFillColor(CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                                 green: CGFloat((hex >> 8) & 0xFF) / 255,
                                 blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
        ctx.fill(rect)
    }

    private static func luma(_ rgb: UInt32) -> UInt32 {
        let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
        let y = UInt32((0.299 * r + 0.587 * g + 0.114 * b).rounded())
        return (y << 16) | (y << 8) | y
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                         1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - index.html

    private static let htmlHeader = """
    <!doctype html><meta charset="utf-8"><title>AI Pet Usage — sprite preview</title>
    <style>
    body { background: #1E2126; color: #E6E8EA; font: 13px -apple-system, sans-serif; padding: 24px; }
    h1 { margin-top: 32px; } h2 { color: #A8ADB2; font-size: 13px; font-weight: 600; }
    img { image-rendering: pixelated; border: 1px solid #353A41; border-radius: 4px; }
    .strips { display: flex; gap: 16px; flex-wrap: wrap; align-items: flex-start; }
    figure { margin: 0; } figcaption { color: #8E9499; font-size: 11px; margin-top: 4px; }
    .checklist { background: #2A2E34; padding: 12px 16px; border-radius: 8px; max-width: 720px; }
    </style>
    <div class="checklist">
    <strong>驗收清單(Pixel Pet spec)</strong>
    <ul>
    <li>50% 尺寸下狗與貓仍可辨識</li>
    <li>灰階下(無綠眼)貓仍讀得出是貓:耳朵、鬍鬚、臉頰、尾巴</li>
    <li>黑貓輪廓不得融入深色背景</li>
    <li>focused 狀態要能從「眼形 + 耳朵前傾 + 顏色」讀出,而不只是紅綠切換</li>
    <li>驚嘆號/尾巴/耳朵動作是否都是整數像素位移</li>
    </ul>
    </div>
    """

    private static let htmlFooter = "\n"
}
