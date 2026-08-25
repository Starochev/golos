using Microsoft.Win32;

namespace Golos;

/// <summary>
/// Автозапуск при входе в систему.
///
/// Через ветку Run в реестре текущего пользователя: прав администратора
/// не требует и не оставляет следов в планировщике. Путь записывается
/// текущий — перенёс приложение, переставь галочку.
/// </summary>
public static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Golos";

    private static string CommandLine
    {
        get
        {
            var path = Environment.ProcessPath ?? "";
            return $"\"{path}\"";
        }
    }

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) is string value && value.Length > 0;
            }
            catch { return false; }
        }
    }

    /// <summary>
    /// Записан ли в реестре путь, отличный от текущего. Такое бывает после
    /// переноса приложения: запись есть, а запускает она то, чего уже нет.
    /// </summary>
    public static bool PathIsStale
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                if (key?.GetValue(ValueName) is not string value) return false;
                return !string.Equals(value.Trim(), CommandLine, StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }
    }

    /// <summary>Возвращает текст ошибки или null при успехе.</summary>
    public static string? Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (key == null) return "Не открылась ветка реестра";

            if (enabled)
            {
                key.SetValue(ValueName, CommandLine, RegistryValueKind.String);
                Log.Write($"автозапуск включён: {CommandLine}");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
                Log.Write("автозапуск выключен");
            }
            return null;
        }
        catch (Exception e)
        {
            Log.Write($"автозапуск не переключился: {e.Message}");
            return e.Message;
        }
    }
}
