import AppKit
import SwiftUI

/// Цвет волны: одна настройка красит и всплывающее окошко, и иконку
/// в строке меню — разъезжаться им незачем.
struct WaveTheme: Identifiable, Hashable {
    let id: String
    let title: String
    let hex: String
    /// Монохромной теме в строке меню цвет не нужен: шаблонное изображение
    /// система красит сама и не промахивается ни на светлой, ни на тёмной.
    let menuBarUsesTemplate: Bool

    static let customID = "custom"

    static let all: [WaveTheme] = [
        WaveTheme(id: "red",    title: "Красный",    hex: "#FF453A", menuBarUsesTemplate: false),
        WaveTheme(id: "teal",   title: "Бирюзовый",  hex: "#2CD4C0", menuBarUsesTemplate: false),
        WaveTheme(id: "violet", title: "Фиолетовый", hex: "#A78BFA", menuBarUsesTemplate: false),
        WaveTheme(id: "amber",  title: "Янтарный",   hex: "#FFB020", menuBarUsesTemplate: false),
        WaveTheme(id: "mono",   title: "Монохром",   hex: "#F2F2F7", menuBarUsesTemplate: true)
    ]

    static let fallback = all[0]

    static func named(_ id: String) -> WaveTheme? {
        all.first { $0.id == id }
    }

    /// Цвет для окошка записи. Фон там тёмный, поэтому берётся как есть.
    static func color(for config: Config) -> NSColor {
        if config.waveTheme == customID {
            return NSColor(hex: config.customWaveColor) ?? fallback.nsColor
        }
        return (named(config.waveTheme) ?? fallback).nsColor
    }

    /// Цвет для строки меню. nil — рисовать шаблоном, пусть система красит.
    static func menuBarColor(for config: Config) -> NSColor? {
        if config.waveTheme == customID {
            return NSColor(hex: config.customWaveColor) ?? fallback.nsColor
        }
        let theme = named(config.waveTheme) ?? fallback
        return theme.menuBarUsesTemplate ? nil : theme.nsColor
    }

    var nsColor: NSColor { NSColor(hex: hex) ?? .systemRed }
    var swiftUIColor: Color { Color(nsColor) }
}

extension NSColor {
    /// Разбирает "#RRGGBB" и "RRGGBB". Кривая строка даёт nil, а не чёрный
    /// квадрат: в настройках это поле правится руками.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    /// Обратное преобразование — для сохранения выбора из палитры.
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#FF453A" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
