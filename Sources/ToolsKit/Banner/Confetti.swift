import AppKit
import QuartzCore
import SuperPDFCore

/// A short burst of confetti in the brand colours (ux §2.5 "success"): it bursts from a view (the banner's check) over the
/// window's content for `SPMotion.confetti` seconds and cleans up after itself. Nothing happens off screen or with Reduce
/// Motion on.
@MainActor
enum Confetti {
    static func burst(from view: NSView) {
        guard !Style.reduceMotion, let window = view.window, window.isVisible, let host = window.contentView else { return }
        host.wantsLayer = true
        guard let hostLayer = host.layer else { return }
        // A layer-backed view's layer works in the view's own coordinates, flipped or not; gravity points down on screen.
        let down: CGFloat = host.isFlipped ? 1 : -1
        let origin = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: host)
        let emitter = CAEmitterLayer()
        emitter.frame = host.bounds
        emitter.emitterPosition = origin
        emitter.emitterShape = .point
        emitter.emitterSize = CGSize(width: 4, height: 4)
        emitter.zPosition = 1000
        let colors = SPColor.categories.map(\.color) + [SPColor.brand.color]
        emitter.emitterCells = colors.enumerated().map { index, color in
            let cell = CAEmitterCell()
            cell.contents = piece(round: index % 3 == 0)
            cell.color = color.cgColor
            cell.birthRate = 30
            cell.lifetime = Float(SPMotion.confetti)
            cell.velocity = 210
            cell.velocityRange = 90
            cell.emissionLongitude = -down * .pi / 2
            cell.emissionRange = .pi * 0.9
            cell.yAcceleration = down * 340
            cell.spin = 4
            cell.spinRange = 8
            cell.scale = 0.9
            cell.scaleRange = 0.4
            cell.alphaSpeed = -0.6
            return cell
        }
        emitter.beginTime = CACurrentMediaTime()
        hostLayer.addSublayer(emitter)
        // A burst, not a fountain: stop making pieces at once, take the layer away when the last one has fallen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { emitter.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + SPMotion.confetti + 0.3) { emitter.removeFromSuperlayer() }
    }

    /// One piece: a little rectangle, or a dot.
    private static func piece(round: Bool) -> CGImage? {
        let size = round ? CGSize(width: 6, height: 6) : CGSize(width: 5, height: 9)
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let rect = CGRect(origin: .zero, size: size)
        if round { context.fillEllipse(in: rect) } else { context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)); context.fillPath() }
        return context.makeImage()
    }
}
