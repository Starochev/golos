using System.Runtime.InteropServices;

namespace Golos;

/// <summary>
/// Слушает правый Alt через низкоуровневый хук клавиатуры и различает
/// два жеста: удержание — рация, двойной тап — переключатель.
///
/// Клавиша перехватывается насовсем (хук возвращает 1). На Windows одиночное
/// нажатие Alt отдаёт фокус меню активного окна — во время диктовки это
/// сбивало бы всё подряд. Правый Alt в русской и английской раскладках
/// ничего не набирает, так что терять нечего.
/// </summary>
public sealed class Hotkey : IDisposable
{
    public enum Event { StartHold, FinishHold, ToggleOn, ToggleOff, Cancel, Discard }

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_ESCAPE = 0x1B;

    /// <summary>Какая клавиша слушается. Меняется на лету.</summary>
    private HotkeyOption option = HotkeyOption.Fallback;

    public void SetOption(HotkeyOption newOption)
    {
        if (newOption.Id == option.Id) return;
        Reset();
        option = newOption;
        Log.Write($"клавиша записи: {newOption.Title}");
    }

    /// <summary>Короче этого удержание считается тапом, а не рацией.</summary>
    private static readonly TimeSpan TapThreshold = TimeSpan.FromMilliseconds(400);
    /// <summary>Окно, внутри которого второй тап образует двойной.</summary>
    private const int DoubleTapWindowMs = 350;

    private readonly Action<Event> handler;
    // Делегат держим полем: если его соберёт сборщик мусора, хук уронит процесс.
    private readonly LowLevelKeyboardProc callback;
    private IntPtr hook = IntPtr.Zero;

    private DateTime? keyDownAt;
    private bool holdActive;
    private bool toggleActive;
    private System.Windows.Forms.Timer? discardTimer;

    public Hotkey(Action<Event> handler)
    {
        this.handler = handler;
        callback = HookProc;
    }

    public bool Start()
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        using var module = process.MainModule!;
        hook = SetWindowsHookEx(WH_KEYBOARD_LL, callback, GetModuleHandle(module.ModuleName), 0);
        if (hook == IntPtr.Zero)
            Log.Write($"SetWindowsHookEx не удался, код {Marshal.GetLastWin32Error()}");
        return hook != IntPtr.Zero;
    }

    /// <summary>Сбросить состояние, если запись остановили не клавишей.</summary>
    public void Reset()
    {
        CancelDiscardTimer();
        toggleActive = false;
        holdActive = false;
        keyDownAt = null;
    }

    private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(hook, nCode, wParam, lParam);

        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        var message = (int)wParam;

        var down = message is WM_KEYDOWN or WM_SYSKEYDOWN;
        var up = message is WM_KEYUP or WM_SYSKEYUP;

        var current = option;
        if (info.vkCode == (uint)current.VirtualKey)
        {
            // Автоповтор при удержании шлёт keydown пачками — KeyPressed
            // отсекает их сам.
            if (down) KeyPressed();
            else if (up) KeyReleased();

            // Модификаторы проглатываем: иначе одиночный Alt или Windows
            // отдаст фокус меню. Обычные клавиши вроде F13 пропускаем —
            // мешать они всё равно никому не будут.
            return current.IsModifier ? (IntPtr)1 : CallNextHookEx(hook, nCode, wParam, lParam);
        }

        if (down && info.vkCode == VK_ESCAPE && (holdActive || toggleActive))
        {
            CancelAll();
            return CallNextHookEx(hook, nCode, wParam, lParam);
        }

        // Пошёл обычный набор при зажатой клавише — значит человек печатает,
        // а не диктует. В режиме переключателя не мешаем: там печатать
        // во время записи может быть намеренно.
        if (down && holdActive) CancelAll();

        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    private void KeyPressed()
    {
        // Автоповтор при удержании шлёт keydown пачками — считаем только первый.
        if (holdActive) return;

        if (toggleActive)
        {
            toggleActive = false;
            keyDownAt = null;
            handler(Event.ToggleOff);
            return;
        }

        // Второй тап внутри окна: одиночный тап уже запустил запись, остаётся
        // отменить её выброс и перевести в режим переключателя.
        if (discardTimer != null)
        {
            CancelDiscardTimer();
            toggleActive = true;
            keyDownAt = null;
            handler(Event.ToggleOn);
            return;
        }

        keyDownAt = DateTime.UtcNow;
        holdActive = true;
        handler(Event.StartHold);
    }

    private void KeyReleased()
    {
        if (!holdActive || keyDownAt == null) return;
        holdActive = false;
        var held = DateTime.UtcNow - keyDownAt.Value;
        keyDownAt = null;

        if (held >= TapThreshold)
        {
            handler(Event.FinishHold);
            return;
        }

        // Короткий тап: ждём напарника. Не пришёл — записанное выбрасываем.
        discardTimer = new System.Windows.Forms.Timer { Interval = DoubleTapWindowMs };
        discardTimer.Tick += (_, _) =>
        {
            CancelDiscardTimer();
            handler(Event.Discard);
        };
        discardTimer.Start();
    }

    private void CancelAll()
    {
        CancelDiscardTimer();
        toggleActive = false;
        holdActive = false;
        keyDownAt = null;
        handler(Event.Cancel);
    }

    private void CancelDiscardTimer()
    {
        discardTimer?.Stop();
        discardTimer?.Dispose();
        discardTimer = null;
    }

    public void Dispose()
    {
        CancelDiscardTimer();
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
}
