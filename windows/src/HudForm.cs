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
    public enum Phase { Recording, Transcribing }

    private const int BarCount = 34;
    private readonly float[] levels = new float[BarCount];
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 33 };
    private Func<float>? levelSource;
    private Phase phase = Phase.Recording;
    private Color waveColor = Color.FromArgb(255, 69, 58);
    private float tick;

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
    private const int WS_EX_TRANSPARENT = 0x00000020;

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT;
            return cp;
        }
    }

    public HudForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        Width = 260;
        Height = 70;
        BackColor = Color.FromArgb(13, 13, 15);
        DoubleBuffered = true;
        StartPosition = FormStartPosition.Manual;

        // Скруглённые углы через регион: без него окно выглядит наклейкой.
        using var path = Rounded(new Rectangle(0, 0, Width, Height), 20);
        Region = new Region(path);

        timer.Tick += (_, _) =>
        {
            Push(levelSource?.Invoke() ?? 0);
            Invalidate();
        };
        animation.Tick += (_, _) => StepAnimation();
        Reset();
        ApplyScale(0);
    }

    public void ShowWave(Color color, Func<float> source)
    {
        waveColor = color;
        levelSource = source;
        phase = Phase.Recording;
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

        if (phase == Phase.Recording) PaintWave(g);
        else PaintTranscribing(g);

        g.Restore(state);
    }

    private void PaintWave(Graphics g)
    {
        const float width = 4f;
        const float gap = 3.5f;
        var total = BarCount * width + (BarCount - 1) * gap;
        var x = (Width - total) / 2f;
        var centerY = Height / 2f;

        using var brush = new SolidBrush(waveColor);
        foreach (var level in levels)
        {
            var height = Math.Max(4f, level * 44f);
            using var path = Rounded(new RectangleF(x, centerY - height / 2f, width, height), width / 2f);
            g.FillPath(brush, path);
            x += width + gap;
        }
    }

    private void PaintTranscribing(Graphics g)
    {
        tick += 1;
        var pulse = 0.75f + 0.6f * (float)((Math.Sin(tick * 0.12) + 1) / 2);
        var size = 8f * pulse;

        using var brush = new SolidBrush(waveColor);
        using var font = new Font("Segoe UI", 9.5f, FontStyle.Regular);
        using var textBrush = new SolidBrush(Color.FromArgb(230, 255, 255, 255));

        var text = "Распознаю…";
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
