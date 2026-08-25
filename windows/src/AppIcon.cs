using System.Drawing;

namespace Golos;

/// <summary>
/// Значок приложения для окон. Берётся из самого exe: класть картинку
/// вторым файлом рядом незачем, она уже вшита в ресурсы.
/// </summary>
public static class AppIcon
{
    private static Icon? cached;

    public static Icon? Load()
    {
        if (cached != null) return cached;
        try
        {
            var path = Environment.ProcessPath;
            if (string.IsNullOrEmpty(path)) return null;
            cached = Icon.ExtractAssociatedIcon(path);
        }
        catch { cached = null; }
        return cached;
    }
}
