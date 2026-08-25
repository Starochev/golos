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
    /// Код кнопки пульта. У кнопок на проводе гарнитуры и у медиаклавиш
    /// клавиатуры своя дорога: системное событие типа 14, а не клавиатурное.
    let mediaCode: Int?
    let note: String

    var isModifier: Bool { flagMask != nil }
    var isMedia: Bool { mediaCode != nil }

    init(id: String, title: String, keyCode: Int64 = 0, flagMask: UInt64? = nil,
         mediaCode: Int? = nil, note: String) {
        self.id = id
        self.title = title
        self.keyCode = keyCode
        self.flagMask = flagMask
        self.mediaCode = mediaCode
        self.note = note
    }

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
                     note: "Есть на полноразмерных клавиатурах"),
        // Кнопки на проводе гарнитуры. Проверено: каждая шлёт отдельные
        // нажатие и отпускание, удержание в три секунды доходит целиком.
        // Центральная кнопка есть в списке, но она хуже боковых: система
        // раздаёт play/pause плеерам своим механизмом, мимо перехвата,
        // и нажатие заодно запускает видео в браузере. Проверено.
        HotkeyOption(id: "mediaPlay", title: "Центральная кнопка гарнитуры",
                     mediaCode: 16,
                     note: "Заодно нажимает play в браузере: эту кнопку система отдаёт плееру мимо нас"),
        HotkeyOption(id: "mediaVolumeUp", title: "Громче на гарнитуре",
                     mediaCode: 0,
                     note: "Лучший выбор для гарнитуры. Нажал — пишет, нажал ещё раз — готово, громкость не трогает"),
        HotkeyOption(id: "mediaVolumeDown", title: "Тише на гарнитуре",
                     mediaCode: 1,
                     note: "Кнопка «тише». Нажатием включает и выключает, громкость не меняет")
    ]

    static let fallback = all[0]

    static func named(_ id: String) -> HotkeyOption {
        all.first { $0.id == id } ?? fallback
    }
}
