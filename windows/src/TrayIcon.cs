using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace Golos;

/// <summary>
/// Иконка в трее: волна из пяти полос, как в версии для macOS.
/// В покое цвет подбирается под тему панели задач — белая иконка на светлой
/// панели не видна, чёрная на тёмной тоже.
/// </summary>
public static class TrayIcon
{
    private const int Size = 32;

    public static Icon Idle() => Bars(new float[] { 8, 16, 24, 16, 8 }, NeutralColor());

    /// <summary>color = null — нейтральный цвет под тему панели задач.</summary>
    public static Icon Recording(float level, Color? color, bool audio = false)
    {
        var weights = new[] { 0.45f, 0.75f, 1.0f, 0.75f, 0.45f };
        var heights = weights.Select(w => Math.Clamp(6 + level * 22 * w, 6, 28)).ToArray();
        // В режиме звука волна ужимается до трёх полос, справа встаёт нотка:
        // при выключенном окошке значок остаётся единственным, кто показывает,
        // чем сейчас отдастся запись.
        return audio
            ? BarsWithNote(heights.Skip(1).Take(3).ToArray(), color ?? NeutralColor())
            : Bars(heights, color ?? NeutralColor());
    }

    /// <summary>Волна слева, нотка справа. Пятью полосами и ноткой не уложиться.</summary>
    private static Icon BarsWithNote(float[] heights, Color color)
    {
        var bitmap = new Bitmap(Size, Size);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            const float width = 4f;
            const float gap = 3f;
            var x = 1f;
            using (var brush = new SolidBrush(color))
            {
                foreach (var height in heights)
                {
                    var rect = new RectangleF(x, (Size - height) / 2f, width, height);
                    using var path = Rounded(rect, width / 2f);
                    g.FillPath(brush, path);
                    x += width + gap;
                }

                // Нотка: головка и штиль. Своей фигурой, а не шрифтом —
                // в тридцати двух точках символ из шрифта плывёт.
                var head = new RectangleF(Size - 15f, Size - 13f, 8f, 6.5f);
                g.FillEllipse(brush, head);
                using var stem = new Pen(color, 2.2f);
                g.DrawLine(stem, head.Right - 1.1f, head.Top + 3f, head.Right - 1.1f, 7f);
                g.DrawLine(stem, head.Right - 1.1f, 7f, Size - 3f, 10f);
            }
        }
        return FromBitmap(bitmap);
    }

    public static Icon Transcribing(float phase)
    {
        var heights = Enumerable.Range(0, 5)
            .Select(i => 8f + 10f * (0.5f + 0.5f * (float)Math.Sin(phase - i * 0.9)))
            .ToArray();
        return Bars(heights, Color.FromArgb(150, 150, 150));
    }

    public static Icon Failed() => Bars(new float[] { 6, 6, 26, 6, 6 }, Color.FromArgb(255, 159, 10));

    private static Color NeutralColor()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var light = key?.GetValue("SystemUsesLightTheme") as int?;
            return light == 1 ? Color.FromArgb(32, 32, 32) : Color.White;
        }
        catch { return Color.White; }
    }

    private static Icon Bars(float[] heights, Color color)
    {
        var bitmap = new Bitmap(Size, Size);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            const float width = 4f;
            const float gap = 3f;
            var total = heights.Length * width + (heights.Length - 1) * gap;
            var x = (Size - total) / 2f;

            using var brush = new SolidBrush(color);
            foreach (var height in heights)
            {
                var rect = new RectangleF(x, (Size - height) / 2f, width, height);
                using var path = Rounded(rect, width / 2f);
                g.FillPath(brush, path);
                x += width + gap;
            }
        }

        return FromBitmap(bitmap);
    }

    /// <summary>
    /// Icon.FromHandle не владеет хендлом: клонируем и сразу освобождаем,
    /// иначе за час работы утекут тысячи GDI-объектов.
    /// </summary>
    private static Icon FromBitmap(Bitmap bitmap)
    {
        var handle = bitmap.GetHicon();
        using var temp = Icon.FromHandle(handle);
        var icon = (Icon)temp.Clone();
        DestroyIcon(handle);
        bitmap.Dispose();
        return icon;
    }

    private static GraphicsPath Rounded(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        var diameter = radius * 2;
        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}
