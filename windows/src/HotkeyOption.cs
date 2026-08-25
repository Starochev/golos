namespace Golos;

/// <summary>
/// Клавиша, по которой идёт запись.
///
/// Список закрытый намеренно. Свободный захват «нажми любую клавишу» позволяет
/// назначить букву — и человек остаётся без клавиатуры, потому что каждое её
/// нажатие уходит в диктовку.
///
/// Идентификаторы общие с версией для macOS: там правый Alt называется
/// правым Option, но это одна и та же физическая клавиша, и конфиг должен
/// переноситься между машинами без правок.
/// </summary>
public sealed record HotkeyOption(string Id, string Title, int VirtualKey, string Note)
{
    public static readonly HotkeyOption[] All =
    {
        new("rightOption",  "Правый Alt",     0xA5, "По умолчанию. В наборе не участвует"),
        new("rightCommand", "Правый Windows", 0x5C, "Свободен, если не пользуешься меню «Пуск» с клавиатуры"),
        new("rightControl", "Правый Ctrl",    0xA3, "Свободен на большинстве клавиатур"),
        new("rightShift",   "Правый Shift",   0xA1, "Осторожно: им набирают заглавные"),
        new("f13",          "F13",            0x7C, "Есть на полноразмерных клавиатурах"),
        new("f14",          "F14",            0x7D, "Есть на полноразмерных клавиатурах"),
        new("f15",          "F15",            0x7E, "Есть на полноразмерных клавиатурах"),
        new("f16",          "F16",            0x7F, "Есть на полноразмерных клавиатурах")
    };

    public static HotkeyOption Fallback => All[0];

    public static HotkeyOption Named(string id) =>
        All.FirstOrDefault(o => o.Id == id) ?? Fallback;

    /// <summary>
    /// Модификаторы проглатываем: одиночное нажатие Alt или Windows отдаёт
    /// фокус меню, а Shift и Ctrl сами по себе ничего не делают, но их
    /// сочетания ломать нельзя — поэтому глотаем только когда клавиша
    /// нажата одна.
    /// </summary>
    public bool IsModifier => VirtualKey is 0xA5 or 0x5C or 0xA3 or 0xA1;
}
