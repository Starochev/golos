using System.Runtime.InteropServices;

namespace Golos;

/// <summary>Доставляет готовый текст в активное поле ввода.</summary>
public static class Inserter
{
    private static string? savedClipboard;
    private static System.Windows.Forms.Timer? restoreTimer;

    public static void Insert(string text, string mode)
    {
        if (string.IsNullOrEmpty(text)) return;

        if (mode == "clipboard")
        {
            TrySetClipboard(text);
            return;
        }
        PasteViaClipboard(text);
    }

    /// <summary>
    /// Схема как в версии для macOS: сохранить буфер, подставить своё,
    /// синтезировать Ctrl+V, вернуть как было.
    /// </summary>
    private static void PasteViaClipboard(string text)
    {
        // Две диктовки подряд успевают наложиться: восстановление отложено,
        // и в буфере ещё лежит наш прошлый текст. Снимать его как «исходный»
        // нельзя — затрём содержимое пользователя своим же выводом.
        if (restoreTimer == null)
            savedClipboard = TryGetClipboard();
        StopRestoreTimer();

        if (!TrySetClipboard(text)) return;
        SendCtrlV();

        // Вернуть буфер сразу нельзя: приложение-получатель читает его асинхронно.
        restoreTimer = new System.Windows.Forms.Timer { Interval = 350 };
        restoreTimer.Tick += (_, _) =>
        {
            StopRestoreTimer();
            if (savedClipboard != null) TrySetClipboard(savedClipboard);
            else TryClearClipboard();
            savedClipboard = null;
        };
        restoreTimer.Start();
    }

    private static void StopRestoreTimer()
    {
        restoreTimer?.Stop();
        restoreTimer?.Dispose();
        restoreTimer = null;
    }

    // Буфер обмена бывает занят другим процессом — тогда обращение кидает
    // исключение. Пробуем несколько раз, а не падаем.
    private static string? TryGetClipboard()
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try { return Clipboard.ContainsText() ? Clipboard.GetText() : null; }
            catch { Thread.Sleep(30); }
        }
        return null;
    }

    private static bool TrySetClipboard(string text)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try { Clipboard.SetText(text); return true; }
            catch { Thread.Sleep(30); }
        }
        Log.Write("не удалось положить текст в буфер обмена");
        return false;
    }

    private static void TryClearClipboard()
    {
        try { Clipboard.Clear(); } catch { }
    }

    private static void SendCtrlV()
    {
        const ushort VK_CONTROL = 0x11;
        const ushort VK_V = 0x56;

        var inputs = new[]
        {
            KeyInput(VK_CONTROL, false),
            KeyInput(VK_V, false),
            KeyInput(VK_V, true),
            KeyInput(VK_CONTROL, true)
        };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT KeyInput(ushort key, bool up) => new()
    {
        type = 1, // INPUT_KEYBOARD
        u = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = key,
                dwFlags = up ? 0x0002u : 0u // KEYEVENTF_KEYUP
            }
        }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion u; }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
}
