using System.Diagnostics;

namespace Golos;

/// <summary>Связывает хоткей, запись, распознавание и вставку.</summary>
public sealed class TrayApp : ApplicationContext
{
    private enum State { Starting, Idle, Recording, Transcribing, Failed }

    private readonly NotifyIcon tray = new();
    private readonly ToolStripMenuItem statusItem = new("Запускаюсь…") { Enabled = false };
    private readonly ToolStripMenuItem toggleItem = new("Начать запись");
    private readonly System.Windows.Forms.Timer animation = new() { Interval = 50 };
    private ToolStripMenuItem micMenu = new("Микрофон");
    private ToolStripMenuItem hintItem = new("");

    private Config config = Config.Load();
    private readonly Recorder recorder = new();
    private HudForm? hud;
    /// <summary>Чем отдать текущую запись. Хозяин здесь, а не в окошке:
    /// переключать можно и с выключенным окошком, тогда режим виден по значку.</summary>
    private HudForm.Mode captureMode = HudForm.Mode.Text;
    private readonly Candidates candidates = new();
    private Whisper whisper;
    private Hotkey? hotkey;

    private State state = State.Starting;
    private float transcribePhase;
    private int recordingGeneration;
    private Icon? currentIcon;

    public TrayApp(bool openSettings = false)
    {
        whisper = new Whisper(config);
        BuildTray();
        if (openSettings) ShowSettings();
        animation.Tick += (_, _) => AnimateIcon();

        Log.Write($"запуск, версия {Updater.CurrentVersion}");
        // Тихая проверка при старте: если обновления нет, человек ничего
        // не заметит. Таймер нужен именно оконный: проверка может дойти до
        // диалога, а его нельзя показывать из фонового потока.
        var updateCheck = new System.Windows.Forms.Timer { Interval = 20_000 };
        updateCheck.Tick += async (_, _) =>
        {
            updateCheck.Stop();
            updateCheck.Dispose();
            try { await Updater.CheckAsync(null, silent: true); } catch { }
        };
        updateCheck.Start();
        foreach (var (index, name) in Recorder.Devices())
            Log.Write($"микрофон {index}: {name}");
        Log.Write($"выбран микрофон: {(config.InputDevice.Length == 0 ? "системный по умолчанию" : config.InputDevice)}");
        PurgeHistory();
        StartHotkey();
        _ = BootWhisperAsync();
    }

    private void BuildTray()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(statusItem);
        menu.Items.Add(new ToolStripSeparator());

        toggleItem.Click += (_, _) => ToggleFromMenu();
        menu.Items.Add(toggleItem);

        hintItem = new ToolStripMenuItem("") { Enabled = false };
        menu.Items.Add(hintItem);
        RefreshHint();
        menu.Items.Add(new ToolStripSeparator());

        micMenu = new ToolStripMenuItem("Микрофон");
        menu.Items.Add(micMenu);
        // Список строим при открытии меню: гарнитуру могли воткнуть только что.
        menu.Opening += (_, _) => BuildMicMenu();

        var transcribeItem = new ToolStripMenuItem("Расшифровать файл…");
        transcribeItem.Click += (_, _) => ShowTranscribe();
        menu.Items.Add(transcribeItem);

        menu.Items.Add(new ToolStripSeparator());

        var settingsItem = new ToolStripMenuItem("Настройки…");
        settingsItem.Click += (_, _) => ShowSettings();
        menu.Items.Add(settingsItem);

        menu.Items.Add(new ToolStripSeparator());

        var updateItem = new ToolStripMenuItem("Проверить обновления…");
        updateItem.Click += async (_, _) => await Updater.CheckAsync(null, silent: false);
        menu.Items.Add(updateItem);

        var quitItem = new ToolStripMenuItem("Выход");
        quitItem.Click += (_, _) => Quit();
        menu.Items.Add(quitItem);

        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        Render();
    }

    private SettingsForm? settingsForm;
    private TranscribeForm? transcribeForm;
    /// <summary>Файлы, пришедшие до готовности движка.</summary>
    private readonly List<string> pendingFiles = new();

    /// <summary>Окно расшифровки файлов.</summary>
    private void ShowTranscribe()
    {
        if (transcribeForm == null || transcribeForm.IsDisposed)
        {
            transcribeForm = new TranscribeForm(
                () => whisper.Ready ? new FileTranscriber(whisper) : null,
                Config.Load);
            transcribeForm.FormClosed += (_, _) => transcribeForm = null;
        }
        transcribeForm.Show();
        transcribeForm.Activate();
    }

    /// <summary>Поставить файлы в очередь расшифровки.</summary>
    public void TranscribeFiles(IEnumerable<string> paths)
    {
        var list = paths.ToList();
        ShowTranscribe();
        if (whisper.Ready) transcribeForm?.Add(list);
        else pendingFiles.AddRange(list);
    }

    /// <summary>
    /// Окно настроек. Держим один экземпляр: второе окно писало бы в тот же
    /// файл и затирало правки первого.
    /// </summary>
    private void ShowSettings()
    {
        if (settingsForm == null || settingsForm.IsDisposed)
        {
            settingsForm = new SettingsForm();
            settingsForm.FormClosed += (_, _) =>
            {
                // Правки могли поменять словарь, микрофон и клавишу.
                config = Config.Load();
                hotkey?.SetOption(HotkeyOption.Named(config.Hotkey));
                hotkey?.SetSecondOption(string.IsNullOrEmpty(config.SecondHotkey)
                                        ? null : HotkeyOption.Named(config.SecondHotkey));
                RefreshHint();
                settingsForm = null;
            };
        }
        settingsForm.Show();
        settingsForm.Activate();
    }

    /// <summary>Список микрофонов с галочкой у выбранного.</summary>
    private void BuildMicMenu()
    {
        micMenu.DropDownItems.Clear();

        var systemItem = new ToolStripMenuItem("Системный по умолчанию")
        {
            Checked = string.IsNullOrEmpty(config.InputDevice)
        };
        systemItem.Click += (_, _) => ChooseMic("");
        micMenu.DropDownItems.Add(systemItem);

        var devices = Recorder.Devices();
        if (devices.Count > 0) micMenu.DropDownItems.Add(new ToolStripSeparator());

        foreach (var (_, name) in devices)
        {
            var item = new ToolStripMenuItem(name)
            {
                Checked = string.Equals(name, config.InputDevice, StringComparison.OrdinalIgnoreCase)
            };
            var captured = name;
            item.Click += (_, _) => ChooseMic(captured);
            micMenu.DropDownItems.Add(item);
        }

        if (devices.Count == 0)
        {
            micMenu.DropDownItems.Add(new ToolStripMenuItem("Микрофонов не найдено") { Enabled = false });
        }
    }

    private void ChooseMic(string name)
    {
        // Пишем прямо в файл: между диктовками конфиг перечитывается,
        // и правка вступит в силу со следующей записи.
        var stored = Config.Load();
        stored.InputDevice = name;
        stored.Save();
        config = stored;
        Log.Write($"микрофон: {(name.Length == 0 ? "системный по умолчанию" : name)}");
    }

    /// <summary>Подсказка называет ту клавишу, что выбрана сейчас.</summary>
    private void RefreshHint()
    {
        hintItem.Text = $"{HotkeyOption.Named(config.Hotkey).Title} — держать; двойной тап — переключатель";
    }

    private static void OpenInShell(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write($"не открылось {path}: {e.Message}"); }
    }

    private void StartHotkey()
    {
        hotkey = new Hotkey(HandleHotkey);
        hotkey.SetOption(HotkeyOption.Named(config.Hotkey));
        hotkey.SetSecondOption(string.IsNullOrEmpty(config.SecondHotkey) ? null : HotkeyOption.Named(config.SecondHotkey));
        if (hotkey.Start()) Log.Write("горячая клавиша слушается");
        else SetState(State.Failed, "Не удалось перехватить клавиатуру");
    }

    private async Task BootWhisperAsync()
    {
        var ok = await whisper.StartAsync();
        if (ok)
        {
            Log.Write("сервер распознавания готов");
            if (pendingFiles.Count > 0)
            {
                var waiting = pendingFiles.ToList();
                pendingFiles.Clear();
                transcribeForm?.Add(waiting);
            }
            if (state != State.Failed) SetState(State.Idle);
        }
        else
        {
            SetState(State.Failed, whisper.LastError ?? "Распознавание не поднялось");
        }
    }

    private void HandleHotkey(Hotkey.Event e)
    {
        Log.Write($"клавиша: {e}");
        switch (e)
        {
            case Hotkey.Event.StartHold:
            case Hotkey.Event.ToggleOn:
                BeginRecording();
                break;
            case Hotkey.Event.FinishHold:
            case Hotkey.Event.ToggleOff:
                _ = EndRecordingAsync(discard: false);
                break;
            case Hotkey.Event.Discard:
            case Hotkey.Event.Cancel:
                _ = EndRecordingAsync(discard: true);
                break;
            case Hotkey.Event.FlipMode:
                if (state == State.Recording)
                    SetCaptureMode(captureMode == HudForm.Mode.Text
                                   ? HudForm.Mode.Audio : HudForm.Mode.Text);
                break;
        }
    }

    private void ToggleFromMenu()
    {
        hotkey?.Reset();
        if (recorder.IsRunning) _ = EndRecordingAsync(discard: false);
        else BeginRecording();
    }

    private void BeginRecording()
    {
        if (recorder.IsRunning) return;
        if (!whisper.Ready)
        {
            SetState(State.Failed, whisper.LastError ?? "Модель ещё грузится");
            return;
        }

        // Словарь мог поменяться между диктовками — перечитываем.
        config = Config.Load();
        recordingGeneration++;
        // Каждый раз с чистого листа: звук уходит только по осознанному выбору.
        captureMode = HudForm.Mode.Text;

        try
        {
            recorder.Start(config.InputDevice);
            Log.Write($"запись пошла, микрофон: {recorder.ActiveDeviceName}, окошко: {config.ShowHUD}");
            SetState(State.Recording);
            PlaySound(start: true);
            if (config.ShowHUD)
            {
                if (hud == null)
                {
                    hud = new HudForm();
                    hud.ModeChanged += SetCaptureMode;
                }
                hud.ShowWave(WaveTheme.ColorFor(config), captureMode, () => recorder.Level);
            }
        }
        catch (Exception e)
        {
            SetState(State.Failed, $"Микрофон не открылся: {e.Message}");
        }
    }

    private async Task EndRecordingAsync(bool discard)
    {
        if (!recorder.IsRunning) return;
        var wav = recorder.Stop();

        if (discard || wav == null)
        {
            hud?.HideWave();
            SetState(State.Idle);
            return;
        }

        PlaySound(start: false);

        // Переключатель решает, чем отдать надиктованное. Звуком — значит
        // распознавать нечего, сразу пакуем и кладём в буфер.
        if (captureMode == HudForm.Mode.Audio)
        {
            SetState(State.Idle);
            ExportVoice(wav);
            return;
        }

        hud?.MarkTranscribing();
        SetState(State.Transcribing);

        var generation = recordingGeneration;

        var parts = AudioSplit.Chunks(wav);
        if (parts.Count > 1) Log.Write($"запись длинная, режу на {parts.Count} куска");

        // Куски идут по очереди: сервер один и обрабатывает запросы
        // последовательно, параллелить нечего.
        var pieces = new List<string>();
        for (var partIndex = 0; partIndex < parts.Count; partIndex++)
        {
            var part = parts[partIndex];
            var piece = await whisper.TranscribeAsync(part, config.PromptString());
            var cleaned = Clean(piece, partIndex);

            // Со второй попытки идём без словаря. Именно он и рушит
            // распознавание: замерено на живом куске в 15 секунд речи — со
            // словарём три попытки дали три разные выдумки, без словаря текст
            // распознался целиком. Замены по готовому тексту при этом остаются.
            var seconds = Hallucination.WavSeconds(part);
            var bad = piece == null
                   || Hallucination.LooksInvented(piece, seconds)
                   || Hallucination.LooksDegenerate(piece)
                   // Текста меньше, чем было речи: самый общий признак потери,
                   // работает и на выдумках, которых нет ни в одном списке.
                   || Hallucination.LooksThin(piece, seconds)
                   // Иероглифы в русской диктовке: голосом их не произнести.
                   || (!Hallucination.ScriptExempt.Contains(config.Language)
                       && Hallucination.ContainsForeignScript(piece))
                   || string.IsNullOrWhiteSpace(cleaned);

            if (bad)
            {
                Log.Write($"кусок не разобрался: «{piece}» — переспрашиваю без словаря");
                piece = await whisper.TranscribeAsync(part, "");
                cleaned = Clean(piece, partIndex);
            }

            if (!string.IsNullOrWhiteSpace(cleaned)) pieces.Add(cleaned);
        }

        var raw = pieces.Count > 0 ? string.Join(" ", pieces) : null;

        // Пока распознавали, могла начаться следующая диктовка — тогда её
        // окошко и состояние трогать нельзя.
        var current = generation == recordingGeneration;
        if (current) hud?.HideWave();

        if (raw == null)
        {
            // Распознать не вышло, но речь была. Запись сохраняем: иначе
            // минута надиктованного пропадает без следа, а вернуть её неоткуда.
            if (config.KeepHistory) SaveHistory(wav, "");
            Log.Write("распознать не вышло, запись сохранена в историю");
            // Движок мог умереть: поднимаем заново, иначе все следующие
            // диктовки уйдут в пустоту до перезапуска приложения.
            if (whisper.Disconnected)
            {
                Log.Write("движок не отвечает, поднимаю заново");
                whisper.Dispose();
                whisper = new Whisper(config);
                _ = BootWhisperAsync();
            }
            if (current) SetState(State.Failed, whisper.LastError ?? "Не распознал, запись в истории");
            return;
        }

        var text = config.ApplyFinalPunctuation(config.ApplyReplacements(
            Hallucination.StripTrailingInvention(Hallucination.CollapseTrailingRepeats(raw))));
        Log.Write($"распознано: {text}");
        if (text.Length == 0)
        {
            if (config.KeepHistory) SaveHistory(wav, "");
            Log.Write("распознать не вышло, запись сохранена в историю");
            if (current) SetState(State.Idle);
            return;
        }

        Inserter.Insert(text, config.InsertMode);
        if (config.KeepHistory) SaveHistory(wav, text);
        if (current) SetState(State.Idle);
        if (current) _ = CollectCandidatesAsync(wav, generation);
    }

    private void SetCaptureMode(HudForm.Mode mode)
    {
        if (mode == captureMode) return;
        captureMode = mode;
        Log.Write($"режим записи: {(mode == HudForm.Mode.Audio ? "звук" : "текст")}");
        hud?.SetMode(mode);
        AnimateIcon();
    }

    /// <summary>Пакует запись в голосовое и кладёт в буфер файлом.</summary>
    private void ExportVoice(byte[] wav)
    {
        hud?.ShowMessage("Пакую…");
        var seconds = (int)Math.Round((wav.Length - 44) / 32000.0);
        Task.Run(() => VoiceMessage.Encode(wav)).ContinueWith(task =>
        {
            var (path, error) = task.Result;
            if (path == null)
            {
                Log.Write($"голосовое не собралось: {error}");
                hud?.HideWave();
                SetState(State.Failed, error ?? "Не вышло сжать запись");
                return;
            }
            VoiceMessage.CopyToClipboard(path);
            Log.Write($"голосовое в буфере: {Path.GetFileName(path)}, {seconds} с");
            hud?.ShowMessage($"В буфере, {seconds} с", 1400);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    /// <summary>
    /// Разбор слов, в которых модель сомневалась. Идёт после вставки:
    /// уверенность живёт только в подробном ответе сервера, а он отвечает
    /// на полсекунды дольше, и ждать это на каждой фразе незачем.
    /// Словарь не передаём: он подсказывает модели ответ, а нам нужна
    /// её собственная неуверенность.
    /// </summary>
    private async Task CollectCandidatesAsync(byte[] wav, int generation)
    {
        if (!config.CollectCandidates) return;
        foreach (var part in AudioSplit.Chunks(wav))
        {
            // Начали новую диктовку — разбор бросаем: сервер один.
            if (generation != recordingGeneration) return;
            var words = await whisper.AnalyzeWordsAsync(part, "");
            if (generation != recordingGeneration) return;
            candidates.Record(words);
        }
    }

    /// <summary>
    /// Чистит кусок от заученных фраз и повторов. Начало трогаем только
    /// со второго куска: в первом приветствие законно.
    /// </summary>
    private static string Clean(string? piece, int partIndex)
    {
        if (string.IsNullOrWhiteSpace(piece)) return "";
        var cleaned = Hallucination.StripTrailingInvention(
            Hallucination.CollapseTrailingRepeats(piece.Trim()));
        if (partIndex > 0) cleaned = Hallucination.StripLeadingInvention(cleaned);
        return cleaned;
    }

    private void PlaySound(bool start)
    {
        if (!config.Sounds) return;
        Sounds.Play(start ? Sounds.Moment.Start : Sounds.Moment.Stop, config.SoundTheme);
    }

    private void SaveHistory(byte[] wav, string text)
    {
        try
        {
            var dir = Path.Combine(Config.Directory, "history");
            Directory.CreateDirectory(dir);
            var stamp = DateTime.Now.ToString("yyyy-MM-ddTHHmmss");
            File.WriteAllBytes(Path.Combine(dir, stamp + ".wav"), wav);
            File.WriteAllText(Path.Combine(dir, stamp + ".txt"), text);
            PurgeHistory();
        }
        catch (Exception e) { Log.Write($"история не записалась: {e.Message}"); }
    }

    /// <summary>Голос на диске держать дольше нужного незачем.</summary>
    private void PurgeHistory()
    {
        if (config.HistoryRetentionHours <= 0) return;
        try
        {
            var dir = Path.Combine(Config.Directory, "history");
            if (!Directory.Exists(dir)) return;
            var cutoff = DateTime.Now.AddHours(-config.HistoryRetentionHours);
            var removed = 0;
            foreach (var file in Directory.GetFiles(dir))
            {
                // Расшифровки не трогаем никогда: место копеечное, а по ним
                // видно, как со временем меняется речь.
                if (Path.GetExtension(file).Equals(".txt", StringComparison.OrdinalIgnoreCase)) continue;
                if (File.GetLastWriteTime(file) >= cutoff) continue;
                try { File.Delete(file); removed++; } catch { }
            }
            if (removed > 0) Log.Write($"история: удалено записей {removed}, расшифровки оставлены");
        }
        catch { }
    }

    private void SetState(State next, string? message = null)
    {
        state = next;
        if (next == State.Failed && message != null) Log.Write($"ошибка: {message}");
        Render(message);
    }

    private void Render(string? message = null)
    {
        switch (state)
        {
            case State.Starting:
                SetIcon(TrayIcon.Idle());
                statusItem.Text = "Гружу модель…";
                toggleItem.Enabled = false;
                toggleItem.Text = "Начать запись";
                break;
            case State.Idle:
                SetIcon(TrayIcon.Idle());
                statusItem.Text = "Готово";
                toggleItem.Enabled = true;
                toggleItem.Text = "Начать запись";
                break;
            case State.Recording:
                statusItem.Text = "Идёт запись";
                toggleItem.Enabled = true;
                toggleItem.Text = "Остановить и распознать";
                break;
            case State.Transcribing:
                statusItem.Text = "Распознаю…";
                toggleItem.Enabled = false;
                toggleItem.Text = "Начать запись";
                break;
            case State.Failed:
                SetIcon(TrayIcon.Failed());
                statusItem.Text = message ?? "Ошибка";
                toggleItem.Enabled = true;
                toggleItem.Text = "Начать запись";
                break;
        }

        tray.Text = Shorten(statusItem.Text ?? "Голос");

        // Иконка оживает только в двух состояниях — в покое таймер не нужен.
        var lively = state is State.Recording or State.Transcribing;
        if (lively && !animation.Enabled) { transcribePhase = 0; animation.Start(); }
        else if (!lively && animation.Enabled) animation.Stop();
    }

    private static string Shorten(string s) => s.Length <= 63 ? s : s[..60] + "…";

    private void AnimateIcon()
    {
        switch (state)
        {
            case State.Recording:
                SetIcon(TrayIcon.Recording(recorder.Level, WaveTheme.TrayColorFor(config),
                                           captureMode == HudForm.Mode.Audio));
                break;
            case State.Transcribing:
                transcribePhase += 0.32f;
                SetIcon(TrayIcon.Transcribing(transcribePhase));
                break;
            default:
                animation.Stop();
                break;
        }
    }

    private void SetIcon(Icon icon)
    {
        tray.Icon = icon;
        currentIcon?.Dispose();
        currentIcon = icon;
    }

    private void Quit()
    {
        Log.Write("выход");
        animation.Stop();
        hotkey?.Dispose();
        hud?.Dispose();
        recorder.Dispose();
        whisper.Dispose();
        tray.Visible = false;
        tray.Dispose();
        currentIcon?.Dispose();
        ExitThread();
    }
}
