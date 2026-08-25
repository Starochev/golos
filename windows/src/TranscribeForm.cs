using System.Drawing;

namespace Golos;

/// <summary>
/// Окно расшифровки файлов: перетащил запись встречи — получил текст
/// с тайм-кодами рядом с ней.
/// </summary>
public sealed class TranscribeForm : Form
{
    private sealed class Item
    {
        public string Path = "";
        public string Status = "В очереди";
        public double Progress;
        public FileTranscriber.Result? Result;
        public bool Failed;
    }

    private readonly Func<FileTranscriber?> makeTranscriber;
    private readonly Func<Config> currentConfig;
    private readonly List<Item> items = new();

    private readonly Panel dropArea = new();
    private readonly Label hint = new();
    private readonly FlowLayoutPanel list = new();
    private bool running;

    public TranscribeForm(Func<FileTranscriber?> makeTranscriber, Func<Config> currentConfig)
    {
        this.makeTranscriber = makeTranscriber;
        this.currentConfig = currentConfig;

        Text = "Расшифровка файла";
        Icon = AppIcon.Load();
        Width = 660;
        Height = 580;
        StartPosition = FormStartPosition.CenterScreen;
        AllowDrop = true;

        BuildDropArea();

        hint.AutoSize = true;
        hint.ForeColor = SystemColors.GrayText;
        hint.Location = new Point(16, 176);
        Controls.Add(hint);

        list.Location = new Point(16, 202);
        list.Size = new Size(610, 330);
        list.FlowDirection = FlowDirection.TopDown;
        list.WrapContents = false;
        list.AutoScroll = true;
        list.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;
        Controls.Add(list);

        RefreshHint();
    }

    private void BuildDropArea()
    {
        dropArea.Location = new Point(16, 16);
        dropArea.Size = new Size(610, 150);
        dropArea.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        dropArea.AllowDrop = true;
        dropArea.BackColor = Color.FromArgb(246, 246, 248);
        dropArea.Paint += (_, e) =>
        {
            using var pen = new Pen(Color.FromArgb(150, 150, 160)) { DashStyle = System.Drawing.Drawing2D.DashStyle.Dash };
            e.Graphics.DrawRectangle(pen, 1, 1, dropArea.Width - 3, dropArea.Height - 3);
        };

        var title = new Label
        {
            Text = "Перетащи сюда запись встречи или созвона",
            Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold),
            AutoSize = true
        };
        var formats = new Label
        {
            Text = "Видео и звук: mp4, mov, m4a, mp3, wav и остальное, что читает система",
            ForeColor = SystemColors.GrayText,
            AutoSize = true
        };
        var choose = new Button { Text = "Выбрать файл…", Width = 150, Height = 26 };
        choose.Click += (_, _) => Choose();

        dropArea.Controls.Add(title);
        dropArea.Controls.Add(formats);
        dropArea.Controls.Add(choose);
        dropArea.Resize += (_, _) => CenterDropContents(title, formats, choose);
        CenterDropContents(title, formats, choose);

        // Перетаскивание ловим и на области, и на самом окне: мимо рамки
        // промахнуться проще, чем кажется.
        foreach (Control target in new Control[] { this, dropArea, title, formats })
        {
            target.AllowDrop = true;
            target.DragEnter += OnDragEnter;
            target.DragDrop += OnDragDrop;
        }

        Controls.Add(dropArea);
    }

    private void CenterDropContents(Label title, Label formats, Button choose)
    {
        title.Location = new Point((dropArea.Width - title.Width) / 2, 38);
        formats.Location = new Point((dropArea.Width - formats.Width) / 2, 66);
        choose.Location = new Point((dropArea.Width - choose.Width) / 2, 96);
    }

    private void OnDragEnter(object? sender, DragEventArgs e)
    {
        e.Effect = e.Data?.GetDataPresent(DataFormats.FileDrop) == true
            ? DragDropEffects.Copy
            : DragDropEffects.None;
    }

    private void OnDragDrop(object? sender, DragEventArgs e)
    {
        if (e.Data?.GetData(DataFormats.FileDrop) is string[] paths) Add(paths);
    }

    private void Choose()
    {
        using var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Filter = "Звук и видео|*.mp3;*.m4a;*.aac;*.wav;*.wma;*.flac;*.mp4;*.mov;*.m4v;*.mkv;*.avi;*.webm|Все файлы|*.*"
        };
        if (dialog.ShowDialog(this) == DialogResult.OK) Add(dialog.FileNames);
    }

    public void Add(IEnumerable<string> paths)
    {
        var fresh = paths
            .Where(p => MediaDecoder.SupportedExtensions.Contains(Path.GetExtension(p)))
            .Where(p => items.All(i => !string.Equals(i.Path, p, StringComparison.OrdinalIgnoreCase)))
            .ToList();
        if (fresh.Count == 0) return;

        foreach (var p in fresh) items.Add(new Item { Path = p });
        Redraw();
        _ = RunNextAsync();
    }

    private async Task RunNextAsync()
    {
        if (running) return;
        var item = items.FirstOrDefault(i => i.Result == null && !i.Failed && i.Status == "В очереди");
        if (item == null) return;

        var transcriber = makeTranscriber();
        if (transcriber == null)
        {
            item.Failed = true;
            item.Status = "Распознавание ещё не готово";
            Redraw();
            return;
        }

        running = true;
        try
        {
            item.Status = "Достаю звук";
            Redraw();

            var result = await transcriber.TranscribeAsync(item.Path, currentConfig(), (stage, fraction) =>
            {
                if (IsDisposed) return;
                BeginInvoke(() =>
                {
                    if (IsDisposed) return;
                    item.Progress = fraction;
                    item.Status = stage switch
                    {
                        FileTranscriber.Stage.Reading => $"Достаю звук — {fraction * 100:F0}%",
                        FileTranscriber.Stage.Recognizing => $"Распознаю — {fraction * 100:F0}%",
                        _ => "Записываю"
                    };
                    Redraw();
                });
            });

            item.Result = result;
            item.Status = $"{result.Segments} отрезков, {Length(result.Duration)}";
        }
        catch (OperationCanceledException)
        {
            item.Failed = true;
            item.Status = "Отменено";
        }
        catch (Exception e)
        {
            item.Failed = true;
            item.Status = e.Message;
            Log.Write($"расшифровка не удалась: {e.Message}");
        }
        finally
        {
            running = false;
            Redraw();
            await RunNextAsync();
        }
    }

    private static string Length(double seconds)
    {
        var t = (int)seconds;
        return t >= 3600 ? $"{t / 3600} ч {t % 3600 / 60:D2} мин" : $"{t / 60} мин {t % 60:D2} с";
    }

    private void RefreshHint()
    {
        var folder = currentConfig().FileOutputFolder.Trim();
        hint.Text = folder.Length == 0
            ? "Расшифровка ляжет рядом с исходным файлом"
            : $"Расшифровка ляжет в {folder}";
    }

    private void Redraw()
    {
        RefreshHint();
        list.SuspendLayout();
        list.Controls.Clear();

        foreach (var item in items)
        {
            var row = new Panel { Width = 580, Height = 58, BorderStyle = BorderStyle.FixedSingle };
            row.Controls.Add(new Label
            {
                Text = Path.GetFileName(item.Path),
                Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold),
                AutoSize = true,
                Location = new Point(10, 8)
            });
            row.Controls.Add(new Label
            {
                Text = item.Status,
                ForeColor = item.Failed ? Color.DarkRed : SystemColors.GrayText,
                AutoSize = true,
                Location = new Point(10, 30)
            });

            if (item.Result != null)
            {
                var show = new Button { Text = "Показать", Width = 110, Location = new Point(455, 16) };
                var target = item.Result.TextFile;
                show.Click += (_, _) =>
                {
                    try
                    {
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = "explorer.exe",
                            Arguments = $"/select,\"{target}\"",
                            UseShellExecute = true
                        });
                    }
                    catch (Exception e) { Log.Write($"не открылось {target}: {e.Message}"); }
                };
                row.Controls.Add(show);
            }

            list.Controls.Add(row);
        }
        list.ResumeLayout();
    }
}
