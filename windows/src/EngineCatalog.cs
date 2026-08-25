using System.IO.Compression;

namespace Golos;

/// <summary>
/// Где взять whisper-server.
///
/// Процессорная сборка лежит внутри exe и раскладывается при первой надобности:
/// приложение обязано работать сразу после скачивания, а не отправлять человека
/// за архивами на чужой сайт. Сборка под видеокарту весит больше полугигабайта,
/// внутрь такое не положишь — она качается по кнопке в настройках.
/// </summary>
public static class EngineCatalog
{
    /// <summary>Выпуск whisper.cpp, из которого взяты обе сборки.</summary>
    public const string Release = "b4938";

    public const string CudaAsset = "whisper-cublas-12.4.0-bin-x64.zip";

    /// <summary>Размер архива с CUDA, для показа до начала закачки.</summary>
    public const long CudaSizeBytes = 670_000_000;

    public static string CudaUrl =>
        $"https://github.com/ggml-org/whisper.cpp/releases/download/{Release}/{CudaAsset}";

    /// <summary>Куда разложена встроенная процессорная сборка.</summary>
    public static string BundledDirectory => Path.Combine(Config.Directory, "engine");

    /// <summary>Куда ложится скачанная сборка под видеокарту.</summary>
    public static string CudaDirectory => Path.Combine(Config.Directory, "engine-cuda");

    public static bool CudaInstalled => Find(CudaDirectory) != null;

    /// <summary>Ищет whisper-server.exe в папке и её подпапках.</summary>
    public static string? Find(string directory)
    {
        try
        {
            if (!Directory.Exists(directory)) return null;
            var found = Directory.GetFiles(directory, "whisper-server.exe", SearchOption.AllDirectories);
            return found.Length > 0 ? found[0] : null;
        }
        catch { return null; }
    }

    /// <summary>
    /// Порядок: своя папка из настроек, сборка под видеокарту, папка engine
    /// рядом с exe, встроенная процессорная. Последняя раскладывается на месте,
    /// поэтому она же и ответ по умолчанию.
    /// </summary>
    public static string? Locate(Config config)
    {
        if (!string.IsNullOrWhiteSpace(config.EnginePath))
        {
            var chosen = Find(config.EnginePath);
            if (chosen != null) return chosen;
            Log.Write($"движок по пути из настроек не найден: {config.EnginePath}");
        }

        return Find(CudaDirectory)
            ?? Find(Path.Combine(AppContext.BaseDirectory, "engine"))
            ?? ExtractBundled();
    }

    /// <summary>Человеческое название того, что сейчас используется.</summary>
    public static string Describe(Config config)
    {
        var path = Locate(config);
        if (path == null) return "не найден";
        if (path.StartsWith(CudaDirectory, StringComparison.OrdinalIgnoreCase))
            return "видеокарта NVIDIA, CUDA";
        if (path.StartsWith(BundledDirectory, StringComparison.OrdinalIgnoreCase))
            return "процессор, встроенная сборка";
        return path;
    }

    /// <summary>
    /// Достаёт встроенный архив с процессорной сборкой. Метка с номером выпуска
    /// лежит рядом: после обновления приложения содержимое папки заменяется,
    /// иначе новый exe работал бы со старыми библиотеками.
    /// </summary>
    public static string? ExtractBundled()
    {
        try
        {
            var stamp = Path.Combine(BundledDirectory, ".release");
            if (File.Exists(stamp) && File.ReadAllText(stamp).Trim() == Release)
            {
                var ready = Find(BundledDirectory);
                if (ready != null) return ready;
            }

            var assembly = System.Reflection.Assembly.GetExecutingAssembly();
            using var source = assembly.GetManifestResourceStream("engine-cpu.zip");
            if (source == null) return null;

            Directory.CreateDirectory(BundledDirectory);
            using (var archive = new ZipArchive(source, ZipArchiveMode.Read))
                archive.ExtractToDirectory(BundledDirectory, overwriteFiles: true);

            using (var license = assembly.GetManifestResourceStream("whisper.cpp-LICENSE.txt"))
            {
                if (license != null)
                {
                    using var output = File.Create(Path.Combine(BundledDirectory, "whisper.cpp-LICENSE.txt"));
                    license.CopyTo(output);
                }
            }

            File.WriteAllText(stamp, Release);
            Log.Write($"движок разложен: {BundledDirectory}");
            return Find(BundledDirectory);
        }
        catch (Exception e)
        {
            Log.Write($"не удалось разложить движок: {e.Message}");
            return null;
        }
    }

    /// <summary>
    /// Распаковывает скачанный архив с CUDA. Возвращает текст ошибки
    /// или null при успехе.
    /// </summary>
    public static string? UnpackCuda(string zipPath)
    {
        try
        {
            if (Directory.Exists(CudaDirectory)) Directory.Delete(CudaDirectory, recursive: true);
            Directory.CreateDirectory(CudaDirectory);
            ZipFile.ExtractToDirectory(zipPath, CudaDirectory, overwriteFiles: true);
            if (Find(CudaDirectory) == null)
                return "В архиве нет whisper-server.exe";
            Log.Write($"движок под видеокарту распакован: {CudaDirectory}");
            return null;
        }
        catch (Exception e) { return e.Message; }
    }
}
