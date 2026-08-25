using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;

namespace Golos;

/// <summary>
/// Держит whisper-server поднятым всё время работы приложения.
/// Модель грузится секунды, поэтому дёргать её на каждую фразу нельзя.
/// Сборка с CUDA считает на видеокарте — на 3080 Ti это заметно быстрее.
/// </summary>
public sealed class Whisper : IDisposable
{
    private readonly Config config;
    private readonly int port;
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(180) };

    private readonly object gate = new();
    private Process? server;
    private bool ready;
    private string? lastError;
    private int generation;

    public Whisper(Config config)
    {
        this.config = config;
        port = config.Port;
    }

    public bool Ready { get { lock (gate) return ready; } }
    public string? LastError { get { lock (gate) return lastError; } }

    private void SetError(string? message) { lock (gate) lastError = message; }

    public async Task<bool> StartAsync()
    {
        int launchGeneration;
        lock (gate)
        {
            if (server != null) return true;
            launchGeneration = generation;
        }

        var engine = EngineCatalog.Locate(config);
        if (engine == null)
        {
            SetError("Движок распознавания не найден");
            return false;
        }
        if (string.IsNullOrEmpty(config.ModelPath) || !File.Exists(config.ModelPath))
        {
            SetError($"Модель не найдена: {config.ModelPath}");
            return false;
        }

        KillStrays();

        var args = new List<string>
        {
            "-m", Quote(config.ModelPath),
            "--port", port.ToString(),
            "--host", "127.0.0.1",
            "-t", config.Threads.ToString()
        };
        if (config.Language != "auto") { args.Add("-l"); args.Add(config.Language); }
        if (!string.IsNullOrEmpty(config.VadModelPath) && File.Exists(config.VadModelPath))
        {
            args.Add("--vad"); args.Add("-vm"); args.Add(Quote(config.VadModelPath));
        }

        var info = new ProcessStartInfo
        {
            FileName = engine,
            Arguments = string.Join(" ", args),
            // Рабочая папка — рядом с exe: там лежат DLL от CUDA.
            WorkingDirectory = Path.GetDirectoryName(engine)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        Process process;
        try
        {
            process = Process.Start(info)!;
            // Потоки надо вычитывать, иначе буфер переполнится и сервер встанет.
            process.OutputDataReceived += (_, _) => { };
            process.ErrorDataReceived += (_, _) => { };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        catch (Exception e)
        {
            SetError(e.Message);
            return false;
        }

        lock (gate)
        {
            if (generation != launchGeneration)
            {
                try { process.Kill(true); } catch { }
                return false;
            }
            server = process;
        }

        // Ждём, пока модель прогрузится: сервер отвечает только после этого.
        var deadline = DateTime.UtcNow.AddSeconds(180);
        while (DateTime.UtcNow < deadline)
        {
            if (await PingAsync())
            {
                lock (gate)
                {
                    if (generation != launchGeneration) return false;
                    ready = true;
                    lastError = null;
                }
                return true;
            }
            if (process.HasExited) break;
            await Task.Delay(250);
        }

        SetError("Сервер распознавания не поднялся");
        return false;
    }

    private static string Quote(string path) => path.Contains(' ') ? $"\"{path}\"" : path;

    private async Task<bool> PingAsync()
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            var response = await http.GetAsync($"http://127.0.0.1:{port}/", cts.Token);
            return response != null;
        }
        catch { return false; }
    }

    /// <summary>
    /// Снимает серверы, оставшиеся от прошлого запуска: они держат порт
    /// и зря занимают память под модель.
    /// </summary>
    private static void KillStrays()
    {
        foreach (var stray in Process.GetProcessesByName("whisper-server"))
        {
            try { stray.Kill(true); stray.WaitForExit(3000); Log.Write("снят осиротевший whisper-server"); }
            catch { }
            finally { stray.Dispose(); }
        }
    }

    /// <summary>Отрезок распознанного текста с временем от начала записи.</summary>
    public sealed record Segment(double Start, double End, string Text, bool JoinsPreviousWord);

    /// <summary>Распознавание с тайм-кодами — для расшифровки файлов.</summary>
    public async Task<List<Segment>?> TranscribeSegmentsAsync(byte[] wav, string prompt)
    {
        var body = await RequestAsync(wav, prompt, verbose: true);
        if (body == null) return null;

        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("segments", out var array)) return new List<Segment>();

        var segments = new List<Segment>();
        foreach (var item in array.EnumerateArray())
        {
            if (!item.TryGetProperty("text", out var textNode)) continue;
            var raw = textNode.GetString() ?? "";
            var clean = raw.Trim();
            if (clean.Length == 0) continue;

            double start = item.TryGetProperty("start", out var s1) && s1.ValueKind == JsonValueKind.Number ? s1.GetDouble() : 0;
            double end = item.TryGetProperty("end", out var e1) && e1.ValueKind == JsonValueKind.Number ? e1.GetDouble() : 0;
            // Продолжение разорванного слова приходит без ведущего пробела.
            segments.Add(new Segment(start, end, clean, !raw.StartsWith(" ")));
        }
        return segments;
    }

    public async Task<string?> TranscribeAsync(byte[] wav, string prompt)
    {
        var body = await RequestAsync(wav, prompt, verbose: false);
        if (body == null) return null;
        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("text", out var textNode)) return null;
        return Clean(textNode.GetString() ?? "");
    }

    private async Task<string?> RequestAsync(byte[] wav, string prompt, bool verbose)
    {
        if (!Ready) { SetError("Распознавание ещё не готово"); return null; }

        using var content = new MultipartFormDataContent();
        var file = new ByteArrayContent(wav);
        file.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("audio/wav");
        content.Add(file, "file", "audio.wav");
        content.Add(new StringContent(verbose ? "verbose_json" : "json"), "response_format");
        content.Add(new StringContent("0"), "temperature");
        if (config.Language != "auto") content.Add(new StringContent(config.Language), "language");
        if (!string.IsNullOrEmpty(prompt)) content.Add(new StringContent(prompt), "prompt");

        try
        {
            var response = await http.PostAsync($"http://127.0.0.1:{port}/inference", content);
            var body = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
            {
                SetError($"Сервер ответил {(int)response.StatusCode}");
                Log.Write($"ошибка распознавания {(int)response.StatusCode}: {Trim(body)}");
                return null;
            }
            return body;
        }
        catch (Exception e)
        {
            SetError(e.Message);
            return null;
        }
    }

    private static string Trim(string s) => s.Length > 200 ? s[..200] : s;

    /// <summary>
    /// Сервер режет ответ по сегментам и вставляет переводы строк там, где
    /// в речи их не было; плюс whisper помечает тишину служебными скобками.
    /// </summary>
    /// <summary>
    /// Сервер кладёт каждый отрезок на свою строку, и переводы строк надо убрать:
    /// в речи их не было. Но менять их на пробел не глядя нельзя. Whisper рвёт
    /// слова пополам, и тогда «сотруд» и «ников» приходят разными строками:
    /// отрезок с ведущим пробелом начинает новое слово, отрезок без пробела
    /// продолжает предыдущее. Раньше строки обрезались до склейки, и признак
    /// терялся — каждая третья диктовка приезжала с разорванным словом.
    /// </summary>
    public static string Clean(string raw)
    {
        foreach (var marker in new[] { "[BLANK_AUDIO]", "[ Тишина ]", "(тишина)", "[Music]" })
            raw = raw.Replace(marker, "");

        var result = new System.Text.StringBuilder();
        foreach (var line in raw.Split('\n', '\r'))
        {
            var continuesWord = line.Length > 0 && line[0] != ' ' && line[0] != '\t';
            var piece = line.Trim();
            if (piece.Length == 0) continue;
            if (result.Length == 0) result.Append(piece);
            else if (continuesWord) result.Append(piece);
            else result.Append(' ').Append(piece);
        }

        return result.ToString().Replace("  ", " ").Trim();
    }

    public void Stop()
    {
        Process? process;
        lock (gate)
        {
            process = server;
            server = null;
            ready = false;
            generation++;
        }
        if (process == null) return;
        try { process.Kill(true); } catch { }
        process.Dispose();
    }

    public void Dispose()
    {
        Stop();
        http.Dispose();
    }
}
