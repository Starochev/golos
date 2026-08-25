using NAudio.MediaFoundation;
using NAudio.Wave;

namespace Golos;

/// <summary>
/// Приводит любой звуковой или видеофайл к тому, что ест распознавание:
/// моно 16 кГц, 16 бит.
///
/// Сперва Media Foundation: mp3, m4a, aac, wma, wav, звук из mp4 и, если стоит
/// Web Media Extensions, даже webm система читает сама. Что не взяла, отдаём
/// урезанному ffmpeg: он лежит внутри exe и достаётся наружу при первой
/// надобности. Рядом с приложением и в PATH тоже смотрим: своя копия там
/// перебивает встроенную.
/// </summary>
public static class MediaDecoder
{
    public const int SampleRate = 16000;

    /// <summary>Расширения, которые предлагаем перетаскивать.</summary>
    public static readonly HashSet<string> SupportedExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp3", ".m4a", ".aac", ".wav", ".aiff", ".aif", ".flac", ".wma",
        ".mp4", ".mov", ".m4v", ".mkv", ".avi", ".webm", ".ogg", ".opus"
    };

    private static bool started;

    public static byte[] Decode(string path, Action<double>? progress = null)
    {
        try { return DecodeWithMediaFoundation(path, progress); }
        catch (Exception e)
        {
            Log.Write($"системный декодер не взял «{Path.GetFileName(path)}»: {e.Message}");
            var viaFfmpeg = DecodeWithFfmpeg(path);
            if (viaFfmpeg != null) return viaFfmpeg;
            throw;
        }
    }

    private static byte[] DecodeWithMediaFoundation(string path, Action<double>? progress)
    {
        if (!started) { MediaFoundationApi.Startup(); started = true; }

        using var reader = new MediaFoundationReader(path);
        var target = new WaveFormat(SampleRate, 16, 1);
        using var resampler = new MediaFoundationResampler(reader, target) { ResamplerQuality = 60 };

        using var pcm = new MemoryStream();
        var buffer = new byte[1 << 16];
        var total = reader.TotalTime.TotalSeconds;
        int read;
        while ((read = resampler.Read(buffer, 0, buffer.Length)) > 0)
        {
            pcm.Write(buffer, 0, read);
            if (total > 0) progress?.Invoke(Math.Min(1, reader.CurrentTime.TotalSeconds / total));
        }
        progress?.Invoke(1);
        return WrapInWav(pcm.ToArray());
    }

    /// <summary>Запасной путь для форматов, которые система не читает.</summary>
    private static byte[]? DecodeWithFfmpeg(string path)
    {
        var ffmpeg = FindFfmpeg();
        if (ffmpeg == null) return null;

        var temp = Path.Combine(Path.GetTempPath(), $"golos-{Guid.NewGuid():N}.wav");
        try
        {
            var info = new System.Diagnostics.ProcessStartInfo
            {
                FileName = ffmpeg,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            // -vn -sn -dn: в урезанной сборке видеодекодеров нет, и просить их не надо.
            foreach (var a in new[] { "-y", "-loglevel", "error", "-i", path,
                                      "-vn", "-sn", "-dn",
                                      "-ar", SampleRate.ToString(), "-ac", "1",
                                      "-c:a", "pcm_s16le", temp })
                info.ArgumentList.Add(a);

            using var process = System.Diagnostics.Process.Start(info);
            if (process == null) return null;
            process.WaitForExit();
            if (process.ExitCode != 0 || !File.Exists(temp)) return null;

            var which = ffmpeg.StartsWith(Config.Directory, StringComparison.OrdinalIgnoreCase) ? "свой" : "сторонний";
            Log.Write($"файл прочитан через ffmpeg ({which}): {Path.GetFileName(path)}");
            return File.ReadAllBytes(temp);
        }
        catch { return null; }
        finally { try { if (File.Exists(temp)) File.Delete(temp); } catch { } }
    }

    private static string? FindFfmpeg()
    {
        var beside = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
        if (File.Exists(beside)) return beside;

        var extracted = ExtractBundledFfmpeg();
        if (extracted != null) return extracted;

        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir, "ffmpeg.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch { }
        }
        return null;
    }

    /// <summary>
    /// Достаёт встроенный ffmpeg в папку приложения. Раскладывается один раз:
    /// дальше проверяется только размер, чтобы после обновления положить новый.
    /// </summary>
    private static string? ExtractBundledFfmpeg()
    {
        try
        {
            var assembly = System.Reflection.Assembly.GetExecutingAssembly();
            using var source = assembly.GetManifestResourceStream("ffmpeg.exe");
            if (source == null) return null;

            Directory.CreateDirectory(Config.Directory);
            var target = Path.Combine(Config.Directory, "ffmpeg.exe");
            if (File.Exists(target) && new FileInfo(target).Length == source.Length) return target;

            // Через временный файл: иначе прерванная запись оставит битый exe,
            // который по размеру не отличить от целого только в редком случае.
            var temp = target + ".new";
            using (var output = File.Create(temp)) source.CopyTo(output);
            File.Move(temp, target, overwrite: true);

            foreach (var name in new[] { "ffmpeg-LICENSE.txt", "ffmpeg-SOURCE.txt" })
            {
                using var text = assembly.GetManifestResourceStream(name);
                if (text == null) continue;
                using var output = File.Create(Path.Combine(Config.Directory, name));
                text.CopyTo(output);
            }

            Log.Write($"ffmpeg разложен: {target}");
            return target;
        }
        catch (Exception e)
        {
            Log.Write($"не удалось разложить ffmpeg: {e.Message}");
            return null;
        }
    }

    private static byte[] WrapInWav(byte[] pcm)
    {
        using var output = new MemoryStream();
        using var writer = new BinaryWriter(output);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + pcm.Length);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(SampleRate);
        writer.Write(SampleRate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        writer.Write(pcm.Length);
        writer.Write(pcm);
        writer.Flush();
        return output.ToArray();
    }
}
