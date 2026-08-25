using System.Text.Json;
using System.Text.Json.Serialization;

namespace Golos;

/// <summary>Слово, в котором модель сомневалась. Кандидат в словарь.</summary>
public sealed class Candidate
{
    /// <summary>Как модель его написала: «бэкап», хотя сказано было backup.</summary>
    public string Word { get; set; } = "";
    /// <summary>Сколько раз спотыкалась.</summary>
    public int Hits { get; set; }
    /// <summary>Худшая уверенность из всех встреч, от 0 до 1.</summary>
    public double Worst { get; set; } = 1;
    /// <summary>Фраза, в которой встретилось: без неё через день не вспомнить.</summary>
    public string Context { get; set; } = "";
    public DateTime FirstSeen { get; set; }
    public DateTime LastSeen { get; set; }
}

/// <summary>
/// Копилка сомнительных слов.
///
/// Главная трудность в том, чтобы не показывать всё подряд. Слов с уверенностью
/// ниже 0,8 набегает около 630 в час диктовки, и почти все это обычные русские
/// слова, сказанные быстро. Отсекает их системный словарь русского языка:
/// из 91 собранного слова незнакомыми ему оказались 11, и это ровно то,
/// что нужно — «ретаргет», «ПВА-приложение», «рекомендацион», «Type-C».
///
/// Файл общий с версией для macOS и переносится между машинами как есть.
/// </summary>
public sealed class Candidates
{
    public const double Threshold = 0.8;
    /// <summary>Сколько живёт кандидат, о котором не приняли решения.</summary>
    public const double LifetimeDays = 7;
    /// <summary>Сколько молчит слово, по которому решение принято.</summary>
    public const double SettledLifetimeDays = 90;
    private const int MinimumLength = 4;

    /// <summary>
    /// Со словарём хватает одной встречи: он отсеивает столько, что требовать
    /// повтора незачем. Без словаря повтор остаётся единственным решетом.
    /// </summary>
    private static int MinimumHits => RussianDictionary.Available ? 1 : 2;

    /// <summary>Служебные слова: спотыкаются постоянно, а в словаре не нужны.</summary>
    private static readonly HashSet<string> StopWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "это", "если", "можно", "надо", "нужно", "просто", "который", "которая",
        "которую", "которые", "потому", "поэтому", "тогда", "сейчас", "здесь",
        "туда", "сюда", "может", "будет", "было", "были", "есть", "чтобы",
        "когда", "пока", "уже", "ещё", "еще", "там", "тут", "все", "всё",
        "самый", "самое", "самой", "себя", "него", "неё", "нее", "них",
        "сказал", "сказала", "давай", "давайте", "допустим", "предположим",
        "вообще", "конечно", "наверное", "например", "также", "такой", "такое"
    };

    private static string FilePath => Path.Combine(Config.Directory, "candidates.json");

    private Dictionary<string, Candidate> seen = new();
    private Dictionary<string, DateTime> settled = new();

    public Candidates() => Load();

    /// <summary>Кандидаты, о которых стоит спросить, худшие сверху.</summary>
    public List<Candidate> Pending => seen.Values
        .Where(c => c.Hits >= MinimumHits)
        .OrderBy(c => c.Worst)
        .ToList();

    public void Record(IEnumerable<Whisper.WordConfidence> words)
    {
        var now = DateTime.UtcNow;
        var changed = false;

        foreach (var item in words)
        {
            if (item.Probability >= Threshold) continue;
            var key = Key(item.Word);
            if (key.Length < MinimumLength) continue;
            if (StopWords.Contains(key)) continue;
            if (!key.Any(char.IsLetter)) continue;
            if (settled.ContainsKey(key)) continue;
            if (RussianDictionary.Knows(key)) continue;

            if (seen.TryGetValue(key, out var existing))
            {
                if (item.Probability < existing.Worst)
                {
                    // Написание берём от самой неуверенной встречи: там ошибка виднее.
                    existing.Worst = item.Probability;
                    existing.Word = item.Word;
                }
                existing.Hits++;
                existing.Context = item.Context;
                existing.LastSeen = now;
            }
            else
            {
                seen[key] = new Candidate
                {
                    Word = item.Word, Hits = 1, Worst = item.Probability,
                    Context = item.Context, FirstSeen = now, LastSeen = now
                };
            }
            changed = true;
        }

        if (changed) PurgeAndSave();
    }

    /// <summary>«Всё верно»: слово распознано правильно, вопрос закрыт.</summary>
    public void MarkCorrect(Candidate candidate) => Settle(candidate);

    /// <summary>Слово ушло в словарь, спрашивать о нём больше не надо.</summary>
    public void Accepted(Candidate candidate) => Settle(candidate);

    /// <summary>«Скрыть»: вернётся, когда распознавание споткнётся снова.</summary>
    public void Dismiss(Candidate candidate)
    {
        seen.Remove(Key(candidate.Word));
        PurgeAndSave();
    }

    public void ForgetAll()
    {
        seen.Clear();
        PurgeAndSave();
    }

    private void Settle(Candidate candidate)
    {
        var key = Key(candidate.Word);
        settled[key] = DateTime.UtcNow;
        seen.Remove(key);
        PurgeAndSave();
    }

    private sealed class Storage
    {
        [JsonPropertyName("seen")] public Dictionary<string, Candidate> Seen { get; set; } = new();
        /// <summary>Имя ключа общее с macOS, поэтому «ignored», а не «settled».</summary>
        [JsonPropertyName("ignored")] public Dictionary<string, DateTime> Ignored { get; set; } = new();
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private void Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return;
            var storage = JsonSerializer.Deserialize<Storage>(File.ReadAllText(FilePath), JsonOptions);
            if (storage == null) return;
            seen = storage.Seen;
            settled = storage.Ignored;
            PurgeAndSave();
        }
        catch (Exception e) { Log.Write($"копилка кандидатов не прочиталась: {e.Message}"); }
    }

    private void PurgeAndSave()
    {
        var now = DateTime.UtcNow;
        seen = seen.Where(p => (now - p.Value.LastSeen).TotalDays < LifetimeDays)
                   .ToDictionary(p => p.Key, p => p.Value);
        settled = settled.Where(p => (now - p.Value).TotalDays < SettledLifetimeDays)
                         .ToDictionary(p => p.Key, p => p.Value);
        try
        {
            System.IO.Directory.CreateDirectory(Config.Directory);
            var storage = new Storage { Seen = seen, Ignored = settled };
            File.WriteAllText(FilePath, JsonSerializer.Serialize(storage, JsonOptions));
        }
        catch (Exception e) { Log.Write($"копилка кандидатов не записалась: {e.Message}"); }
    }

    /// <summary>Ключ для сравнения: регистр и пунктуация не важны.</summary>
    public static string Key(string word)
    {
        var trimmed = word.Trim();
        var start = 0;
        var end = trimmed.Length;
        while (start < end && !char.IsLetterOrDigit(trimmed[start])) start++;
        while (end > start && !char.IsLetterOrDigit(trimmed[end - 1])) end--;
        return trimmed[start..end].ToLowerInvariant();
    }
}
