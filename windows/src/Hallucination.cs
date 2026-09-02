using System.Text;

namespace Golos;

/// <summary>
/// Ловит выдумки распознавания.
///
/// На неудачном декодировании whisper выдаёт частую фразу из обучающих
/// данных — модель училась на субтитрах, и оттуда лезут концовки роликов:
/// «Всем пока!», «Спасибо за просмотр!», «Субтитры сделал DimaTorzok».
/// Звук при этом нормальный: тот же файл со второй попытки распознаётся верно.
/// </summary>
public static class Hallucination
{
    /// <summary>
    /// Подписи из субтитровых файлов. Такое не диктуют вовсе, поэтому
    /// длина и плотность значения не имеют — это выдумка всегда.
    /// </summary>
    private static readonly string[] AlwaysInvented =
    {
        "субтитры сделал",
        "субтитры делал",
        "субтитры создавал",
        "редактор субтитров",
        "корректор а егорова",
        "dimatorzok",
        "subtitles by the amara"
    };

    /// <summary>
    /// Ядра фраз, которые человек мог сказать и сам. Здесь решает плотность.
    ///
    /// Ищем вхождение, а не совпадение целиком: модель приделывает к ним
    /// приставки. Первая версия проверяла точное равенство и пропустила
    /// «Всем спасибо за просмотр!» — в списке было «спасибо за просмотр».
    /// </summary>
    private static readonly string[] SuspiciousCores =
    {
        "всем пока",
        "всем привет",
        "привет всем",
        "всем здравствуйте",
        "добрый день",
        "добрый вечер",
        "спасибо за просмотр",
        "спасибо за внимание",
        "продолжение следует",
        "продолжение в следующем видео",
        "подписывайтесь на канал",
        "ставьте лайки",
        "до новых встреч",
        "thanks for watching",
        "thank you for watching",
        "please subscribe"
    };

    /// <summary>Короче этого фраза могла быть сказана всерьёз.</summary>
    private const double MinimumSeconds = 1.5;

    /// <summary>
    /// Знаков в секунду, ниже которых текст явно не покрывает записанное.
    /// Обычная речь идёт около десяти знаков в секунду — замерено по полусотне
    /// живых записей. Выдумка даёт полтора.
    /// </summary>
    private const double MinimumDensity = 4.0;

    public static string Normalize(string text)
    {
        var builder = new StringBuilder(text.Length);
        var lastWasSpace = true;
        foreach (var raw in text.ToLowerInvariant())
        {
            var c = raw == 'ё' ? 'е' : raw;
            if (char.IsLetterOrDigit(c))
            {
                builder.Append(c);
                lastWasSpace = false;
            }
            else if (!lastWasSpace)
            {
                builder.Append(' ');
                lastWasSpace = true;
            }
        }
        return builder.ToString().Trim();
    }

    /// <summary>
    /// Похоже ли, что модель выдумала это вместо реальной речи.
    ///
    /// Одного совпадения с заученной фразой мало: «Спасибо за просмотр этого
    /// макета» человек мог сказать сам. Решает плотность — сколько знаков
    /// приходится на секунду записи.
    /// </summary>
    /// <summary>
    /// Короче этого низкая плотность ни о чём не говорит: за две секунды
    /// человек успевает сказать «Да», и это ответ, а не потеря.
    /// </summary>
    private const double ThinMinimumSeconds = 2.5;

    /// <summary>
    /// Текста заметно меньше, чем было речи, что бы в нём ни было написано.
    ///
    /// Отдельно от LooksInvented, потому что там плотность проверяется только
    /// у знакомых заученных фраз, а модель выдумывает и незнакомые.
    /// Порог замерен по истории диктовок: медиана 11,2 знака в секунду,
    /// ниже четырёх оказались единицы, и все были недобраны.
    /// </summary>
    public static bool LooksThin(string text, double audioSeconds)
    {
        if (audioSeconds < ThinMinimumSeconds) return false;
        return text.Length / audioSeconds < MinimumDensity;
    }

    /// <summary>
    /// Чужая письменность: иероглифы, кана, хангыль, арабица. Для диктовки
    /// на русском это верный признак сорвавшегося декодера, а не речи:
    /// произнести иероглиф голосом нельзя.
    /// </summary>
    public static bool ContainsForeignScript(string text)
    {
        foreach (var ch in text)
        {
            var c = (int)ch;
            if ((c >= 0x0590 && c <= 0x05FF) ||   // иврит
                (c >= 0x0600 && c <= 0x06FF) ||   // арабица
                (c >= 0x0900 && c <= 0x097F) ||   // деванагари
                (c >= 0x0E00 && c <= 0x0E7F) ||   // тайская
                (c >= 0x1100 && c <= 0x11FF) ||   // хангыль, чамо
                (c >= 0x3040 && c <= 0x30FF) ||   // хирагана и катакана
                (c >= 0x3400 && c <= 0x4DBF) ||   // иероглифы, расширение A
                (c >= 0x4E00 && c <= 0x9FFF) ||   // иероглифы
                (c >= 0xAC00 && c <= 0xD7AF))     // хангыль, слоги
                return true;
        }
        return false;
    }

    /// <summary>Языки, для которых проверка на чужую письменность бессмысленна.</summary>
    public static readonly HashSet<string> ScriptExempt =
        new(StringComparer.OrdinalIgnoreCase) { "ja", "zh", "ko", "ar", "he", "th", "hi", "auto" };

    public static bool LooksInvented(string text, double audioSeconds)
    {
        var normalized = Normalize(text);

        if (AlwaysInvented.Any(core => normalized.Contains(core))) return true;

        if (audioSeconds < MinimumSeconds) return false;
        if (!SuspiciousCores.Any(core => normalized.Contains(core))) return false;

        return text.Length / audioSeconds < MinimumDensity;
    }

    /// <summary>Длительность записи по размеру WAV: 16 кГц, 16 бит, моно.</summary>
    public static double WavSeconds(byte[] wav) => Math.Max(0, (wav.Length - 44) / (16000.0 * 2));

    /// <summary>
    /// Заученные концовки. Проверяются только как хвост: «Всем привет»
    /// в начале речи законно, а после двадцати секунд диктовки — уже нет.
    /// </summary>
    private static readonly string[] TrailingPhrases =
    {
        "всем пока",
        "всем привет",
        "всем спасибо за просмотр",
        "спасибо за просмотр",
        "спасибо за внимание",
        "продолжение следует",
        "подписывайтесь на канал",
        "ставьте лайки",
        "до новых встреч",
        "субтитры сделал dimatorzok",
        "субтитры сделал",
        "редактор субтитров",
        "thanks for watching",
        "please subscribe"
    };

    /// <summary>Столько слов должно остаться, чтобы отсечение имело смысл.</summary>
    private const int MinimumRemainderWords = 3;
    /// <summary>Дальше по словам вглубь хвост не ищем.</summary>
    private const int MaxTailWords = 6;

    /// <summary>
    /// Срезает заученную фразу, приклеенную в конец правильного текста.
    ///
    /// Второй способ, которым лезут субтитры: основной текст распознан верно,
    /// а в хвост добавляется концовка ролика. Плотность всего текста при этом
    /// нормальная, и проверка по нему такое не видит.
    ///
    /// Ищем по словам, а не по предложениям: разделителя перед выдумкой может
    /// не быть вовсе — «Как-то можно сделать, чтобы Спасибо за просмотр!».
    /// </summary>
    public static string StripTrailingInvention(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();

        while (true)
        {
            var cut = 0;
            for (var tailCount = 1; tailCount <= MaxTailWords; tailCount++)
            {
                if (words.Count - tailCount < MinimumRemainderWords) break;
                var tail = string.Join(" ", words.Skip(words.Count - tailCount));
                if (TrailingPhrases.Contains(Normalize(tail))) cut = tailCount;
            }
            if (cut == 0) break;

            Log.Write($"срезал приклеенное в конец: «{string.Join(" ", words.Skip(words.Count - cut))}»");
            words.RemoveRange(words.Count - cut, cut);
        }

        return string.Join(" ", words);
    }

    // MARK: Зацикливание

    /// <summary>Сколько повторов подряд считаем сбоем, а не речью.</summary>
    private const int MinimumRepeats = 3;
    /// <summary>Какую долю текста должен занимать повтор, чтобы признать выдумкой.</summary>
    private const double DegenerateShare = 0.7;
    /// <summary>Длина повторяющейся группы, которую ищем.</summary>
    private const int MaxRepeatGroup = 4;

    /// <summary>
    /// Весь ли текст — это одно зациклившееся место.
    ///
    /// Whisper иногда срывается в повтор: шесть секунд речи дают «Ссылка на
    /// сайт» пять раз подряд и больше ничего. Отличаем от живой речи по доле:
    /// когда человек сам повторяет фразу, вокруг остаётся другой текст.
    /// </summary>
    public static bool LooksDegenerate(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length < 4) return false;

        var (count, size) = LongestRun(words);
        if (count < MinimumRepeats) return false;
        return (double)(count * size) / words.Length >= DegenerateShare;
    }

    /// <summary>
    /// Схлопывает повтор, если он прилип к концу правильного текста.
    /// Только к концу: в середине повтор обычно настоящий — человек
    /// пересказывает, что ему выдало приложение.
    /// </summary>
    public static string CollapseTrailingRepeats(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();

        for (var size = MaxRepeatGroup; size >= 1; size--)
        {
            if (words.Count < size * MinimumRepeats) continue;

            var repeats = 1;
            var start = words.Count - size;
            while (start - size >= 0 && Group(words, start - size, size) == Group(words, start, size))
            {
                repeats++;
                start -= size;
            }

            if (repeats >= MinimumRepeats)
            {
                var removed = (repeats - 1) * size;
                Log.Write($"схлопнул повтор в конце: «{string.Join(" ", words.Skip(words.Count - removed))}»");
                words.RemoveRange(words.Count - removed, removed);
                return string.Join(" ", words);
            }
        }
        return text;
    }

    /// <summary>Самый длинный ряд одинаковых групп: сколько повторов и какой длины.</summary>
    private static (int Count, int Size) LongestRun(string[] words)
    {
        var best = (Count: 0, Size: 0);
        for (var size = 1; size <= MaxRepeatGroup; size++)
        {
            for (var index = 0; index + size * 2 <= words.Length; index++)
            {
                var repeats = 1;
                while (index + size * (repeats + 1) <= words.Length
                       && Group(words, index, size) == Group(words, index + size * repeats, size))
                {
                    repeats++;
                }
                if (repeats * size > best.Count * best.Size) best = (repeats, size);
            }
        }
        return best;
    }

    private static string Group(IReadOnlyList<string> words, int start, int size) =>
        Normalize(string.Join(" ", words.Skip(start).Take(size)));

    // MARK: Начало куска

    /// <summary>
    /// Приветствия, которыми декодер «разогревается» на старте отрезка.
    /// Проверяются только у кусков со второго: в начале самой диктовки
    /// приветствие законно, а в середине разрезанной фразы — нет.
    /// </summary>
    private static readonly string[] LeadingPhrases =
    {
        "всем привет",
        "привет всем",
        "всем здравствуйте",
        "здравствуйте всем",
        "добрый день",
        "добрый вечер",
        "спасибо за просмотр",
        "продолжение следует",
        "субтитры сделал",
        "редактор субтитров"
    };

    private const int MinimumAfterLeading = 4;
    private const int MaxLeadingWords = 4;

    /// <summary>
    /// Срезает приветствие, приклеенное в начало куска.
    /// Применять только к кускам со второго — иначе съест законное
    /// приветствие в начале речи.
    /// </summary>
    public static string StripLeadingInvention(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();

        while (true)
        {
            var cut = 0;
            for (var headCount = 1; headCount <= MaxLeadingWords; headCount++)
            {
                if (words.Count - headCount < MinimumAfterLeading) break;
                var head = string.Join(" ", words.Take(headCount));
                if (LeadingPhrases.Contains(Normalize(head))) cut = headCount;
            }
            if (cut == 0) break;

            Log.Write($"срезал приклеенное в начало: «{string.Join(" ", words.Take(cut))}»");
            words.RemoveRange(0, cut);
        }

        return string.Join(" ", words);
    }
}
