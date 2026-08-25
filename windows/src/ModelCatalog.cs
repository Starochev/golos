namespace Golos;

/// <summary>Модель распознавания для окна выбора.</summary>
public sealed record ModelInfo(
    string Id, string Title, long SizeBytes, string SpeedNote,
    string[] Pros, string[] Cons, bool Recommended)
{
    public string FileName => $"ggml-{Id}.bin";

    public string Url => $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{FileName}";

    public string SizeText => SizeBytes < 1_073_741_824
        ? $"{SizeBytes / 1_048_576:F0} МБ"
        : $"{SizeBytes / 1_073_741_824.0:F1} ГБ";
}

public static class ModelCatalog
{
    /// Размеры сверены с HuggingFace, скорость — замеры на 3080 Ti.
    public static readonly ModelInfo[] All =
    {
        new("large-v3", "Large v3", 3_094_623_691, "около 0.8 секунды на 10 секунд речи",
            new[]
            {
                "Лучшее качество русского из доступных",
                "Англицизмы почти всегда пишет латиницей, а не транслитом",
                "На видеокарте всё равно быстрая"
            },
            new[] { "Занимает почти 3 ГБ на диске", "Держит около 3 ГБ видеопамяти" },
            true),
        new("large-v3-turbo", "Large v3 Turbo", 1_624_555_275, "около 0.3 секунды",
            new[] { "Втрое быстрее большой модели", "Вдвое меньше места и памяти" },
            new[] { "Чаще мажет по редким именам и терминам", "Словарь замен понадобится длиннее" },
            false),
        new("medium", "Medium", 1_533_763_059, "около 0.6 секунды",
            new[] { "Умеренный расход памяти" },
            new[]
            {
                "Русский заметно слабее большой модели",
                "Англицизмы регулярно уходят в транслит",
                "При этом не быстрее turbo — смысла мало"
            },
            false),
        new("small", "Small", 487_601_967, "около 0.2 секунды",
            new[] { "Меньше полугигабайта", "Годится, когда важнее место, а не точность" },
            new[] { "Для русского с англицизмами слабовата", "Правок руками будет много" },
            false)
    };

    public static ModelInfo Recommended => All.First(m => m.Recommended);

    public const string VadFileName = "ggml-silero-v5.1.2.bin";
    public const string VadUrl = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/" + VadFileName;

    /// <summary>Модели живут рядом с движком, а не в документах: это кеш на гигабайты.</summary>
    public static string Directory
    {
        get
        {
            var beside = Path.Combine(AppContext.BaseDirectory, "models");
            if (System.IO.Directory.Exists(beside)) return beside;
            return Path.Combine(Config.Directory, "models");
        }
    }

    public static string LocalPath(ModelInfo model) => Path.Combine(Directory, model.FileName);

    public static bool IsInstalled(ModelInfo model) => File.Exists(LocalPath(model));
}

/// <summary>Качает модель с прогрессом.</summary>
public sealed class ModelDownloader
{
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromHours(2) };
    private CancellationTokenSource? cancellation;

    public void Cancel() => cancellation?.Cancel();

    /// <summary>Возвращает текст ошибки или null при успехе.</summary>
    public async Task<string?> DownloadAsync(string url, string destination,
                                             Action<long, long> onProgress)
    {
        cancellation = new CancellationTokenSource();
        var token = cancellation.Token;
        // Качаем во временный файл: иначе оборванная закачка остаётся под
        // именем модели и выглядит как готовая.
        var temp = destination + ".part";

        try
        {
            System.IO.Directory.CreateDirectory(Path.GetDirectoryName(destination)!);

            using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, token);
            if (!response.IsSuccessStatusCode)
                return $"Сервер ответил {(int)response.StatusCode} вместо файла модели";

            var total = response.Content.Headers.ContentLength ?? 0;
            await using (var source = await response.Content.ReadAsStreamAsync(token))
            await using (var file = File.Create(temp))
            {
                var buffer = new byte[1 << 20];
                long received = 0;
                int read;
                while ((read = await source.ReadAsync(buffer, token)) > 0)
                {
                    await file.WriteAsync(buffer.AsMemory(0, read), token);
                    received += read;
                    onProgress(received, total);
                }
            }

            var size = new FileInfo(temp).Length;
            // Самая маленькая модель — 450 МБ, детектор речи — 800 КБ.
            // Меньше сотни килобайт — это страница с ошибкой, а не модель.
            if (size < 100_000)
            {
                File.Delete(temp);
                return $"Скачалось всего {size} байт — это не модель";
            }

            File.Move(temp, destination, overwrite: true);
            return null;
        }
        catch (OperationCanceledException)
        {
            TryDelete(temp);
            return null;
        }
        catch (Exception e)
        {
            TryDelete(temp);
            return e.Message;
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
