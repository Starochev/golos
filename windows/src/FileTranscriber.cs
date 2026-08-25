namespace Golos;

/// <summary>
/// Расшифровка готового файла: встречи, созвона, записи экрана.
///
/// Отличие от диктовки в том, что результат нужен с тайм-кодами и ложится
/// на диск. Всё остальное — нарезка на куски, переспрос без словаря, чистка
/// выдумок — то же самое.
/// </summary>
public sealed class FileTranscriber
{
    public enum Stage { Reading, Recognizing, Writing }

    public sealed record Result(string TextFile, string SubtitleFile, string? AudioFile,
                                int Segments, double Duration);

    private readonly Whisper whisper;
    private volatile bool cancelled;

    public FileTranscriber(Whisper whisper) => this.whisper = whisper;

    public void Cancel() => cancelled = true;

    public async Task<Result> TranscribeAsync(string path, Config config,
                                              Action<Stage, double> onProgress)
    {
        cancelled = false;
        onProgress(Stage.Reading, 0);

        var wav = await Task.Run(() => MediaDecoder.Decode(path, f => onProgress(Stage.Reading, f)));

        var chunks = AudioSplit.ChunksWithOffsets(wav);
        Log.Write($"расшифровка файла «{Path.GetFileName(path)}»: кусков {chunks.Count}");

        var segments = new List<Whisper.Segment>();
        for (var i = 0; i < chunks.Count; i++)
        {
            if (cancelled) throw new OperationCanceledException();
            onProgress(Stage.Recognizing, (double)i / chunks.Count);
            segments.AddRange(await AskChunkAsync(chunks[i], config.PromptString()));
        }

        onProgress(Stage.Writing, 1);
        return Write(segments, wav, path, config);
    }

    /// <summary>
    /// Один кусок с теми же защитами, что и диктовка: заученная фраза,
    /// зацикливание и пустота лечатся переспросом без словаря.
    /// </summary>
    private async Task<List<Whisper.Segment>> AskChunkAsync(AudioSplit.Chunk chunk, string prompt)
    {
        var raw = await whisper.TranscribeSegmentsAsync(chunk.Wav, prompt);
        var joined = raw == null ? "" : string.Join(" ", raw.Select(s => s.Text));
        var seconds = (chunk.Wav.Length - 44) / 32000.0;

        var suspicious = raw == null
            || joined.Length == 0
            || Hallucination.LooksInvented(joined, seconds)
            || Hallucination.LooksDegenerate(joined);

        if (suspicious && prompt.Length > 0)
        {
            Log.Write($"кусок не разобрался: «{Shorten(joined)}» — переспрашиваю без словаря");
            raw = await whisper.TranscribeSegmentsAsync(chunk.Wav, "");
        }

        if (raw == null) return new List<Whisper.Segment>();

        // Тайм-коды приходят от начала куска — сдвигаем к началу файла.
        return raw.Select(s => s with { Start = s.Start + chunk.StartSeconds,
                                        End = s.End + chunk.StartSeconds }).ToList();
    }

    private static string Shorten(string s) => s.Length > 60 ? s[..60] : s;

    private Result Write(List<Whisper.Segment> segments, byte[] wav, string source, Config config)
    {
        var folder = OutputFolder(source, config);
        var name = Path.GetFileNameWithoutExtension(source);
        var cleaned = segments
            .Select(s => s with { Text = config.ApplyReplacements(s.Text).Trim() })
            .Where(s => s.Text.Length > 0)
            .ToList();

        Directory.CreateDirectory(folder);

        var textFile = Path.Combine(folder, name + ".txt");
        File.WriteAllText(textFile, PlainText(cleaned));

        var subtitleFile = Path.Combine(folder, name + ".srt");
        File.WriteAllText(subtitleFile, Subtitles(cleaned));

        string? audioFile = null;
        if (config.KeepConvertedAudio)
        {
            audioFile = Path.Combine(folder, name + ".wav");
            File.WriteAllBytes(audioFile, wav);
        }

        var duration = cleaned.Count > 0 ? cleaned[^1].End : 0;
        Log.Write($"расшифровка готова: {textFile}, отрезков {cleaned.Count}");
        return new Result(textFile, subtitleFile, audioFile, cleaned.Count, duration);
    }

    /// <summary>Пусто в настройках — кладём рядом с исходником.</summary>
    private static string OutputFolder(string source, Config config)
    {
        var stored = config.FileOutputFolder.Trim();
        return stored.Length == 0 ? Path.GetDirectoryName(source)! : stored;
    }

    /// <summary>
    /// Текст абзацами: whisper режет речь на куски по несколько слов,
    /// и построчно читать это невозможно.
    /// </summary>
    private static string PlainText(List<Whisper.Segment> segments)
    {
        const int minimumLine = 90;
        const int maximumLine = 400;

        var lines = new List<string>();
        var buffer = "";
        double start = 0;

        foreach (var segment in segments)
        {
            if (buffer.Length == 0)
            {
                start = segment.Start;
                buffer = segment.Text;
            }
            else
            {
                // Разорванное слово склеиваем без пробела, иначе выходит
                // «стар ую версию».
                buffer += segment.JoinsPreviousWord ? segment.Text : " " + segment.Text;
            }

            var ended = ".!?…".Contains(buffer[^1]);
            if ((ended && buffer.Length >= minimumLine) || buffer.Length >= maximumLine)
            {
                lines.Add($"[{Timecode(start)}] {buffer}");
                buffer = "";
            }
        }
        if (buffer.Length > 0) lines.Add($"[{Timecode(start)}] {buffer}");
        return string.Join(Environment.NewLine + Environment.NewLine, lines);
    }

    private static string Subtitles(List<Whisper.Segment> segments)
    {
        var blocks = segments.Select((s, i) =>
            $"{i + 1}{Environment.NewLine}{SrtTime(s.Start)} --> {SrtTime(s.End)}{Environment.NewLine}{s.Text}");
        return string.Join(Environment.NewLine + Environment.NewLine, blocks) + Environment.NewLine;
    }

    private static string Timecode(double seconds)
    {
        var t = (int)seconds;
        return $"{t / 3600:D2}:{t % 3600 / 60:D2}:{t % 60:D2}";
    }

    private static string SrtTime(double seconds)
    {
        var t = (int)seconds;
        var ms = (int)((seconds - t) * 1000);
        return $"{t / 3600:D2}:{t % 3600 / 60:D2}:{t % 60:D2},{ms:D3}";
    }
}
