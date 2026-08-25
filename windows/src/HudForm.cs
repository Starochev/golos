using System.Drawing;
using System.Drawing.Drawing2D;

namespace Golos;

/// <summary>
/// Всплывающее окошко с живой волной во время записи.
///
/// Окно принципиально не активируется и не принимает мышь: приложение
/// вставляет текст в то окно, которое было активным, и любая кража фокуса
/// сломала бы главный сценарий.
/// </summary>
public sealed class HudForm : Form
{
    public enum Phase { Recording, Transcribing, Message }

    /// <summary>Чем отдать запись: текстом в активное окно или звуком в буфер.</summary>
    public enum Mode { Text, Audio }

    private const int BarCount = 34;
    private readonly float[] levels = new float[BarCount];
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 33 };
    private Func<float>? levelSource;
    private Phase phase = Phase.Recording;
    private Color waveColor = Color.FromArgb(255, 69, 58);
    private float tick;
    private string message = "";

    private Mode mode = Mode.Text;
    /// <summary>Положение пилюли: 0 — «Текст», 1 — «Звук». Едет плавно.</summary>
    private float pill;
    /// <summary>Щёлкнули по переключателю мышью.</summary>
    public event Action<Mode>? ModeChanged;

    private const int SwitchWidth = 152;
    private const int SwitchHeight = 26;
    private const int PillWidth = 74;

    // Появление и уход: содержимое растёт из центра и проявляется.
    // Панель выскакивает поверх чужой работы, и резкое возникновение
    // из ниоткуда читается как сбой.
    private readonly System.Windows.Forms.Timer animation = new() { Interval = 16 };
    private const float AppearMs = 280f;
    private const float VanishMs = 240f;
    private float animProgress;      // 0 — спрятано, 1 — на месте
    private bool animGrowing;
    private DateTime animStarted;
    private const float MinScale = 0.86f;

    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            // Без WS_EX_TRANSPARENT: мышь нужна переключателю. Фокус при этом
            // не уезжает, за это отвечает WS_EX_NOACTIVATE.
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }

    public HudForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        Width = 260;
        Height = 108;
        BackColor = Color.FromArgb(13, 13, 15);
        DoubleBuffered = true;
        StartPosition = FormStartPosition.Manual;

        // Скруглённые углы через регион: без него окно выглядит наклейкой.
        using var path = Rounded(new Rectangle(0, 0, Width, Height), 20);
        Region = new Region(path);

        timer.Tick += (_, _) =>
        {
            Push(levelSource?.Invoke() ?? 0);
            StepPill();
            Invalidate();
        };
        animation.Tick += (_, _) => StepAnimation();
        Reset();
        ApplyScale(0);
    }

    public void ShowWave(Color color, Mode startMode, Func<float> source)
    {
        waveColor = color;
        levelSource = source;
        phase = Phase.Recording;
        mode = startMode;
        pill = startMode == Mode.Audio ? 1f : 0f;
        Reset();
        PositionOnActiveScreen();
        ApplyScale(0);
        if (!Visible) Show();
        timer.Start();
        StartAnimation(growing: true);
    }

    /// <summary>Запись кончилась, идёт распознавание — волна замирает.</summary>
    public void MarkTranscribing()
    {
        phase = Phase.Transcribing;
        // Таймер оставляем: точка должна дышать.
        Invalidate();
    }

    /// <summary>Показать выбранный режим. Хозяин режима не окошко, а TrayApp.</summary>
    public void SetMode(Mode value)
    {
        mode = value;
        Invalidate();
    }

    /// <summary>Короткая надпись вместо волны: «Пакую…», потом «В буфере».</summary>
    public void ShowMessage(string text, int hideAfterMs = 0)
    {
        message = text;
        phase = Phase.Message;
        Invalidate();
        if (hideAfterMs <= 0) return;
        var delay = new System.Windows.Forms.Timer { Interval = hideAfterMs };
        delay.Tick += (_, _) => { delay.Stop(); delay.Dispose(); HideWave(); };
        delay.Start();
    }

    /// <summary>Пилюля догоняет выбранный режим: движение читается как переключение.</summary>
    private void StepPill()
    {
        var target = mode == Mode.Audio ? 1f : 0f;
        if (Math.Abs(pill - target) < 0.01f) { pill = target; return; }
        pill += (target - pill) * 0.28f;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (phase != Phase.Recording) return;
        var box = SwitchRect();
        if (!box.Contains(e.Location)) return;
        var picked = e.X < box.X + box.Width / 2f ? Mode.Text : Mode.Audio;
        if (picked == mode) return;
        mode = picked;
        ModeChanged?.Invoke(picked);
        Invalidate();
    }

    private RectangleF SwitchRect()
    {
        // Содержимое: волна 42, отступ 9, переключатель 26 — всё по центру.
        var top = (Height - (42 + 9 + SwitchHeight)) / 2f + 42 + 9;
        return new RectangleF((Width - SwitchWidth) / 2f, top, SwitchWidth, SwitchHeight);
    }

    public void HideWave()
    {
        timer.Stop();
        if (!Visible) return;
        StartAnimation(growing: false);
    }

    private void StartAnimation(bool growing)
    {
        animGrowing = growing;
        animStarted = DateTime.UtcNow;
        animation.Start();
    }

    private void StepAnimation()
    {
        var elapsed = (float)(DateTime.UtcNow - animStarted).TotalMilliseconds;
        var span = animGrowing ? AppearMs : VanishMs;
        var linear = Math.Clamp(elapsed / span, 0f, 1f);

        // Кубическое смягчение: на появлении тормозим к концу, на уходе
        // разгоняемся — так движение читается как живое, а не как рывок.
        var eased = animGrowing
            ? 1 - (float)Math.Pow(1 - linear, 3)
            : (float)Math.Pow(1 - linear, 3);

        ApplyScale(animGrowing ? eased : eased);

        if (linear < 1f) return;

        animation.Stop();
        if (!animGrowing) Hide();
    }

    /// <summary>
    /// Масштаб задаётся регионом окна: само окно остаётся прежнего размера,
    /// а видимая часть растёт из центра. Растить окно бесполезно — картинка
    /// внутри осталась бы неподвижной, получилось бы выезжание.
    /// </summary>
    private void ApplyScale(float progress)
    {
        animProgress = Math.Clamp(progress, 0f, 1f);
        var scale = MinScale + (1f - MinScale) * animProgress;

        var w = Width * scale;
        var h = Height * scale;
        var rect = new RectangleF((Width - w) / 2f, (Height - h) / 2f, w, h);

        var old = Region;
        using (var path = Rounded(rect, 20 * scale)) Region = new Region(path);
        old?.Dispose();

        // Ниже 0.02 Windows уже не отрисовывает окно, но и держать его
        // полностью прозрачным незачем.
        Opacity = Math.Max(0.02, animProgress);
        Invalidate();
    }

    private RectangleF ContentRect
    {
        get
        {
            var scale = MinScale + (1f - MinScale) * animProgress;
            var w = Width * scale;
            var h = Height * scale;
            return new RectangleF((Width - w) / 2f, (Height - h) / 2f, w, h);
        }
    }

    private void Reset()
    {
        for (var i = 0; i < BarCount; i++) levels[i] = 0.06f;
        tick = 0;
    }

    /// <summary>Лента едет справа налево: свежая громкость приходит в правый край.</summary>
    private void Push(float level)
    {
        tick += 1;
        // В тишине полоски не замирают в ноль, а еле заметно дышат — иначе
        // окошко выглядит сломанным, пока человек набирает воздух.
        var idle = 0.05f + 0.03f * (float)Math.Sin(tick * 0.28);
        var target = Math.Max(idle, Math.Min(1f, level));

        Array.Copy(levels, 1, levels, 0, BarCount - 1);
        levels[BarCount - 1] = levels[BarCount - 2] * 0.3f + target * 0.7f;
    }

    private void PositionOnActiveScreen()
    {
        var screen = Screen.FromPoint(Cursor.Position);
        var area = screen.WorkingArea;
        Location = new Point(area.Left + (area.Width - Width) / 2, area.Bottom - Height - 90);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);

        var rect = ContentRect;
        var scale = rect.Width / Width;

        using (var border = new Pen(Color.FromArgb(36, 255, 255, 255)))
        using (var path = Rounded(new RectangleF(rect.X, rect.Y, rect.Width - 1, rect.Height - 1), 20 * scale))
            g.DrawPath(border, path);

        // Содержимое рисуем в системе координат окна, но сжатой к центру —
        // тогда полосы уменьшаются вместе с панелью.
        var state = g.Save();
        g.TranslateTransform(Width / 2f, Height / 2f);
        g.ScaleTransform(scale, scale);
        g.TranslateTransform(-Width / 2f, -Height / 2f);

        if (phase == Phase.Recording)
        {
            PaintWave(g);
            PaintSwitch(g);
        }
        else PaintNote(g, phase == Phase.Transcribing ? "Распознаю…" : message,
                       pulsing: phase == Phase.Transcribing);

        g.Restore(state);
    }

    private void PaintWave(Graphics g)
    {
        const float width = 4f;
        const float gap = 3.5f;
        var total = BarCount * width + (BarCount - 1) * gap;
        var x = (Width - total) / 2f;
        // Волна делит окно с переключателем, поэтому сидит выше центра.
        var centerY = (Height - (42 + 9 + SwitchHeight)) / 2f + 21;

        using var brush = new SolidBrush(waveColor);
        foreach (var level in levels)
        {
            var height = Math.Max(4f, level * 40f);
            using var path = Rounded(new RectangleF(x, centerY - height / 2f, width, height), width / 2f);
            g.FillPath(brush, path);
            x += width + gap;
        }
    }

    /// <summary>
    /// Переключатель «Текст или Звук». Пилюля переезжает плавно, чтобы
    /// движение читалось как переключение, а не как перерисовка.
    /// </summary>
    private void PaintSwitch(Graphics g)
    {
        var box = SwitchRect();

        using (var trough = new SolidBrush(Color.FromArgb(23, 255, 255, 255)))
        using (var path = Rounded(box, 9))
            g.FillPath(trough, path);

        var pillRect = new RectangleF(box.X + 2 + pill * (SwitchWidth - PillWidth - 4),
                                      box.Y + 2, PillWidth, SwitchHeight - 4);
        using (var brush = new SolidBrush(waveColor))
        using (var path = Rounded(pillRect, 8))
            g.FillPath(brush, path);

        // Белую волну не подписать белым по ней же: считаем яркость.
        var luminance = 0.299 * waveColor.R + 0.587 * waveColor.G + 0.114 * waveColor.B;
        var onPill = luminance > 153 ? Color.FromArgb(217, 0, 0, 0) : Color.White;
        var dim = Color.FromArgb(128, 255, 255, 255);

        using var chosenFont = new Font("Segoe UI Semibold", 8.5f);
        using var plainFont = new Font("Segoe UI", 8.5f);
        var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };

        void Label(string title, bool audio)
        {
            var selected = (mode == Mode.Audio) == audio;
            using var brush = new SolidBrush(selected ? onPill : dim);
            var half = new RectangleF(box.X + (audio ? SwitchWidth / 2f : 0), box.Y,
                                      SwitchWidth / 2f, SwitchHeight);
            g.DrawString(title, selected ? chosenFont : plainFont, brush, half, format);
        }
        Label("Текст", audio: false);
        Label("Звук", audio: true);
        format.Dispose();
    }

    private void PaintNote(Graphics g, string text, bool pulsing)
    {
        tick += 1;
        var pulse = pulsing ? 0.75f + 0.6f * (float)((Math.Sin(tick * 0.12) + 1) / 2) : 1f;
        var size = 8f * pulse;

        using var brush = new SolidBrush(waveColor);
        using var font = new Font("Segoe UI", 9.5f, FontStyle.Regular);
        using var textBrush = new SolidBrush(Color.FromArgb(230, 255, 255, 255));

        var textSize = g.MeasureString(text, font);
        var totalWidth = size + 8 + textSize.Width;
        var x = (Width - totalWidth) / 2f;
        var centerY = Height / 2f;

        g.FillEllipse(brush, x, centerY - size / 2f, size, size);
        g.DrawString(text, font, textBrush, x + size + 8, centerY - textSize.Height / 2f);
    }

    private static GraphicsPath Rounded(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { timer.Dispose(); animation.Dispose(); }
        base.Dispose(disposing);
    }
}
