import Foundation

/// Клавиша, по которой идёт запись.
///
/// Список закрытый намеренно. Свободный захват «нажми любую клавишу» позволяет
/// назначить букву — и человек остаётся без клавиатуры, потому что каждое её
/// нажатие уходит в диктовку. Здесь только те клавиши, что в обычном наборе
/// не участвуют.
struct HotkeyOption: Identifiable, Hashable {
    let id: String
    let title: String
    /// Код клавиши в событиях CGEvent.
    let keyCode: Int64
    /// Бит в маске флагов — только у модификаторов. У обычных клавиш nil:
    /// они приходят не через flagsChanged, а через keyDown и keyUp.
    let flagMask: UInt64?
    let note: String

    var isModifier: Bool { flagMask != nil }

    static let all: [HotkeyOption] = [
        HotkeyOption(id: "rightOption", title: "Правый ⌥", keyCode: 61, flagMask: 0x0000_0040,
                     note: "По умолчанию. В наборе не участвует"),
        HotkeyOption(id: "rightCommand", title: "Правый ⌘", keyCode: 54, flagMask: 0x0000_0010,
                     note: "Свободен, если не пользуешься сочетаниями правой рукой"),
        HotkeyOption(id: "rightControl", title: "Правый ⌃", keyCode: 62, flagMask: 0x0000_2000,
                     note: "Свободен на большинстве клавиатур"),
        HotkeyOption(id: "rightShift", title: "Правый ⇧", keyCode: 60, flagMask: 0x0000_0004,
                     note: "Осторожно: им набирают заглавные"),
        HotkeyOption(id: "f13", title: "F13", keyCode: 105, flagMask: nil,
                     note: "Есть на полноразмерных клавиатурах"),
        HotkeyOption(id: "f14", title: "F14", keyCode: 107, flagMask: nil,
                     note: "Есть на полноразмерных клавиатурах"),
        HotkeyOption(id: "f15", title: "F15", keyCode: 113, flagMask: nil,
                     note: "Есть на полноразмерных клавиатурах"),
        HotkeyOption(id: "f16", title: "F16", keyCode: 106, flagMask: nil,
                     note: "Есть на полноразмерных клавиатурах")
    ]

    static let fallback = all[0]

    static func named(_ id: String) -> HotkeyOption {
        all.first { $0.id == id } ?? fallback
    }
}
