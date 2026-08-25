using System.Drawing;

namespace Golos;

/// <summary>Окно выбора модели с загрузкой.</summary>
public sealed class ModelPickerForm : Form
{
    private readonly Config config;
    private readonly ModelDownloader downloader = new();
    private readonly ProgressBar progress = new() { Width = 560, Height = 10, Visible = false };
    private readonly Label progressLabel = new() { AutoSize = true, Visible = false };
    private readonly Button chooseButton = new() { Text = "Скачать и использовать", Width = 210 };
    private readonly Button cancelButton = new() { Text = "Отменить загрузку", Width = 170, Visible = false };
    private readonly List<RadioButton> radios = new();

    private ModelInfo selected = ModelCatalog.Recommended;

    /// <summary>Вызывается после смены модели: движок надо перезапустить.</summary>
    public Action? OnModelChanged;

    public ModelPickerForm()
    {
        config = Config.Load();

        Text = "Модель распознавания";
        Icon = AppIcon.Load();
        Width = 640;
        Height = 660;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MinimizeBox = false;
        MaximizeBox = false;

        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(14)
        };

        layout.Controls.Add(new Label
        {
            Text = "Модель качается один раз и работает на этом компьютере — записи никуда не отправляются.",
            AutoSize = true,
            MaximumSize = new Size(560, 0),
            ForeColor = SystemColors.GrayText,
            Margin = new Padding(0, 0, 0, 10)
        });

        foreach (var model in ModelCatalog.All) layout.Controls.Add(Card(model));

        progressLabel.Margin = new Padding(0, 10, 0, 2);
        layout.Controls.Add(progressLabel);
        layout.Controls.Add(progress);

        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 12, 0, 0) };
        chooseButton.Click += async (_, _) => await ChooseAsync();
        cancelButton.Click += (_, _) => downloader.Cancel();
        buttons.Controls.Add(chooseButton);
        buttons.Controls.Add(cancelButton);
        layout.Controls.Add(buttons);

        Controls.Add(layout);
        UpdateButton();
    }

    private Control Card(ModelInfo model)
    {
        var panel = new Panel
        {
            Width = 560,
            Height = 108,
            BorderStyle = BorderStyle.FixedSingle,
            Margin = new Padding(0, 0, 0, 8)
        };

        var radio = new RadioButton
        {
            Text = model.Title,
            Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold),
            AutoSize = true,
            Location = new Point(10, 8),
            Checked = model.Id == config.ModelPath.Split('\\').LastOrDefault()?.Replace("ggml-", "").Replace(".bin", "")
                      || (model.Recommended && string.IsNullOrEmpty(config.ModelPath))
        };
        radio.CheckedChanged += (_, _) =>
        {
            if (!radio.Checked) return;
            selected = model;
            UpdateButton();
        };
        radios.Add(radio);
        panel.Controls.Add(radio);

        var badges = new List<string> { model.SizeText, model.SpeedNote };
        if (model.Recommended) badges.Insert(0, "рекомендуется");
        if (ModelCatalog.IsInstalled(model)) badges.Insert(0, "уже скачана");

        panel.Controls.Add(new Label
        {
            Text = string.Join("  ·  ", badges),
            AutoSize = true,
            Location = new Point(28, 30),
            ForeColor = SystemColors.GrayText
        });

        var lines = model.Pros.Select(p => "+ " + p).Concat(model.Cons.Select(c => "− " + c));
        panel.Controls.Add(new Label
        {
            Text = string.Join(Environment.NewLine, lines),
            AutoSize = false,
            Width = 530,
            Height = 56,
            Location = new Point(28, 48)
        });

        return panel;
    }

    private void UpdateButton()
    {
        chooseButton.Text = ModelCatalog.IsInstalled(selected) ? "Использовать" : "Скачать и использовать";
    }

    private async Task ChooseAsync()
    {
        var destination = ModelCatalog.LocalPath(selected);

        if (!ModelCatalog.IsInstalled(selected))
        {
            SetBusy(true, $"Качаю {selected.Title} — {selected.SizeText}");
            var error = await downloader.DownloadAsync(selected.Url, destination, ReportProgress);
            if (error != null)
            {
                SetBusy(false, "");
                MessageBox.Show(this, error, "Не скачалось", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (!File.Exists(destination)) { SetBusy(false, ""); return; }   // отменили
        }

        // Детектор речи весит меньше мегабайта — тянем молча.
        var vad = Path.Combine(ModelCatalog.Directory, ModelCatalog.VadFileName);
        if (!File.Exists(vad))
        {
            SetBusy(true, "Качаю детектор речи");
            await downloader.DownloadAsync(ModelCatalog.VadUrl, vad, ReportProgress);
        }

        var stored = Config.Load();
        stored.ModelPath = destination;
        stored.VadModelPath = File.Exists(vad) ? vad : "";
        stored.Save();
        Log.Write($"выбрана модель: {destination}");

        SetBusy(false, "");
        OnModelChanged?.Invoke();
        Close();
    }

    private void ReportProgress(long received, long total)
    {
        if (IsDisposed) return;
        BeginInvoke(() =>
        {
            if (IsDisposed) return;
            progress.Maximum = 1000;
            progress.Value = total > 0 ? (int)Math.Clamp(received * 1000 / total, 0, 1000) : 0;
            progressLabel.Text = total > 0
                ? $"{received / 1_048_576} из {total / 1_048_576} МБ"
                : $"{received / 1_048_576} МБ";
        });
    }

    private void SetBusy(bool busy, string title)
    {
        progress.Visible = busy;
        progressLabel.Visible = busy;
        cancelButton.Visible = busy;
        chooseButton.Enabled = !busy;
        foreach (var radio in radios) radio.Enabled = !busy;
        if (busy) progressLabel.Text = title;
    }
}
