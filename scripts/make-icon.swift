// Renders Super PDF's app icon into a folder. Original artwork, in the modern macOS shape: a blue rounded-square plate
// lit from above; on it a sheet of paper, slightly turned, with a folded corner, lines of text and one line marked in
// Preview's yellow highlight; and on the sheet's lower corner a small blue seal with a four-point spark, the "super".
//   AppIcon.iconset/   the app icon at every size iconutil needs
// Usage: swift scripts/make-icon.swift <out-folder>
// Adapted from super-granola scripts/make-icon.swift (the plate geometry, its shadow and the iconset sizes).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func context(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func png(_ ctx: CGContext) -> Data { NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])! }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

/// A four-point spark centred on `c` with outer radius `r`.
func spark(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let inner = r * 0.26
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let radius = i % 2 == 0 ? r : inner
        let p = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func renderIcon(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = context(px)
    let small = px <= 32

    // The plate: Apple's icon grid (824 of 1024, centred, a little high), its soft shadow, a blue lit from above.
    let inset = s * 0.098
    let plate = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.225
    let squircle = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.3))
    ctx.addPath(squircle); ctx.setFillColor(color(0x1D5FD6)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x4FA3FF), color(0x1F63E0), color(0x1846B8)], [0, 0.55, 1]),
                           start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: [])
    // A gentle sheen across the top.
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: plate.midX, y: plate.maxY), startRadius: 0,
                           endCenter: CGPoint(x: plate.midX, y: plate.maxY), endRadius: plate.width * 0.75, options: [])
    ctx.restoreGState()

    // The sheet: portrait, turned 4° to the left, with its top-right corner folded down.
    let sheetWidth = plate.width * 0.56, sheetHeight = sheetWidth * 1.3
    let fold = sheetWidth * 0.22
    ctx.saveGState()
    ctx.translateBy(x: plate.midX, y: plate.midY - plate.height * 0.01)
    ctx.rotate(by: 4 * .pi / 180)
    let sheet = CGRect(x: -sheetWidth / 2, y: -sheetHeight / 2, width: sheetWidth, height: sheetHeight)
    let corner = sheetWidth * 0.045
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: sheet.minX + corner, y: sheet.minY))
    outline.addLine(to: CGPoint(x: sheet.maxX - corner, y: sheet.minY))
    outline.addQuadCurve(to: CGPoint(x: sheet.maxX, y: sheet.minY + corner), control: CGPoint(x: sheet.maxX, y: sheet.minY))
    outline.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
    outline.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
    outline.addLine(to: CGPoint(x: sheet.minX + corner, y: sheet.maxY))
    outline.addQuadCurve(to: CGPoint(x: sheet.minX, y: sheet.maxY - corner), control: CGPoint(x: sheet.minX, y: sheet.maxY))
    outline.addLine(to: CGPoint(x: sheet.minX, y: sheet.minY + corner))
    outline.addQuadCurve(to: CGPoint(x: sheet.minX + corner, y: sheet.minY), control: CGPoint(x: sheet.minX, y: sheet.minY))
    outline.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.014), blur: s * 0.035, color: color(0x0A1F55, 0.45))
    ctx.addPath(outline); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(outline); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xEEF1F6)], [0, 1]),
                           start: CGPoint(x: 0, y: sheet.maxY), end: CGPoint(x: 0, y: sheet.minY), options: [])
    ctx.restoreGState()
    // The folded corner: the back of the paper, a little darker, with a soft edge shadow.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
    flap.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold * 0.92))
    flap.addQuadCurve(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold), control: CGPoint(x: sheet.maxX - fold * 0.9, y: sheet.maxY - fold))
    flap.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -s * 0.004, height: -s * 0.004), blur: s * 0.01, color: color(0x000000, 0.25))
    ctx.addPath(flap); ctx.setFillColor(color(0xD9DFEA)); ctx.fillPath()
    ctx.restoreGState()

    // Text: a title, then lines; the third marked in the highlight yellow. Fewer, heavier lines at small sizes.
    let left = sheet.minX + sheetWidth * 0.14, right = sheet.maxX - sheetWidth * 0.14
    let lineHeight = sheetHeight * (small ? 0.075 : 0.045)
    let gap = sheetHeight * (small ? 0.12 : 0.085)
    var y = sheet.maxY - sheetHeight * 0.2
    ctx.setFillColor(color(0x2B3445))
    ctx.addPath(CGPath(roundedRect: CGRect(x: left, y: y, width: (right - left) * 0.62, height: lineHeight * 1.35),
                       cornerWidth: lineHeight * 0.5, cornerHeight: lineHeight * 0.5, transform: nil))
    ctx.fillPath()
    y -= gap * 1.35
    let widths: [CGFloat] = small ? [1, 0.82, 0.9] : [1, 0.94, 0.88, 1, 0.7, 0.96, 0.8]
    for (index, width) in widths.enumerated() {
        let line = CGRect(x: left, y: y, width: (right - left) * width, height: lineHeight)
        if index == 2 {
            let mark = line.insetBy(dx: -lineHeight * 0.45, dy: -lineHeight * 0.55)
            ctx.addPath(CGPath(roundedRect: mark, cornerWidth: lineHeight * 0.35, cornerHeight: lineHeight * 0.35, transform: nil))
            ctx.setFillColor(color(0xFACD5A)); ctx.fillPath()
        }
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        ctx.setFillColor(color(0xA7B0C0)); ctx.fillPath()
        y -= gap
    }

    // The seal: a blue disc with a white spark, overlapping the sheet's lower right corner.
    let sealRadius = sheetWidth * 0.2
    let seal = CGPoint(x: sheet.maxX - sealRadius * 0.55, y: sheet.minY + sealRadius * 0.55)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.016, color: color(0x0A1F55, 0.45))
    ctx.addEllipse(in: CGRect(x: seal.x - sealRadius, y: seal.y - sealRadius, width: sealRadius * 2, height: sealRadius * 2))
    ctx.setFillColor(color(0x1F63E0)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: seal.x - sealRadius, y: seal.y - sealRadius, width: sealRadius * 2, height: sealRadius * 2))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x5AAEFF), color(0x1A50C8)], [0, 1]),
                           start: CGPoint(x: seal.x, y: seal.y + sealRadius), end: CGPoint(x: seal.x, y: seal.y - sealRadius), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFFFFF, 0.9)); ctx.setLineWidth(max(s * 0.006, 0.6))
    ctx.strokeEllipse(in: CGRect(x: seal.x - sealRadius, y: seal.y - sealRadius, width: sealRadius * 2, height: sealRadius * 2))
    ctx.addPath(spark(seal, sealRadius * 0.62)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    return png(ctx)
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! renderIcon(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print("Rendered the icon into \(out.path)")
