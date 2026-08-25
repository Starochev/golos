using System.Text.Json;
using System.Text.Json.Serialization;

namespace Golos;

/// <summary>
/// Настройки в %USERPROFILE%\Documents\Golos\config.json.
/// Формат общий с версией для macOS — файл переносится между машинами как есть.
/// Перечитывается перед каждой диктовкой, поэтому правка словаря видна сразу.
/// </summary>
public sealed class Config
{
    public string Language { get; set; } = "ru";
    public string ModelPath { get; set; } = "";
    public string VadModelPath { get; set; } = "";
    public List<string> Vocabulary { get; set; } = new();
    public List<Replacement> Replacements { get; set; } = new();
    /// <summary>paste — буфер и Ctrl+V, clipboard — только положить в буфер.</summary>
    public string InsertMode { get; set; } = "paste";
    /// <summary>Клавиша записи: идентификатор из HotkeyOption.All.</summary>
    public string Hotkey { get; set; } = "rightOption";
    /// <summary>Цвет волны: идентификатор темы из WaveTheme.All либо custom.</summary>
    public string WaveTheme { get; set; } = "red";
    /// <summary>Свой цвет волны в виде #RRGGBB.</summary>
    public string CustomWaveColor { get; set; } = "#7CE0FF";
    /// <summary>Показывать окошко с живой волной во время записи.</summary>
    public bool ShowHUD { get; set; } = true;
    /// <summary>Набор тонов: soft, bell или quiet.</summary>
    public string SoundTheme { get; set; } = "soft";
    /// <summary>
    /// Имя микрофона. Пусто — то, что выбрано в системе.
    /// Хранится именно имя, а не номер: номера у звуковых устройств
    /// перетасовываются при каждом подключении гарнитуры.
    /// </summary>
    public string InputDevice { get; set; } = "";
    /// <summary>
    /// Своя папка с движком распознавания. Пусто значит искать самому:
    /// сборка под видеокарту, потом папка engine рядом с exe, потом встроенная.
    /// Ключ только для Windows, версия для macOS его не знает.
    /// </summary>
    public string EnginePath { get; set; } = "";
    /// <summary>
    /// Что делать со знаком в конце распознанной фразы:
    /// keep — оставить как распознано, period — убрать точку,
    /// any — убрать любой знак.
    /// </summary>
    public string FinalPunctuation { get; set; } = "keep";
    /// <summary>
    /// Собирать слова, в которых модель сомневалась, и предлагать их в словарь.
    /// Разбор идёт фоном, уже после вставки текста.
    /// </summary>
    public bool CollectCandidates { get; set; } = true;
    public int Port { get; set; } = 8178;
    public int Threads { get; set; } = 8;
    public bool Sounds { get; set; } = true;
    /// <summary>Куда класть расшифровки файлов. Пусто — рядом с исходником.</summary>
    public string FileOutputFolder { get; set; } = "";
    /// <summary>Оставлять ли рядом с расшифровкой переконвертированный wav.</summary>
    public bool KeepConvertedAudio { get; set; } = false;
    public bool KeepHistory { get; set; } = true;
    public int HistoryRetentionHours { get; set; } = 1;

    public sealed class Replacement
    {
        public string From { get; set; } = "";
        public string To { get; set; } = "";
        public bool IgnoreCase { get; set; } = true;
    }

    public static string Directory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Golos");

    public static string FilePath => Path.Combine(Directory, "config.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never
    };

    public static Config Load()
    {
        System.IO.Directory.CreateDirectory(Directory);

        if (File.Exists(FilePath))
        {
            try
            {
                var loaded = JsonSerializer.Deserialize<Config>(File.ReadAllText(FilePath), JsonOptions);
                if (loaded != null)
                {
                    if (string.IsNullOrEmpty(loaded.ModelPath)) loaded.ModelPath = FindModel() ?? "";
                    if (string.IsNullOrEmpty(loaded.VadModelPath)) loaded.VadModelPath = FindVad() ?? "";
                    return loaded;
                }
            }
            catch (Exception e)
            {
                // Файл есть, но разобрать не вышло. Не затираем молча: там мог
                // быть словарь, который человек набирал руками.
                var broken = Path.Combine(Directory, "config.broken.json");
                try { File.Copy(FilePath, broken, overwrite: true); } catch { }
                Log.Write($"конфиг не разобрался, копия в config.broken.json: {e.Message}");
            }
        }

        // Словарь и замены остаются пустыми намеренно. У каждого свои слова,
        // а чужой список только съедает лимит подсказки: место в нём считанное,
        // и занимать его словами, которые человек не произносит, вредно.
        var config = new Config
        {
            ModelPath = FindModel() ?? "",
            VadModelPath = FindVad() ?? ""
        };
        config.Save();
        return config;
    }

    public void Save()
    {
        System.IO.Directory.CreateDirectory(Directory);
        var temp = FilePath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(this, JsonOptions));
        File.Move(temp, FilePath, overwrite: true);
    }

    /// <summary>Потолок подсказки whisper — 224 токена, это примерно 600 символов.</summary>
    public const int PromptCharacterBudget = 600;

    /// <summary>Строка словаря для initial prompt, обрезанная по лимиту модели.</summary>
    public string PromptString()
    {
        if (Vocabulary.Count == 0) return "";

        var kept = new List<string>();
        var length = 0;
        var dropped = 0;
        foreach (var term in Vocabulary)
        {
            var addition = term.Length + 2;
            if (length + addition > PromptCharacterBudget) { dropped++; continue; }
            kept.Add(term);
            length += addition;
        }
        if (dropped > 0) Log.Write($"словарь длиннее лимита whisper: {dropped} терминов не вошло");
        return string.Join(", ", kept) + ".";
    }

    /// <summary>
    /// Срезает знак в конце фразы, если так просили в настройках.
    ///
    /// Знаки препинания ставит сама модель, отдельной ручки у неё нет.
    /// Единственное, что можно сделать снаружи, это убрать лишнее с конца.
    /// Многоточие не трогаем: откусить от него одну точку хуже, чем оставить.
    /// </summary>
    public string ApplyFinalPunctuation(string text)
    {
        switch (FinalPunctuation)
        {
            case "period":
                if (!text.EndsWith(".") || text.EndsWith("..")) return text;
                return text[..^1];
            case "any":
                var result = text;
                while (result.Length > 0 && ".,!?;:".Contains(result[^1]))
                    result = result[..^1];
                return result.Length == 0 ? text : result;
            default:
                return text;
        }
    }

    public string ApplyReplacements(string text)
    {
        foreach (var r in Replacements)
        {
            if (string.IsNullOrEmpty(r.From)) continue;
            text = text.Replace(r.From, r.To,
                r.IgnoreCase ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
        }
        return text;
    }

    private static string? FindModel()
    {
        foreach (var name in new[] { "ggml-large-v3.bin", "ggml-large-v3-turbo.bin", "ggml-medium.bin", "ggml-small.bin" })
        {
            foreach (var dir in ModelDirectories())
            {
                var path = Path.Combine(dir, name);
                if (File.Exists(path)) return path;
            }
        }
        return null;
    }

    private static string? FindVad()
    {
        foreach (var dir in ModelDirectories())
        {
            foreach (var name in new[] { "ggml-silero-v5.1.2.bin", "ggml-silero-v6.2.0.bin" })
            {
                var path = Path.Combine(dir, name);
                if (File.Exists(path)) return path;
            }
        }
        return null;
    }

    private static IEnumerable<string> ModelDirectories()
    {
        yield return Path.Combine(AppContext.BaseDirectory, "models");
        yield return Path.Combine(Directory, "models");
        yield return @"D:\Golos\models";
    }
}
