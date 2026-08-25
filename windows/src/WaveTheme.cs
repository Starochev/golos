using System.Drawing;

namespace Golos;

/// <summary>
/// Цвет волны: одна настройка красит и окошко записи, и значок в трее.
/// Идентификаторы общие с версией для macOS.
/// </summary>
public sealed record WaveTheme(string Id, string Title, string Hex, bool TrayUsesNeutral)
{
    public const string CustomId = "custom";

    public static readonly WaveTheme[] All =
    {
        new("red",    "Красный",    "#FF453A", false),
        new("teal",   "Бирюзовый",  "#2CD4C0", false),
        new("violet", "Фиолетовый", "#A78BFA", false),
        new("amber",  "Янтарный",   "#FFB020", false),
        // Монохрому в трее цвет не нужен: там значок подбирается под тему
        // панели задач, и белый на светлой панели было бы не видно.
        new("mono",   "Монохром",   "#F2F2F7", true)
    };

    public static WaveTheme Fallback => All[0];

    public static WaveTheme? Named(string id) => All.FirstOrDefault(t => t.Id == id);

    public Color Color => Parse(Hex) ?? System.Drawing.Color.FromArgb(255, 69, 58);

    /// <summary>Цвет для окошка записи: фон там тёмный, берётся как есть.</summary>
    public static Color ColorFor(Config config)
    {
        if (config.WaveTheme == CustomId)
            return Parse(config.CustomWaveColor) ?? Fallback.Color;
        return (Named(config.WaveTheme) ?? Fallback).Color;
    }

    /// <summary>Цвет для трея. null — рисовать нейтральным под тему панели.</summary>
    public static Color? TrayColorFor(Config config)
    {
        if (config.WaveTheme == CustomId)
            return Parse(config.CustomWaveColor) ?? Fallback.Color;
        var theme = Named(config.WaveTheme) ?? Fallback;
        return theme.TrayUsesNeutral ? null : theme.Color;
    }

    /// <summary>Разбирает #RRGGBB. Кривая строка даёт null, а не чёрный квадрат.</summary>
    public static Color? Parse(string hex)
    {
        var text = hex.Trim().TrimStart('#');
        if (text.Length != 6) return null;
        if (!int.TryParse(text, System.Globalization.NumberStyles.HexNumber, null, out var value)) return null;
        return System.Drawing.Color.FromArgb((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF);
    }

    public static string ToHex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";
}
