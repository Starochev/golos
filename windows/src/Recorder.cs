using NAudio.Wave;

namespace Golos;

/// <summary>
/// Пишет микрофон в моно 16 кГц — ровно то, что ест whisper.
/// Формат запрашивается у winmm напрямую: он сам пересчитает частоту,
/// если железо отдаёт другую, и возиться с ресемплером не приходится.
/// </summary>
public sealed class Recorder : IDisposable
{
    private WaveInEvent? device;
    private MemoryStream buffer = new();
    private readonly object gate = new();

    public bool IsRunning { get; private set; }

    /// <summary>Имя микрофона, который слушали в последний раз.</summary>
    public string ActiveDeviceName { get; private set; } = "";

    /// <summary>
    /// Доступные микрофоны. Имена приходят из winmm и обрезаны до 31 символа —
    /// это ограничение самого интерфейса, не наше.
    /// </summary>
    public static List<(int Index, string Name)> Devices()
    {
        var devices = new List<(int, string)>();
        for (var i = 0; i < WaveInEvent.DeviceCount; i++)
        {
            try { devices.Add((i, WaveInEvent.GetCapabilities(i).ProductName)); }
            catch { }
        }
        return devices;
    }

    /// <summary>
    /// Номер устройства по сохранённому имени. -1 — системное по умолчанию.
    /// Если записанного микрофона нет (отключили гарнитуру), молча падаем
    /// на системный, но пишем об этом в журнал: тишина в записи иначе
    /// выглядит как сломанное приложение.
    /// </summary>
    public static int ResolveDevice(string preferredName)
    {
        if (string.IsNullOrWhiteSpace(preferredName)) return -1;

        foreach (var (index, name) in Devices())
            if (string.Equals(name, preferredName, StringComparison.OrdinalIgnoreCase))
                return index;

        // Имя обрезано в winmm — сверяем по началу строки.
        foreach (var (index, name) in Devices())
            if (name.StartsWith(preferredName, StringComparison.OrdinalIgnoreCase) ||
                preferredName.StartsWith(name, StringComparison.OrdinalIgnoreCase))
                return index;

        Log.Write($"микрофон «{preferredName}» не найден, беру системный");
        return -1;
    }

    public void Start(string preferredDevice = "")
    {
        if (IsRunning) return;

        lock (gate) { buffer = new MemoryStream(); }

        var number = ResolveDevice(preferredDevice);
        ActiveDeviceName = number < 0
            ? "системный по умолчанию"
            : Devices().FirstOrDefault(d => d.Index == number).Name ?? "";

        device = new WaveInEvent
        {
            DeviceNumber = number,
            WaveFormat = new WaveFormat(16000, 16, 1),
            BufferMilliseconds = 50
        };
        device.DataAvailable += OnData;
        device.StartRecording();
        IsRunning = true;
    }

    /// <summary>Останавливает запись и отдаёт WAV. null — писать было нечего.</summary>
    public byte[]? Stop()
    {
        if (!IsRunning) return null;
        IsRunning = false;

        if (device != null)
        {
            device.DataAvailable -= OnData;
            try { device.StopRecording(); } catch { }
            device.Dispose();
            device = null;
        }

        byte[] pcm;
        lock (gate)
        {
            pcm = buffer.ToArray();
            buffer = new MemoryStream();
        }

        // Меньше 0.3 с — случайное нажатие, а не речь.
        if (pcm.Length < 16000 * 2 * 3 / 10) return null;

        // Совсем тихая запись — микрофон не тот, выключен или человек
        // передумал говорить. Отправлять такое нельзя: на тишине whisper
        // выдаёт выдуманную фразу из обучающих данных.
        if (!HasSpeech(pcm))
        {
            Log.Write("в записи нет речи, не отправляю");
            return null;
        }

        return BuildWav(pcm, 16000);
    }

    /// <summary>
    /// Текущая громкость 0…1 для живой иконки. Шкала логарифмическая:
    /// линейная даёт почти плоскую линию, потому что речь по амплитуде
    /// занимает крошечную часть диапазона.
    /// </summary>
    public float Level
    {
        get
        {
            byte[] tail;
            lock (gate)
            {
                var length = (int)buffer.Length;
                if (length < 2) return 0;
                var take = Math.Min(3200, length - length % 2);
                tail = new byte[take];
                var data = buffer.GetBuffer();
                Array.Copy(data, length - take, tail, 0, take);
            }

            double sum = 0;
            var count = tail.Length / 2;
            for (var i = 0; i < count; i++)
            {
                var sample = BitConverter.ToInt16(tail, i * 2) / 32768.0;
                sum += sample * sample;
            }
            var rms = Math.Sqrt(sum / Math.Max(1, count));
            if (rms < 1e-6) return 0;

            var db = 20 * Math.Log10(rms);
            return (float)Math.Clamp((db + 60) / 50, 0, 1);
        }
    }

    /// <summary>
    /// Есть ли в записи хоть треть секунды звука.
    ///
    /// Считаем не пик, а сколько окон содержат звук: пик бесполезен, потому
    /// что приложение само играет сигнал в начале записи и микрофон его
    /// слышит. По той же причине начало пропускаем.
    ///
    /// Окно 100 мс, порог примерно −42 дБ: комнатная тишина держится ниже
    /// −55 дБ, речь идёт в районе −30 дБ, порог лежит с запасом между ними.
    /// </summary>
    public static bool HasSpeech(byte[] pcm)
    {
        const int window = 1600;        // 100 мс при 16 кГц
        const int skipStart = 3200;     // 200 мс на собственный сигнал
        const double threshold = 0.008;
        const int needed = 3;

        var total = pcm.Length / 2;
        if (total <= skipStart + window) return false;

        var loud = 0;
        for (var start = skipStart; start + window <= total; start += window)
        {
            double sum = 0;
            for (var i = start; i < start + window; i++)
            {
                var sample = BitConverter.ToInt16(pcm, i * 2) / 32768.0;
                sum += sample * sample;
            }
            if (Math.Sqrt(sum / window) > threshold && ++loud >= needed) return true;
        }
        return false;
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        lock (gate) { buffer.Write(e.Buffer, 0, e.BytesRecorded); }
    }

    /// <summary>Собирает 16-битный PCM WAV вручную: тащить ради этого писатель незачем.</summary>
    private static byte[] BuildWav(byte[] pcm, int sampleRate)
    {
        using var output = new MemoryStream();
        using var writer = new BinaryWriter(output);

        writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + pcm.Length);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);                       // размер fmt-блока
        writer.Write((short)1);                 // PCM
        writer.Write((short)1);                 // моно
        writer.Write(sampleRate);
        writer.Write(sampleRate * 2);           // байт в секунду
        writer.Write((short)2);                 // выравнивание блока
        writer.Write((short)16);                // бит на сэмпл
        writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        writer.Write(pcm.Length);
        writer.Write(pcm);
        writer.Flush();
        return output.ToArray();
    }

    public void Dispose()
    {
        device?.Dispose();
        buffer.Dispose();
    }
}
