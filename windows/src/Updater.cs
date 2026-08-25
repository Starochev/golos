using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace Golos;

/// <summary>
/// Обновления через файл в репозитории.
///
/// Адрес взят из ветки, а не из «последнего релиза»: в том же репозитории
/// лежат сборки для macOS, и «последним» оказывался бы то один, то другой.
/// Файл в ветке всегда указывает именно на актуальную сборку для Windows.
/// </summary>
public static class Updater
{
    private const string FeedUrl = "https://raw.githubusercontent.com/Starochev/golos/main/windows.json";

    private sealed record Feed(string Version, string Url, string? Sha256, string? Notes);

    public static string CurrentVersion =>
        typeof(Updater).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    /// <summary>Проверка вручную: показывает результат в любом случае.</summary>
    public static async Task CheckAsync(IWin32Window? owner, bool silent)
    {
        Feed? feed;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            var json = await http.GetStringAsync(FeedUrl);
            feed = JsonSerializer.Deserialize<Feed>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });
        }
        catch (Exception e)
        {
            Log.Write($"обновления: не дотянулся до ленты: {e.Message}");
            if (!silent) Show(owner, "Не удалось проверить обновления. Похоже, нет сети.");
            return;
        }

        if (feed == null || string.IsNullOrEmpty(feed.Version) || string.IsNullOrEmpty(feed.Url))
        {
            if (!silent) Show(owner, "Лента обновлений пустая.");
            return;
        }

        if (!IsNewer(feed.Version, CurrentVersion))
        {
            Log.Write($"обновления: установлена {CurrentVersion}, в ленте {feed.Version}");
            if (!silent) Show(owner, $"Установлена последняя версия — {CurrentVersion}.");
            return;
        }

        var text = $"Есть версия {feed.Version}, установлена {CurrentVersion}.";
        if (!string.IsNullOrWhiteSpace(feed.Notes)) text += Environment.NewLine + Environment.NewLine + feed.Notes;
        text += Environment.NewLine + Environment.NewLine + "Обновить сейчас? Приложение перезапустится.";

        var answer = MessageBox.Show(owner, text, "Голос", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (answer != DialogResult.Yes) return;

        await DownloadAndSwapAsync(owner, feed);
    }

    private static async Task DownloadAndSwapAsync(IWin32Window? owner, Feed feed)
    {
        var temp = Path.Combine(Path.GetTempPath(), "Golos-update.exe");
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(15) };
            var bytes = await http.GetByteArrayAsync(feed.Url);

            // Файл заменит собой работающее приложение — проверяем, что это
            // вообще исполняемый файл, а не страница с ошибкой.
            if (bytes.Length < 1_000_000 || bytes[0] != 'M' || bytes[1] != 'Z')
            {
                Show(owner, "Скачался не тот файл. Обновление отменено.");
                return;
            }

            if (!string.IsNullOrEmpty(feed.Sha256))
            {
                var actual = Convert.ToHexString(SHA256.HashData(bytes));
                if (!actual.Equals(feed.Sha256, StringComparison.OrdinalIgnoreCase))
                {
                    Log.Write($"обновления: контрольная сумма не сошлась, ждали {feed.Sha256}, получили {actual}");
                    Show(owner, "Контрольная сумма не сошлась. Обновление отменено.");
                    return;
                }
            }

            await File.WriteAllBytesAsync(temp, bytes);
        }
        catch (Exception e)
        {
            Log.Write($"обновления: не скачалось: {e.Message}");
            Show(owner, "Не удалось скачать обновление.");
            return;
        }

        // Себя на ходу заменить нельзя: файл занят. Поэтому помощник ждёт
        // выхода нашего процесса, подменяет exe и запускает заново.
        var target = Environment.ProcessPath;
        if (string.IsNullOrEmpty(target))
        {
            Show(owner, "Не понял, где лежу. Обновление отменено.");
            return;
        }

        var script = Path.Combine(Path.GetTempPath(), "golos-update.ps1");
        await File.WriteAllTextAsync(script, $"""
            Wait-Process -Id {Environment.ProcessId} -Timeout 60 -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            Copy-Item -LiteralPath '{temp}' -Destination '{target}' -Force
            Remove-Item -LiteralPath '{temp}' -Force -ErrorAction SilentlyContinue
            Start-Process -FilePath '{target}'
            Remove-Item -LiteralPath '{script}' -Force -ErrorAction SilentlyContinue
            """);

        Process.Start(new ProcessStartInfo
        {
            FileName = "powershell",
            Arguments = $"-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"{script}\"",
            UseShellExecute = false,
            CreateNoWindow = true
        });

        Log.Write($"обновляюсь до {feed.Version}");
        Application.Exit();
    }

    /// <summary>Сравнение версий по числам, а не по строке: 0.10 новее 0.9.</summary>
    private static bool IsNewer(string candidate, string current)
    {
        static int[] Parse(string v) => v.Split('.')
            .Select(part => int.TryParse(part, out var n) ? n : 0)
            .Concat(new[] { 0, 0, 0 })
            .Take(3)
            .ToArray();

        var a = Parse(candidate);
        var b = Parse(current);
        for (var i = 0; i < 3; i++)
        {
            if (a[i] > b[i]) return true;
            if (a[i] < b[i]) return false;
        }
        return false;
    }

    private static void Show(IWin32Window? owner, string text) =>
        MessageBox.Show(owner, text, "Голос", MessageBoxButtons.OK, MessageBoxIcon.Information);
}
