import AppKit

/// Иконка в строке меню.
///
/// Рисуется вручную, а не берётся из SF Symbols: во время записи она должна
/// шевелиться в такт голосу, а готового символа с таким поведением нет.
/// В покое отдаём шаблонное изображение — тогда система сама красит его
/// под светлую и тёмную строку меню и подсвечивает при открытом меню.
enum MenuBarIcon {
    enum Look {
        case loading
        case idle
        case recording(level: CGFloat, color: NSColor?)
        case transcribing(phase: CGFloat)
        case needsModel
        case failed
    }

    static let size = NSSize(width: 20, height: 16)

    /// Пять полос — та же фигура, что в окошке записи, только крошечная.
    private static let barCount = 5
    private static let barWidth: CGFloat = 2.4
    private static let gap: CGFloat = 1.9

    static func image(for look: Look) -> NSImage {
        switch look {
        case .loading:
            return symbol("ellipsis", template: true)
        case .needsModel:
            return symbol("arrow.down.circle", template: true)
        case .failed:
            return symbol("exclamationmark.triangle.fill", template: false, tint: .systemOrange)
        case .idle:
            return bars(heights: idleHeights, color: nil)
        case .recording(let level, let color):
            return bars(heights: recordingHeights(level: level), color: color)
        case .transcribing(let phase):
            return bars(heights: travellingHeights(phase: phase), color: .secondaryLabelColor)
        }
    }

    // MARK: - Формы

    /// Покой: ровная симметричная волна, ничего не мигает.
    private static let idleHeights: [CGFloat] = [4, 8, 12, 8, 4]

    /// Запись: полосы тянутся за громкостью, середина отзывается сильнее краёв,
    /// иначе фигура выглядит как прыгающий блок, а не как волна.
    private static func recordingHeights(level: CGFloat) -> [CGFloat] {
        let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
        return weights.map { weight in
            let amplitude = 3 + level * 11 * weight
            return min(14, max(3, amplitude))
        }
    }

    /// Распознавание: волна бежит слева направо — видно, что работа идёт.
    private static func travellingHeights(phase: CGFloat) -> [CGFloat] {
        (0..<barCount).map { i in
            let offset = CGFloat(i) * 0.9
            return 4 + 5 * (0.5 + 0.5 * sin(phase - offset))
        }
    }

    // MARK: - Рисование

    private static func bars(heights: [CGFloat], color: NSColor?) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        (color ?? .black).setFill()

        let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
        var x = (size.width - total) / 2
        for height in heights {
            let rect = NSRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }

        image.unlockFocus()
        // Шаблон только для покоя: цветные состояния система перекрасила бы
        // в чёрный и потеряла бы весь смысл красного при записи.
        image.isTemplate = (color == nil)
        return image
    }

    private static func symbol(_ name: String, template: Bool, tint: NSColor? = nil) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return NSImage(size: size)
        }
        guard let tint, !template else {
            base.isTemplate = template
            return base
        }
        let image = NSImage(size: base.size)
        image.lockFocus()
        tint.set()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
