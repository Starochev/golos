import AppKit

/// Разведка кнопок пультов: что вообще присылает гарнитура, AirPods или
/// приёмник радиосистемы.
///
/// Запускается ключом `--probe-media` и пишет в журнал каждое системное
/// событие пульта: код кнопки, нажатие или отпускание. Нужен, чтобы не гадать,
/// доходит ли кнопка до Мака и годится ли она под удержание.
enum MediaProbe {
    private static var tap: CFMachPort?

    static let names: [Int: String] = [
        0: "громче",
        1: "тише",
        7: "выключить звук",
        16: "play/pause",
        17: "следующий трек",
        18: "предыдущий трек",
        19: "быстрая перемотка вперёд",
        20: "перемотка назад"
    ]

    static func title(for code: Int) -> String { names[code] ?? "неизвестная кнопка" }

    static func start(seconds: Double) {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << 14),
            callback: { _, _, event, _ in
                if let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
                    let data = ns.data1
                    let code = Int((data & 0xFFFF_0000) >> 16)
                    let flags = data & 0x0000_FFFF
                    let down = ((flags & 0xFF00) >> 8) == 0x0A
                    Log.write("ПУЛЬТ: код \(code), \(MediaProbe.title(for: code)), \(down ? "нажата" : "отпущена")")
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            Log.write("ПУЛЬТ: перехват не создался")
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.write("ПУЛЬТ: слушаю \(Int(seconds)) секунд, жми кнопки")

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            MediaProbe.tap = nil
            Log.write("ПУЛЬТ: закончил слушать")
        }
    }
}
