using System.ComponentModel;
using System.Diagnostics;

namespace Golos;

/// <summary>
/// Окно настроек с вкладками. Кнопки «Сохранить» нет намеренно: конфиг
/// перечитывается перед каждой диктовкой, поэтому правка вступает в силу сразу.
/// </summary>
public sealed class SettingsForm : Form
{
    private Config config;
    private readonly BindingList<Config.Replacement> replacements;
    private readonly ListBox vocabularyList = new();
    private readonly TextBox newTermBox = new();
    private readonly Label budgetLabel = new();
    private readonly ProgressBar budgetBar = new();
    private readonly Label problemLabel = new();
    private readonly Candidates candidates = new();

    public SettingsForm()
    {
        config = Config.Load();
        replacements = new BindingList<Config.Replacement>(config.Replacements);
        replacements.ListChanged += (_, _) => Save();

        Text = "Настройки Голоса";
        Icon = AppIcon.Load();
        Width = 660;
        Height = 600;
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;
        MaximizeBox = false;
        FormBorderStyle = FormBorderStyle.FixedDialog;

        var tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(12, 6) };
        tabs.TabPages.Add(GeneralTab());
        tabs.TabPages.Add(VocabularyTab());
        tabs.TabPages.Add(ReplacementsTab());
        tabs.TabPages.Add(CandidatesTab());
        tabs.TabPages.Add(AboutTab());
        Controls.Add(tabs);

        RefreshVocabulary();
    }

    private void Save()
    {
        config.Replacements = replacements.ToList();
        config.Save();
    }

    // MARK: Основное

    private TabPage GeneralTab()
    {
        var page = new TabPage("Основное") { Padding = new Padding(14) };
        var layout = Column();

        var autostart = new CheckBox
        {
            Text = "Запускать при входе в систему",
            Checked = Autostart.IsEnabled,
            AutoSize = true
        };
        var autostartNote = Hint(AutostartNote());
        autostart.CheckedChanged += (_, _) =>
        {
            var error = Autostart.Set(autostart.Checked);
            // Система могла отказать — показываем правду, а не галочку.
            autostart.Checked = Autostart.IsEnabled;
            autostartNote.Text = error ?? AutostartNote();
        };
        layout.Controls.Add(Header("Поведение"));
        layout.Controls.Add(autostart);
        layout.Controls.Add(autostartNote);

        layout.Controls.Add(Header("Микрофон"));
        var mic = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 560 };
        mic.Items.Add("Системный по умолчанию");
        foreach (var (_, name) in Recorder.Devices()) mic.Items.Add(name);
        mic.SelectedIndex = 0;
        for (var i = 1; i < mic.Items.Count; i++)
            if (string.Equals(mic.Items[i]?.ToString(), config.InputDevice, StringComparison.OrdinalIgnoreCase))
                mic.SelectedIndex = i;
        // Подписываемся после установки начального значения. Иначе сама
        // расстановка выбора считается правкой: у отключённой гарнитуры
        // выбранного пункта в списке нет, и открытие настроек молча стирало бы
        // сохранённый микрофон.
        mic.SelectedIndexChanged += (_, _) =>
        {
            config.InputDevice = mic.SelectedIndex <= 0 ? "" : mic.SelectedItem?.ToString() ?? "";
            Save();
        };
        layout.Controls.Add(mic);
        layout.Controls.Add(Hint("Имена приходят из системы и обрезаны до 31 символа — это ограничение Windows, а не приложения."));

        layout.Controls.Add(Header("Клавиша записи"));
        var hotkeyBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
        foreach (var option in HotkeyOption.All) hotkeyBox.Items.Add(option.Title);
        hotkeyBox.SelectedIndex = Math.Max(0, Array.FindIndex(HotkeyOption.All, o => o.Id == config.Hotkey));
        var hotkeyNote = Hint(HotkeyOption.Named(config.Hotkey).Note);
        var secondBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
        // Первым пунктом «выключено», дальше всё, кроме основной клавиши.
        var secondIds = new List<string>();
        void FillSecond()
        {
            secondBox.Items.Clear();
            secondIds.Clear();
            secondBox.Items.Add("Выключено");
            secondIds.Add("");
            foreach (var option in HotkeyOption.All.Where(o => o.Id != config.Hotkey))
            {
                secondBox.Items.Add(option.Title);
                secondIds.Add(option.Id);
            }
            secondBox.SelectedIndex = Math.Max(0, secondIds.IndexOf(config.SecondHotkey));
        }


        hotkeyBox.SelectedIndexChanged += (_, _) =>
        {
            var chosen = HotkeyOption.All[hotkeyBox.SelectedIndex];
            config.Hotkey = chosen.Id;
            hotkeyNote.Text = chosen.Note;
            if (config.SecondHotkey == chosen.Id) config.SecondHotkey = "";
            Save();
            FillSecond();
        };
        layout.Controls.Add(hotkeyBox);
        layout.Controls.Add(hotkeyNote);
        layout.Controls.Add(Header("Вторая клавиша"));
        FillSecond();
        secondBox.SelectedIndexChanged += (_, _) =>
        {
            if (secondBox.SelectedIndex < 0) return;
            config.SecondHotkey = secondIds[secondBox.SelectedIndex];
            Save();
        };
        layout.Controls.Add(secondBox);
        layout.Controls.Add(Hint("Работает наравне с основной. Удобно, когда до основной не всегда дотянуться, а лезть в настройки ради этого не хочется. Применяется после закрытия окна."));

        layout.Controls.Add(Hint("Список закрыт намеренно: обычную букву назначить нельзя, иначе каждое её нажатие уходило бы в диктовку. Применяется после закрытия окна."));

        layout.Controls.Add(Header("Окошко с волной"));
        var showHud = new CheckBox { Text = "Показывать волну во время записи", Checked = config.ShowHUD, AutoSize = true };
        showHud.CheckedChanged += (_, _) => { config.ShowHUD = showHud.Checked; Save(); };
        layout.Controls.Add(showHud);

        var colorRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        var colorBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
        foreach (var theme in WaveTheme.All) colorBox.Items.Add(theme.Title);
        colorBox.Items.Add("Свой цвет…");
        var themeIndex = Array.FindIndex(WaveTheme.All, t => t.Id == config.WaveTheme);
        colorBox.SelectedIndex = themeIndex >= 0 ? themeIndex : WaveTheme.All.Length;

        var swatch = new Panel { Width = 26, Height = 22, BorderStyle = BorderStyle.FixedSingle,
                                 BackColor = WaveTheme.ColorFor(config), Margin = new Padding(8, 2, 0, 0) };
        colorBox.SelectedIndexChanged += (_, _) =>
        {
            if (colorBox.SelectedIndex < WaveTheme.All.Length)
            {
                config.WaveTheme = WaveTheme.All[colorBox.SelectedIndex].Id;
            }
            else
            {
                using var dialog = new ColorDialog { Color = WaveTheme.ColorFor(config), FullOpen = true };
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    config.WaveTheme = WaveTheme.CustomId;
                    config.CustomWaveColor = WaveTheme.ToHex(dialog.Color);
                }
            }
            swatch.BackColor = WaveTheme.ColorFor(config);
            Save();
        };
        colorRow.Controls.Add(colorBox);
        colorRow.Controls.Add(swatch);
        layout.Controls.Add(Header("Цвет волны"));
        layout.Controls.Add(colorRow);
        layout.Controls.Add(Hint("Красит и окошко записи, и значок в трее, пока идёт запись."));

        layout.Controls.Add(Header("Модель распознавания"));
        var modelRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        var modelLabel = new Label
        {
            Text = ModelTitle(config.ModelPath),
            AutoSize = true,
            Margin = new Padding(0, 6, 12, 0)
        };
        var modelButton = new Button { Text = "Сменить…", Width = 130 };
        modelButton.Click += (_, _) =>
        {
            using var picker = new ModelPickerForm();
            picker.OnModelChanged = () =>
            {
                config = Config.Load();
                modelLabel.Text = ModelTitle(config.ModelPath);
            };
            picker.ShowDialog(this);
        };
        modelRow.Controls.Add(modelLabel);
        modelRow.Controls.Add(modelButton);
        layout.Controls.Add(modelRow);

        layout.Controls.Add(Header("Движок распознавания"));
        var engineRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        var engineLabel = new Label
        {
            Text = EngineCatalog.Describe(config),
            AutoSize = true,
            Margin = new Padding(0, 6, 12, 0),
            ForeColor = SystemColors.GrayText
        };
        var engineProgress = new ProgressBar
        {
            Width = 480, Height = 10, Maximum = 1000, Visible = false,
            Margin = new Padding(0, 4, 0, 0)
        };
        var cudaButton = new Button
        {
            Text = EngineCatalog.CudaInstalled ? "Переставить CUDA…" : "Скачать под NVIDIA…",
            Width = 180
        };
        var pickEngine = new Button { Text = "Своя папка…", Width = 120 };
        var resetEngine = new Button { Text = "Сбросить", Width = 100 };

        var downloader = new ModelDownloader();
        var downloading = false;

        cudaButton.Click += async (_, _) =>
        {
            if (downloading) { downloader.Cancel(); return; }

            var megabytes = EngineCatalog.CudaSizeBytes / 1_048_576;
            var ask = MessageBox.Show(this,
                $"Сборка под видеокарту весит около {megabytes} МБ.\n\n" +
                "Нужна видеокарта NVIDIA с драйвером 12.x. Без неё останется\n" +
                "встроенная процессорная сборка, она тоже работает, только медленнее.",
                "Движок под видеокарту", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
            if (ask != DialogResult.OK) return;

            var zip = Path.Combine(Path.GetTempPath(), EngineCatalog.CudaAsset);
            downloading = true;
            cudaButton.Text = "Отменить";
            pickEngine.Enabled = resetEngine.Enabled = false;
            engineProgress.Visible = true;

            var error = await downloader.DownloadAsync(EngineCatalog.CudaUrl, zip, (got, total) =>
                BeginInvoke(() =>
                {
                    engineProgress.Value = total > 0 ? (int)Math.Clamp(got * 1000 / total, 0, 1000) : 0;
                    engineLabel.Text = total > 0
                        ? $"качаю: {got / 1_048_576} из {total / 1_048_576} МБ"
                        : $"качаю: {got / 1_048_576} МБ";
                }));

            // Отменённая закачка не оставляет файла — распаковывать нечего.
            if (error == null && File.Exists(zip))
            {
                engineProgress.Style = ProgressBarStyle.Marquee;
                engineLabel.Text = "распаковываю…";
                error = await Task.Run(() => EngineCatalog.UnpackCuda(zip));
                engineProgress.Style = ProgressBarStyle.Blocks;
                try { File.Delete(zip); } catch { }

                if (error == null)
                {
                    config.EnginePath = "";
                    Save();
                }
            }

            downloading = false;
            engineProgress.Visible = false;
            cudaButton.Text = EngineCatalog.CudaInstalled ? "Переставить CUDA…" : "Скачать под NVIDIA…";
            pickEngine.Enabled = resetEngine.Enabled = true;
            engineLabel.Text = EngineCatalog.Describe(config);

            if (error != null)
                MessageBox.Show(this, error, "Не вышло", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        };

        pickEngine.Click += (_, _) =>
        {
            using var dialog = new FolderBrowserDialog();
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            if (EngineCatalog.Find(dialog.SelectedPath) == null)
            {
                MessageBox.Show(this, "В этой папке нет whisper-server.exe",
                                "Не тот каталог", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            config.EnginePath = dialog.SelectedPath;
            Save();
            engineLabel.Text = EngineCatalog.Describe(config);
        };

        resetEngine.Click += (_, _) =>
        {
            config.EnginePath = "";
            Save();
            engineLabel.Text = EngineCatalog.Describe(config);
        };

        engineRow.Controls.Add(engineLabel);
        engineRow.Controls.Add(cudaButton);
        engineRow.Controls.Add(pickEngine);
        engineRow.Controls.Add(resetEngine);
        layout.Controls.Add(engineRow);
        layout.Controls.Add(engineProgress);
        layout.Controls.Add(Hint("Процессорная сборка лежит внутри приложения и работает сразу. На видеокарте NVIDIA распознавание идёт в разы быстрее, но её сборку приходится качать отдельно: она слишком тяжёлая, чтобы носить её всем. Смена применится после перезапуска приложения."));

        layout.Controls.Add(Header("Знак в конце фразы"));
        var punctuation = new ComboBox { Width = 260, DropDownStyle = ComboBoxStyle.DropDownList };
        var punctuationIds = new[] { "keep", "period", "any" };
        punctuation.Items.AddRange(new object[] { "Как распознано", "Убирать точку", "Убирать любой знак" });
        punctuation.SelectedIndex = Math.Max(0, Array.IndexOf(punctuationIds, config.FinalPunctuation));
        punctuation.SelectedIndexChanged += (_, _) =>
        {
            config.FinalPunctuation = punctuationIds[punctuation.SelectedIndex];
            Save();
        };
        layout.Controls.Add(punctuation);
        layout.Controls.Add(Hint("Знаки препинания расставляет сама модель, по интонации и смыслу. Отдельной ручки у неё нет, и вопросительный знак она иногда пропускает. Убрать лишнее с конца можно, доставить нужное нет. На расшифровку файлов не влияет."));

        layout.Controls.Add(Header("Расшифровка файлов"));
        var folderRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        var folderLabel = new Label
        {
            Text = FolderTitle(),
            AutoSize = true,
            Margin = new Padding(0, 6, 12, 0),
            ForeColor = SystemColors.GrayText
        };
        var pick = new Button { Text = "Выбрать…", Width = 110 };
        pick.Click += (_, _) =>
        {
            using var dialog = new FolderBrowserDialog();
            if (dialog.ShowDialog(this) == DialogResult.OK)
            {
                config.FileOutputFolder = dialog.SelectedPath;
                folderLabel.Text = FolderTitle();
                Save();
            }
        };
        var reset = new Button { Text = "Рядом с файлом", Width = 150 };
        reset.Click += (_, _) =>
        {
            config.FileOutputFolder = "";
            folderLabel.Text = FolderTitle();
            Save();
        };
        folderRow.Controls.Add(folderLabel);
        folderRow.Controls.Add(pick);
        folderRow.Controls.Add(reset);
        layout.Controls.Add(folderRow);
        layout.Controls.Add(Hint("По умолчанию расшифровка ложится рядом с исходным файлом. Рядом же появляется файл субтитров."));

        var keepAudio = new CheckBox
        {
            Text = "Оставлять переконвертированный звук",
            Checked = config.KeepConvertedAudio,
            AutoSize = true
        };
        keepAudio.CheckedChanged += (_, _) => { config.KeepConvertedAudio = keepAudio.Checked; Save(); };
        layout.Controls.Add(keepAudio);
        layout.Controls.Add(Hint("Для распознавания файл приводится к моно 16 кГц. Обычно этот wav не нужен, но иногда удобно послушать ровно то, что слышала модель."));

        layout.Controls.Add(Header("Язык речи"));
        var language = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
        language.Items.AddRange(new object[] { "Русский", "Английский", "Определять автоматически" });
        language.SelectedIndex = config.Language switch { "en" => 1, "auto" => 2, _ => 0 };
        language.SelectedIndexChanged += (_, _) =>
        {
            config.Language = language.SelectedIndex switch { 1 => "en", 2 => "auto", _ => "ru" };
            Save();
        };
        layout.Controls.Add(language);
        layout.Controls.Add(Hint("Русский распознаёт и англицизмы внутри русской речи — переключать не нужно. Смена языка применится после перезапуска приложения."));

        layout.Controls.Add(Header("Куда девать текст"));
        var insert = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 320 };
        insert.Items.AddRange(new object[] { "Вставлять в активное поле", "Только копировать в буфер" });
        insert.SelectedIndex = config.InsertMode == "clipboard" ? 1 : 0;
        insert.SelectedIndexChanged += (_, _) =>
        {
            config.InsertMode = insert.SelectedIndex == 1 ? "clipboard" : "paste";
            Save();
        };
        layout.Controls.Add(insert);

        var sounds = new CheckBox { Text = "Звук при начале и конце записи", Checked = config.Sounds, AutoSize = true };
        sounds.CheckedChanged += (_, _) => { config.Sounds = sounds.Checked; Save(); };
        layout.Controls.Add(Spacer());
        layout.Controls.Add(sounds);

        var soundRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        var soundBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
        foreach (var theme in Sounds.Themes) soundBox.Items.Add(theme.Title);
        soundBox.SelectedIndex = Math.Max(0, Array.FindIndex(Sounds.Themes, t => t.Id == config.SoundTheme));
        var soundNote = Hint(Sounds.ThemeOf(config.SoundTheme).Note);
        soundBox.SelectedIndexChanged += (_, _) =>
        {
            var chosen = Sounds.Themes[soundBox.SelectedIndex];
            config.SoundTheme = chosen.Id;
            soundNote.Text = chosen.Note;
            Save();
            Preview();
        };
        var preview = new Button { Text = "Прослушать", Width = 120, Margin = new Padding(8, 0, 0, 0) };
        preview.Click += (_, _) => Preview();
        soundRow.Controls.Add(soundBox);
        soundRow.Controls.Add(preview);
        layout.Controls.Add(soundRow);
        layout.Controls.Add(soundNote);

        var history = new CheckBox { Text = "Хранить записи и расшифровки", Checked = config.KeepHistory, AutoSize = true };
        history.CheckedChanged += (_, _) => { config.KeepHistory = history.Checked; Save(); };
        layout.Controls.Add(history);
        layout.Controls.Add(Hint("На каждую диктовку сохраняется аудиофайл и текст. Нужно, чтобы послушать, что распознавание услышало в неудачной фразе."));

        var retention = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
        retention.Items.AddRange(new object[] { "Удалять через час", "Через сутки", "Через неделю", "Не удалять" });
        retention.SelectedIndex = config.HistoryRetentionHours switch { 24 => 1, 168 => 2, 0 => 3, _ => 0 };
        retention.SelectedIndexChanged += (_, _) =>
        {
            config.HistoryRetentionHours = retention.SelectedIndex switch { 1 => 24, 2 => 168, 3 => 0, _ => 1 };
            Save();
        };
        layout.Controls.Add(retention);

        page.Controls.Add(layout);
        return page;
    }

    private string FolderTitle()
    {
        var stored = config.FileOutputFolder.Trim();
        return stored.Length == 0 ? "рядом с файлом" : stored;
    }

    private static string AutostartNote()
    {
        if (!Autostart.IsEnabled) return "Приложение будет само подниматься после перезагрузки.";
        return Autostart.PathIsStale
            ? "В реестре записан другой путь — похоже, приложение переносили. Переставь галочку."
            : "Включено.";
    }

    private static string ModelTitle(string path)
    {
        var file = Path.GetFileName(path);
        if (string.IsNullOrEmpty(file)) return "не выбрана";
        var match = ModelCatalog.All.FirstOrDefault(m => m.FileName == file);
        return match?.Title ?? file;
    }

    /// <summary>Проигрываем обе метки подряд — так слышно пару целиком.</summary>
    private void Preview()
    {
        Sounds.Play(Sounds.Moment.Start, config.SoundTheme);
        var timer = new System.Windows.Forms.Timer { Interval = 550 };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            timer.Dispose();
            Sounds.Play(Sounds.Moment.Stop, config.SoundTheme);
        };
        timer.Start();
    }

    // MARK: Словарь

    private TabPage VocabularyTab()
    {
        var page = new TabPage("Словарь") { Padding = new Padding(14) };
        var layout = Column();

        layout.Controls.Add(Header("Слова, которые нужно писать латиницей"));
        layout.Controls.Add(Hint("Подсказка распознаванию: перечисленное здесь оно будет писать как написано, а не транслитом. Русские слова добавлять не нужно."));
        var vocabWarning = Hint("Держи список коротким. Словарь идёт в распознавание подсказкой и влияет не только на перечисленные слова: чем он длиннее, тем чаще модель срывается на соседних кусках речи и подставляет выдуманную фразу вместо сказанного. Добавляй только то, что действительно произносишь и что распознаётся неверно.");
        vocabWarning.ForeColor = Color.DarkOrange;
        layout.Controls.Add(vocabWarning);

        var row = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 4, 0, 4) };
        newTermBox.Width = 420;
        newTermBox.PlaceholderText = "Например: pull request";
        newTermBox.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { AddTerm(); e.SuppressKeyPress = true; } };
        var addButton = new Button { Text = "Добавить", Width = 110 };
        addButton.Click += (_, _) => AddTerm();
        row.Controls.Add(newTermBox);
        row.Controls.Add(addButton);
        layout.Controls.Add(row);

        problemLabel.ForeColor = Color.DarkOrange;
        problemLabel.AutoSize = true;
        layout.Controls.Add(problemLabel);

        vocabularyList.Width = 560;
        vocabularyList.Height = 240;
        vocabularyList.KeyDown += (_, e) => { if (e.KeyCode == Keys.Delete) RemoveTerm(); };
        layout.Controls.Add(vocabularyList);

        var removeButton = new Button { Text = "Удалить выбранное", Width = 180 };
        removeButton.Click += (_, _) => RemoveTerm();
        layout.Controls.Add(removeButton);

        budgetBar.Width = 560;
        budgetBar.Height = 8;
        budgetBar.Maximum = Config.PromptCharacterBudget;
        budgetLabel.AutoSize = true;
        layout.Controls.Add(budgetLabel);
        layout.Controls.Add(budgetBar);
        layout.Controls.Add(Hint("У подсказки жёсткий потолок: всё, что не влезло, распознавание просто не увидит."));

        page.Controls.Add(layout);
        return page;
    }

    private void AddTerm()
    {
        var problem = AddTerm(newTermBox.Text);
        problemLabel.Text = problem ?? "";
        if (problem == null) newTermBox.Text = "";
    }

    /// <summary>Возвращает причину отказа или null, если слово добавлено.</summary>
    private string? AddTerm(string raw)
    {
        var term = raw.Trim();
        if (term.Length == 0) return "Пустая строка";
        if (config.Vocabulary.Any(t => string.Equals(t, term, StringComparison.OrdinalIgnoreCase)))
            return $"«{term}» уже в списке";
        config.Vocabulary.Add(term);
        Save();
        RefreshVocabulary();
        return null;
    }

    private void RemoveTerm()
    {
        if (vocabularyList.SelectedItem is not string term) return;
        config.Vocabulary.Remove(term);
        Save();
        RefreshVocabulary();
    }

    private void RefreshVocabulary()
    {
        vocabularyList.BeginUpdate();
        vocabularyList.Items.Clear();
        foreach (var term in config.Vocabulary) vocabularyList.Items.Add(term);
        vocabularyList.EndUpdate();

        var used = config.Vocabulary.Sum(t => t.Length + 2);
        budgetBar.Value = Math.Min(used, Config.PromptCharacterBudget);
        budgetLabel.Text = $"{config.Vocabulary.Count} слов, {used} из {Config.PromptCharacterBudget} символов";
        budgetLabel.ForeColor = used > Config.PromptCharacterBudget ? Color.DarkOrange : SystemColors.GrayText;
    }

    // MARK: Замены

    private TabPage ReplacementsTab()
    {
        var page = new TabPage("Замены") { Padding = new Padding(14) };
        var layout = Column();

        layout.Controls.Add(Header("Исправления готового текста"));
        layout.Controls.Add(Hint("Если распознавание стабильно ошибается на слове, впиши, что слышится и чем это заменить. Замена без учёта регистра."));

        var grid = new DataGridView
        {
            Width = 560,
            Height = 320,
            AutoGenerateColumns = false,
            AllowUserToAddRows = true,
            AllowUserToDeleteRows = true,
            RowHeadersVisible = false,
            SelectionMode = DataGridViewSelectionMode.FullRowSelect,
            DataSource = replacements
        };
        grid.Columns.Add(new DataGridViewTextBoxColumn
        {
            HeaderText = "Слышится", DataPropertyName = nameof(Config.Replacement.From), Width = 260
        });
        grid.Columns.Add(new DataGridViewTextBoxColumn
        {
            HeaderText = "Писать", DataPropertyName = nameof(Config.Replacement.To), Width = 260
        });
        layout.Controls.Add(grid);
        layout.Controls.Add(Hint("Новая строка добавляется в последней, пустой. Удалить — выделить строку и нажать Delete."));

        page.Controls.Add(layout);
        return page;
    }

    // MARK: О программе

    private TabPage AboutTab()
    {
        var page = new TabPage("О программе") { Padding = new Padding(14) };
        var layout = Column();

        var version = typeof(SettingsForm).Assembly.GetName().Version?.ToString(3) ?? "?";
        layout.Controls.Add(Header($"Голос {version}"));
        layout.Controls.Add(Hint("Голосовой ввод с распознаванием на этом компьютере. Записи никуда не отправляются."));
        layout.Controls.Add(Spacer());

        layout.Controls.Add(Header("Горячие клавиши"));
        var key = HotkeyOption.Named(config.Hotkey).Title;
        layout.Controls.Add(Hint($"Держать {key} — запись, пока держишь.\nДвойной тап — запись до следующего тапа.\nEscape во время записи — отменить без вставки."));
        layout.Controls.Add(Spacer());

        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        buttons.Controls.Add(Link("Журнал", Log.FilePath));
        buttons.Controls.Add(Link("Папка записей", Path.Combine(Config.Directory, "history")));
        buttons.Controls.Add(Link("Файл настроек", Config.FilePath));
        layout.Controls.Add(buttons);

        page.Controls.Add(layout);
        return page;
    }

    private static Button Link(string title, string path)
    {
        var button = new Button { Text = title, Width = 150, Margin = new Padding(0, 0, 8, 0) };
        button.Click += (_, _) =>
        {
            try
            {
                if (Directory.Exists(path) || File.Exists(path))
                    Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            }
            catch (Exception e) { Log.Write($"не открылось {path}: {e.Message}"); }
        };
        return button;
    }

    // MARK: Мелочи разметки

    private static FlowLayoutPanel Column() => new()
    {
        Dock = DockStyle.Fill,
        FlowDirection = FlowDirection.TopDown,
        WrapContents = false,
        AutoScroll = true
    };

    /// <summary>
    /// Слова, в которых модель сомневалась, с предложением занести их в словарь.
    /// Показываем не всё подряд: отсеивает системный словарь русского языка,
    /// иначе список забивается обычными словами, сказанными быстро.
    /// </summary>
    private TabPage CandidatesTab()
    {
        var page = new TabPage("Кандидаты") { Padding = new Padding(14) };
        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true
        };

        layout.Controls.Add(Header("Слова, в которых распознавание сомневалось"));
        layout.Controls.Add(Hint("Модель отдаёт уверенность по каждому слову. Сюда попадает то, что она разобрала неуверенно и чего нет в словаре русского языка: обычно это англицизм, записанный кириллицей. Напиши, как слово пишется на самом деле, и оно уйдёт в словарь распознавания."));

        var list = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Margin = new Padding(0, 8, 0, 8)
        };
        layout.Controls.Add(list);

        void Rebuild()
        {
            list.Controls.Clear();
            var pending = candidates.Pending;
            if (pending.Count == 0)
            {
                list.Controls.Add(Hint(config.CollectCandidates
                    ? "Пока пусто. Слово попадает сюда, когда распознавание о него спотыкается, а словарь русского языка его не знает."
                    : "Сбор выключен. Включи его ниже, и после нескольких диктовок здесь появятся слова."));
                return;
            }
            foreach (var candidate in pending) list.Controls.Add(Row(candidate, Rebuild));
        }

        Rebuild();

        var collect = new CheckBox
        {
            Text = "Собирать сомнительные слова",
            Checked = config.CollectCandidates,
            AutoSize = true,
            Margin = new Padding(0, 10, 0, 0)
        };
        collect.CheckedChanged += (_, _) => { config.CollectCandidates = collect.Checked; Save(); Rebuild(); };
        layout.Controls.Add(collect);
        layout.Controls.Add(Hint("Разбор идёт фоном, уже после того как текст вставлен: на саму диктовку он не влияет. Кандидат без ответа исчезает сам через неделю, решённое молчит три месяца."));

        var forget = new Button { Text = "Очистить список", Width = 160 };
        forget.Click += (_, _) => { candidates.ForgetAll(); Rebuild(); };
        layout.Controls.Add(forget);

        page.Controls.Add(layout);
        return page;
    }

    private Control Row(Candidate candidate, Action refresh)
    {
        var box = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BorderStyle = BorderStyle.FixedSingle,
            Padding = new Padding(8),
            Margin = new Padding(0, 0, 0, 6)
        };

        var title = new Label
        {
            Text = candidate.Hits > 1
                ? $"{candidate.Word}   {candidate.Hits} раза, уверенность {candidate.Worst * 100:F0}%"
                : $"{candidate.Word}   уверенность {candidate.Worst * 100:F0}%",
            Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold),
            AutoSize = true
        };
        box.Controls.Add(title);

        if (candidate.Context.Length > 0)
        {
            box.Controls.Add(new Label
            {
                Text = "«" + Shorten(candidate.Context) + "»",
                ForeColor = SystemColors.GrayText,
                AutoSize = true,
                MaximumSize = new Size(520, 0)
            });
        }

        var row = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        var field = new TextBox { Width = 190, PlaceholderText = "как пишется на самом деле" };
        var accept = new Button { Text = "В словарь", Width = 110, Enabled = false };
        var correct = new Button { Text = "Всё верно", Width = 110 };
        var hide = new Button { Text = "Скрыть", Width = 90 };

        field.TextChanged += (_, _) => accept.Enabled = field.Text.Trim().Length > 0;
        accept.Click += (_, _) =>
        {
            var problem = AddTerm(field.Text);
            if (problem != null) { MessageBox.Show(this, problem, "Не вышло"); return; }
            candidates.Accepted(candidate);
            refresh();
        };
        correct.Click += (_, _) => { candidates.MarkCorrect(candidate); refresh(); };
        hide.Click += (_, _) => { candidates.Dismiss(candidate); refresh(); };

        row.Controls.Add(field);
        row.Controls.Add(accept);
        row.Controls.Add(correct);
        row.Controls.Add(hide);
        box.Controls.Add(row);
        return box;
    }

    private static string Shorten(string text) => text.Length <= 90 ? text : text[..87] + "…";

    private static Label Header(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Font = new Font(SystemFonts.DefaultFont, FontStyle.Bold),
        Margin = new Padding(0, 10, 0, 4)
    };

    /// Ширину задаём через MaximumSize, а высоту отдаём автоподбору:
    /// считать её по длине строки — верный способ обрезать текст.
    private static Label Hint(string text) => new()
    {
        Text = text,
        AutoSize = true,
        MaximumSize = new Size(560, 0),
        ForeColor = SystemColors.GrayText,
        Margin = new Padding(0, 2, 0, 6)
    };

    private static Label Spacer() => new() { Height = 8, Width = 10 };
}
