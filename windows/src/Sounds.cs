using System.Media;

namespace Golos;

/// <summary>
/// Сигналы начала и конца записи.
///
/// Тоны синтезируются в коде, а не лежат файлами: их проще подобрать на слух
/// и не надо тащить ресурсы. Системные звуки для действия, которое
/// повторяется десятки раз в день, звучат как отказ ввода.
/// </summary>
public static class Sounds
{
    public enum Moment { Start, Stop }

    public sealed record Tone(double Frequency, double Duration = 0.11, double Amplitude = 0.22,
                              double Harmonic = 0.18, double Decay = 5.0);

    public sealed record Theme(string Id, string Title, string Note, Tone Start, Tone Stop);

    public static readonly Theme[] Themes =
    {
        new("soft", "Мягкий", "Ниже и глуше остальных, меньше привлекает внимание",
            new Tone(523.25, 0.13, Harmonic: 0.10, Decay: 4.0),
            new Tone(392.00, 0.13, Harmonic: 0.10, Decay: 4.0)),
        new("bell", "Колокольчик", "Ясно слышно даже в шумном месте",
            new Tone(783.99), new Tone(587.33)),
        new("quiet", "Тихий", "Совсем короткий отклик, не мешает в тишине",
            new Tone(659.25, 0.07, 0.15, 0.05, 7.0),
            new Tone(493.88, 0.07, 0.15, 0.05, 7.0))
    };

    public static Theme ThemeOf(string id) => Themes.FirstOrDefault(t => t.Id == id) ?? Themes[0];

    // По одному готовому проигрывателю на сигнал: создавать их на каждое
    // воспроизведение — верный способ накопить сотни живых объектов.
    private static readonly Dictionary<string, SoundPlayer> Players = new();
    private static readonly object Gate = new();

    public static void Play(Moment moment, string themeId)
    {
        var theme = ThemeOf(themeId);
        var tone = moment == Moment.Start ? theme.Start : theme.Stop;
        var key = $"{theme.Id}.{moment}";

        SoundPlayer? player;
        lock (Gate)
        {
            if (!Players.TryGetValue(key, out player))
            {
                try
                {
                    player = new SoundPlayer(new MemoryStream(BuildWav(tone)));
                    player.Load();
                    Players[key] = player;
                }
                catch { return; }
            }
        }

        try { player?.Play(); } catch { }
    }

    /// <summary>Синус со второй гармоникой, мягкой атакой и затуханием.</summary>
    private static byte[] BuildWav(Tone tone)
    {
        const int sampleRate = 44100;
        const double attack = 0.006;
        var count = (int)(sampleRate * tone.Duration);

        using var output = new MemoryStream();
        using var writer = new BinaryWriter(output);
        var bytes = count * 2;

        writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + bytes);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(sampleRate);
        writer.Write(sampleRate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        writer.Write(bytes);

        for (var i = 0; i < count; i++)
        {
            var t = (double)i / sampleRate;
            // Плавный вход убирает щелчок в начале.
            var envelope = Math.Min(1.0, t / attack) * Math.Exp(-tone.Decay * t / tone.Duration);
            var value = Math.Sin(2 * Math.PI * tone.Frequency * t)
                      + tone.Harmonic * Math.Sin(4 * Math.PI * tone.Frequency * t);
            var scaled = Math.Clamp(value * envelope * tone.Amplitude, -1, 1);
            writer.Write((short)(scaled * 32767));
        }

        writer.Flush();
        return output.ToArray();
    }
}
