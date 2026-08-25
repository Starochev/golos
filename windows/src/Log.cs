namespace Golos;

/// <summary>
/// Журнал в %USERPROFILE%\Documents\Golos\golos.log.
/// Приложение живёт в трее без окон, и без файла разбираться в
/// «почему ничего не происходит» нечем.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();

    public static string FilePath => Path.Combine(Config.Directory, "golos.log");

    public static void Write(string message)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Config.Directory);
                // Не даём журналу расти бесконечно.
                if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 512_000)
                    File.Delete(FilePath);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {message}{Environment.NewLine}");
            }
            catch { }
        }
    }
}
