namespace Golos;

/// <summary>
/// Режет длинную запись на куски короче окна распознавания.
///
/// Whisper разбирает звук окнами по 30 секунд. На стыке окон декодер срывается:
/// замерено, что запись на 47 секунд со словарём давала 128 знаков вместо 757.
/// Без словаря та же запись распознавалась целиком, но словарь нужнее — он
/// держит англицизмы латиницей. Поэтому режем сами, до границы окна.
/// </summary>
public static class AudioSplit
{
    private const int SampleRate = 16000;
    private const int HeaderBytes = 44;

    /// <summary>Длиннее этого — режем. С запасом до тридцати секунд.</summary>
    private const double MaxChunkSeconds = 22;
    /// <summary>Раньше этого рез не ищем, иначе куски выйдут рваные.</summary>
    private const double MinChunkSeconds = 14;

    /// <summary>
    /// Кусок вместе с его началом в исходной записи — нужно, чтобы
    /// пересчитать тайм-коды при расшифровке файла.
    /// </summary>
    public readonly record struct Chunk(byte[] Wav, double StartSeconds);

    public static List<Chunk> ChunksWithOffsets(byte[] wav)
    {
        var total = (wav.Length - HeaderBytes) / 2;
        var maxLength = (int)(MaxChunkSeconds * SampleRate);
        if (total <= maxLength) return new List<Chunk> { new(wav, 0) };

        var parts = new List<Chunk>();
        var start = 0;
        while (start < total)
        {
            var offset = (double)start / SampleRate;
            var remaining = total - start;
            if (remaining <= maxLength)
            {
                parts.Add(new Chunk(Slice(wav, start, total), offset));
                break;
            }
            var cut = start + QuietestCut(wav, start, total);
            parts.Add(new Chunk(Slice(wav, start, cut), offset));
            start = cut;
        }
        return parts;
    }

    public static List<byte[]> Chunks(byte[] wav)
    {
        var total = (wav.Length - HeaderBytes) / 2;
        var maxLength = (int)(MaxChunkSeconds * SampleRate);
        if (total <= maxLength) return new List<byte[]> { wav };

        var parts = new List<byte[]>();
        var start = 0;
        while (start < total)
        {
            var remaining = total - start;
            if (remaining <= maxLength)
            {
                parts.Add(Slice(wav, start, total));
                break;
            }
            var cut = start + QuietestCut(wav, start, total);
            parts.Add(Slice(wav, start, cut));
            start = cut;
        }
        return parts;
    }

    /// <summary>
    /// Ищет самое тихое место в допустимом окне — чтобы рез не пришёлся
    /// на середину слова.
    /// </summary>
    private static int QuietestCut(byte[] wav, int start, int total)
    {
        var window = SampleRate / 10;                        // 100 мс
        var earliest = (int)(MinChunkSeconds * SampleRate);
        var latest = (int)(MaxChunkSeconds * SampleRate);

        var bestOffset = latest;
        var bestEnergy = double.MaxValue;

        for (var offset = earliest; offset + window <= latest && start + offset + window <= total; offset += window)
        {
            double sum = 0;
            for (var i = start + offset; i < start + offset + window; i++)
            {
                var sample = BitConverter.ToInt16(wav, HeaderBytes + i * 2) / 32768.0;
                sum += sample * sample;
            }
            if (sum < bestEnergy)
            {
                bestEnergy = sum;
                bestOffset = offset + window / 2;
            }
        }
        return bestOffset;
    }

    /// <summary>Собирает новый WAV из диапазона сэмплов исходного.</summary>
    private static byte[] Slice(byte[] wav, int fromSample, int toSample)
    {
        var bytes = (toSample - fromSample) * 2;
        using var output = new MemoryStream();
        using var writer = new BinaryWriter(output);

        writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + bytes);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(SampleRate);
        writer.Write(SampleRate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        writer.Write(bytes);
        writer.Write(wav, HeaderBytes + fromSample * 2, bytes);
        writer.Flush();
        return output.ToArray();
    }
}
