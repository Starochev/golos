import AppKit
import Foundation

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let tile = canvas - inset * 2
let radius: CGFloat = 185

func makeImage(_ draw: (CGContext) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    draw(ctx)
    image.unlockFocus()
    return image
}

func tilePath() -> CGPath {
    CGPath(roundedRect: CGRect(x: inset, y: inset, width: tile, height: tile),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func darkTile(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.addPath(tilePath())
    ctx.clip()
    let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: canvas / 2, y: canvas - inset),
                           end: CGPoint(x: canvas / 2, y: inset), options: [])
    let vignette = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 0, alpha: 0).cgColor,
                                       NSColor(white: 0, alpha: 0.55).cgColor] as CFArray,
                              locations: [0.45, 1])!
    ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: canvas / 2, y: canvas * 0.6), startRadius: 0,
                           endCenter: CGPoint(x: canvas / 2, y: canvas * 0.6), endRadius: tile * 0.78, options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath())
    ctx.setLineWidth(3)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
    ctx.strokePath()
    ctx.restoreGState()
}

func neon(_ ctx: CGContext, path: CGPath, passes: [(CGFloat, CGFloat)], white: CGFloat = 0.93) {
    for (blur, alpha) in passes {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: NSColor(white: 1, alpha: alpha).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(white: white, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// Лучи по кругу. Длина задаётся суммой гармоник с целыми частотами —
/// тогда контур замыкается без разрыва на стыке.
func ring(count: Int, inner: CGFloat, width: CGFloat,
          base: CGFloat, swing: CGFloat,
          shape: (CGFloat) -> CGFloat) -> CGPath {
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let path = CGMutablePath()
    for i in 0..<count {
        let angle = CGFloat(i) / CGFloat(count) * .pi * 2
        let length = base + swing * shape(angle)
        let start = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
        let bar = CGPath(roundedRect: CGRect(x: -width / 2, y: 0, width: width, height: length),
                         cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        let transform = CGAffineTransform(translationX: start.x, y: start.y).rotated(by: angle - .pi / 2)
        path.addPath(bar, transform: transform)
    }
    return path
}

func innerRing(_ ctx: CGContext, radius r: CGFloat, width: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: NSColor(white: 1, alpha: 0.5).cgColor)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(NSColor(white: 0.93, alpha: alpha).cgColor)
    ctx.addEllipse(in: CGRect(x: canvas / 2 - r, y: canvas / 2 - r, width: r * 2, height: r * 2))
    ctx.strokePath()
    ctx.restoreGState()
}

// Симметрия честная: число лучей кратно частоте модуляции, поэтому
// рисунок повторяется ровно и контур не заваливается набок.

/// Один рисунок в трёх плотностях. На 16 и 32 пикселях тонкие лучи сливаются
/// в кашу, поэтому мелкие размеры получают свою, упрощённую версию —
/// ровно для этого в наборе иконок и предусмотрены отдельные картинки.
func orb(_ ctx: CGContext, count: Int, barWidth: CGFloat, inner: CGFloat,
         base: CGFloat, swing: CGFloat, ringRadius: CGFloat, ringWidth: CGFloat,
         lobes: CGFloat, glow: [(CGFloat, CGFloat)]) {
    darkTile(ctx)
    innerRing(ctx, radius: ringRadius, width: ringWidth, alpha: 0.5)
    let path = ring(count: count, inner: inner, width: barWidth, base: base, swing: swing) { angle in
        0.5 + 0.5 * sin(angle * lobes)
    }
    neon(ctx, path: path, passes: glow)
}

/// Крупные размеры: вся детализация.
func orbFull(_ ctx: CGContext) {
    orb(ctx, count: 60, barWidth: 18, inner: 176, base: 72, swing: 54,
        ringRadius: 134, ringWidth: 14, lobes: 6,
        glow: [(64, 0.5), (30, 0.6), (10, 0.9)])
}

/// Средние: лучей вдвое меньше, каждый вдвое толще.
func orbMedium(_ ctx: CGContext) {
    orb(ctx, count: 30, barWidth: 34, inner: 178, base: 76, swing: 50,
        ringRadius: 132, ringWidth: 20, lobes: 6,
        glow: [(56, 0.5), (26, 0.6), (9, 0.9)])
}

/// Мелкие: крупные зубцы и толстое кольцо — форма должна читаться
/// в шестнадцати пикселях, где деталей не остаётся вовсе.
func orbSmall(_ ctx: CGContext) {
    orb(ctx, count: 12, barWidth: 74, inner: 196, base: 92, swing: 40,
        ringRadius: 138, ringWidth: 34, lobes: 6,
        glow: [(44, 0.45), (18, 0.7)])
}

/// Шестнадцать пикселей: свечение здесь только мылит, поэтому рисуем
/// плоско и контрастно — чистый белый на чёрном, крупные зубцы.
func orbTiny(_ ctx: CGContext) {
    darkTile(ctx)
    innerRing(ctx, radius: 150, width: 46, alpha: 1.0)
    let path = ring(count: 8, inner: 208, width: 92, base: 104, swing: 0) { _ in 0 }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}

func save(_ image: NSImage, _ path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
save(makeImage(orbFull),   "\(dir)/icon-full.png")
save(makeImage(orbMedium), "\(dir)/icon-medium.png")
save(makeImage(orbSmall),  "\(dir)/icon-small.png")
save(makeImage(orbTiny),   "\(dir)/icon-tiny.png")
print("нарисовано")
