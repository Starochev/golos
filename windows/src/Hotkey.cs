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
    public enum Event { StartHold, FinishHold, ToggleOn, ToggleOff, Cancel, Discard, FlipMode }

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_ESCAPE = 0x1B;

    /// <summary>Какая клавиша слушается. Меняется на лету.</summary>
    private HotkeyOption option = HotkeyOption.Fallback;

    /// <summary>
    /// Вторая клавиша записи. Работает наравне с основной: до одной не всегда
    /// дотянуться, а менять настройку ради каждого случая незачем.
    /// </summary>
    private HotkeyOption? secondOption;

    /// <summary>Обе клавиши записи.</summary>
    private IEnumerable<HotkeyOption> RecordKeys
    {
        get
        {
            yield return option;
            if (secondOption != null) yield return secondOption;
        }
    }

    /// <summary>Какая клавиша начала текущий жест. Вторая в чужой не лезет.</summary>
    private string? activeKeyId;

    /// <summary>
    /// Клавиша, которая во время записи переключает «текст или звук».
    /// Ничего не запускает и не останавливает, поэтому настройки под неё нет.
    /// Берём первый свободный модификатор: занятый под запись не годится.
    /// </summary>
    private HotkeyOption ModeKey
    {
        get
        {
            var taken = RecordKeys.Select(k => k.Id).ToHashSet();
            foreach (var id in new[] { "rightControl", "rightOption", "rightCommand", "rightShift" })
                if (!taken.Contains(id)) return HotkeyOption.Named(id);
            return HotkeyOption.Named("rightControl");
        }
    }

    private bool modeKeyDown;

    public void SetOption(HotkeyOption newOption)
    {
        if (newOption.Id == option.Id) return;
        Reset();
        option = newOption;
        if (secondOption?.Id == newOption.Id) secondOption = null;
        Log.Write($"клавиша записи: {newOption.Title}");
    }

    /// <summary>Вторая клавиша. null — выключена. Совпасть с основной не может.</summary>
    public void SetSecondOption(HotkeyOption? newOption)
    {
        var resolved = newOption?.Id == option.Id ? null : newOption;
        if (resolved?.Id == secondOption?.Id) return;
        Reset();
        secondOption = resolved;
        Log.Write($"вторая клавиша записи: {resolved?.Title ?? "выключена"}");
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
        modeKeyDown = false;
        activeKeyId = null;
    }

    private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(hook, nCode, wParam, lParam);

        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        var message = (int)wParam;

        var down = message is WM_KEYDOWN or WM_SYSKEYDOWN;
        var up = message is WM_KEYUP or WM_SYSKEYUP;

        var hit = RecordKeys.FirstOrDefault(k => info.vkCode == (uint)k.VirtualKey);
        if (hit != null)
        {
            // Автоповтор при удержании шлёт keydown пачками — KeyPressed
            // отсекает их сам.
            if (down) KeyPressed(hit.Id);
            else if (up) KeyReleased(hit.Id);

            // Модификаторы проглатываем: иначе одиночный Alt или Windows
            // отдаст фокус меню. Обычные клавиши вроде F13 пропускаем —
            // мешать они всё равно никому не будут.
            return hit.IsModifier ? (IntPtr)1 : CallNextHookEx(hook, nCode, wParam, lParam);
        }

        // Смена режима: только пока идёт запись, только на нажатие.
        if (info.vkCode == (uint)ModeKey.VirtualKey && (holdActive || toggleActive))
        {
            if (down && !modeKeyDown)
            {
                modeKeyDown = true;
                handler(Event.FlipMode);
            }
            else if (up) modeKeyDown = false;
            return ModeKey.IsModifier ? (IntPtr)1 : CallNextHookEx(hook, nCode, wParam, lParam);
        }
        if (up && info.vkCode == (uint)ModeKey.VirtualKey) modeKeyDown = false;

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

    private void KeyPressed(string id)
    {
        // Чужой жест не перебиваем: одна запись за раз.
        if (activeKeyId != null && activeKeyId != id) return;
        activeKeyId = id;

        // Автоповтор при удержании шлёт keydown пачками — считаем только первый.
        if (holdActive) return;

        if (toggleActive)
        {
            toggleActive = false;
            keyDownAt = null;
            activeKeyId = null;
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

    private void KeyReleased(string id)
    {
        if (activeKeyId != id) return;
        if (!holdActive || keyDownAt == null) return;
        holdActive = false;
        var held = DateTime.UtcNow - keyDownAt.Value;
        keyDownAt = null;

        if (held >= TapThreshold)
        {
            activeKeyId = null;
            handler(Event.FinishHold);
            return;
        }

        // Короткий тап: ждём напарника. Не пришёл — записанное выбрасываем.
        discardTimer = new System.Windows.Forms.Timer { Interval = DoubleTapWindowMs };
        discardTimer.Tick += (_, _) =>
        {
            CancelDiscardTimer();
            activeKeyId = null;
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
        modeKeyDown = false;
        activeKeyId = null;
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
