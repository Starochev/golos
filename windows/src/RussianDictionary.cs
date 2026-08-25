using System.Runtime.InteropServices;

namespace Golos;

/// <summary>
/// Системный словарь русского языка, тот же, что подчёркивает опечатки
/// в полях ввода. Нужен как решето: слово, которое словарь знает, кандидатом
/// в наш словарь не будет.
///
/// Без него список кандидатов бесполезен: слов с низкой уверенностью набегает
/// около 630 в час диктовки, и почти все они обычные русские, сказанные
/// быстро. Словарь оставляет от них единицы.
///
/// Если проверки русского в системе нет (не поставлен языковой пакет),
/// решето выключается целиком, а отбор идёт по повтору: спрашиваем только
/// про слова, споткнувшиеся дважды.
/// </summary>
public static class RussianDictionary
{
    private static readonly object Gate = new();
    private static ISpellChecker? checker;
    private static bool tried;

    /// <summary>Работает ли проверка. Если нет, отбор идёт по повтору.</summary>
    public static bool Available
    {
        get { Ensure(); return checker != null; }
    }

    public static bool Knows(string word)
    {
        Ensure();
        var current = checker;
        if (current == null || word.Length == 0) return false;
        try
        {
            var errors = current.Check(word);
            // Next возвращает S_OK, только если ошибка нашлась.
            return errors.Next(out _) != 0;
        }
        catch { return false; }
    }

    private static void Ensure()
    {
        lock (Gate)
        {
            if (tried) return;
            tried = true;
            try
            {
                var type = Type.GetTypeFromCLSID(new Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC"));
                if (type == null) return;
                var factory = (ISpellCheckerFactory?)Activator.CreateInstance(type);
                if (factory == null) return;
                if (factory.IsSupported("ru-RU") == 0)
                {
                    Log.Write("проверки русского в системе нет, кандидаты отбираются по повтору");
                    return;
                }
                checker = factory.CreateSpellChecker("ru-RU");
            }
            catch (Exception e)
            {
                Log.Write($"словарь русского недоступен: {e.Message}");
            }
        }
    }
}

[ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ISpellCheckerFactory
{
    // Порядок методов обязан совпадать с таблицей COM, поэтому неиспользуемые
    // всё равно объявлены.
    void GetSupportedLanguages_Unused();
    int IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
    [return: MarshalAs(UnmanagedType.Interface)]
    ISpellChecker CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
}

[ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ISpellChecker
{
    void get_LanguageTag_Unused();
    [return: MarshalAs(UnmanagedType.Interface)]
    IEnumSpellingError Check([MarshalAs(UnmanagedType.LPWStr)] string text);
}

[ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IEnumSpellingError
{
    [PreserveSig]
    int Next([MarshalAs(UnmanagedType.Interface)] out object? value);
}
