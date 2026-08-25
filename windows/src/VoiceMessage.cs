using System.Diagnostics;

namespace Golos;

/// <summary>
/// Голосовое сообщение: запись сжимается и кладётся в буфер файлом.
/// Дальше её вставляют в чат обычным Ctrl+V.
///
/// Формат ogg с opus, а не m4a: мессенджеры показывают голосовым сообщением
/// именно его, остальное приезжает вложением с плеером. 48 кГц моно, 24 кбит,
/// профиль voip — то же, что пишут сами мессенджеры. Выходит около 178 КБ
/// на минуту против 1875 у исходного WAV.
/// </summary>
public static class VoiceMessage
{
    /// <summary>
    /// Готовые файлы живут рядом с настройками, а не во временной папке:
    /// в буфере лежит ссылка, и файл обязан пережить вставку.
    /// </summary>
    public static string Directory => Path.Combine(Config.Directory, "voice");

    /// <summary>Сколько держим отправленные файлы.</summary>
    private const double RetentionHours = 24;

    /// <summary>Сжимает запись и возвращает путь к файлу либо текст ошибки.</summary>
    public static (string? path, string? error) Encode(byte[] wav)
    {
        var ffmpeg = MediaDecoder.FindFfmpegPublic();
        if (ffmpeg == null) return (null, "Сжатие звука недоступно: рядом нет ffmpeg");

        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            var stamp = DateTime.Now.ToString("yyyy-MM-dd'T'HHmmss");
            var source = Path.Combine(Directory, $"{stamp}.wav");
            var target = Path.Combine(Directory, $"voice-{stamp}.ogg");
            File.WriteAllBytes(source, wav);

            try
            {
                var info = new ProcessStartInfo
                {
                    FileName = ffmpeg,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardError = true
                };
                foreach (var a in new[] { "-y", "-loglevel", "error", "-i", source,
                                          "-c:a", "libopus", "-b:a", "24k", "-ar", "48000",
                                          "-ac", "1", "-application", "voip",
                                          "-f", "ogg", target })
                    info.ArgumentList.Add(a);

                using var process = Process.Start(info);
                if (process == null) return (null, "ffmpeg не запустился");
                var complaint = process.StandardError.ReadToEnd().Trim();
                process.WaitForExit();

                if (process.ExitCode != 0 || !File.Exists(target) || new FileInfo(target).Length == 0)
                    return (null, complaint.Length > 0 ? complaint : $"ffmpeg вышел с кодом {process.ExitCode}");

                Purge();
                return (target, null);
            }
            finally
            {
                try { File.Delete(source); } catch { }
            }
        }
        catch (Exception e) { return (null, e.Message); }
    }

    /// <summary>Кладёт готовый файл в буфер обмена ссылкой.</summary>
    public static void CopyToClipboard(string path)
    {
        var files = new System.Collections.Specialized.StringCollection { path };
        Clipboard.SetFileDropList(files);
    }

    /// <summary>Чистит вчерашние файлы. Свежий не трогаем: на него смотрит буфер.</summary>
    private static void Purge()
    {
        try
        {
            var deadline = DateTime.Now.AddHours(-RetentionHours);
            var removed = 0;
            foreach (var file in System.IO.Directory.GetFiles(Directory))
            {
                if (File.GetLastWriteTime(file) >= deadline) continue;
                try { File.Delete(file); removed++; } catch { }
            }
            if (removed > 0) Log.Write($"голосовые: удалено файлов {removed}");
        }
        catch { }
    }
}
