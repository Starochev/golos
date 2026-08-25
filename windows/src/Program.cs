namespace Golos;

internal static class Program
{
    // STA обязателен: без него буфер обмена в Windows Forms не работает.
    [STAThread]
    private static void Main()
    {
        // Второй экземпляр перехватил бы ту же клавишу и занял тот же порт.
        using var single = new Mutex(true, "Golos.SingleInstance", out var first);
        if (!first)
        {
            MessageBox.Show("Голос уже запущен.", "Голос",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        // --settings открывает окно настроек сразу: удобно и для проверки,
        // и когда значок в трее спрятан в скрытой области.
        var openSettings = Environment.GetCommandLineArgs()
            .Any(a => string.Equals(a, "--settings", StringComparison.OrdinalIgnoreCase));
        // Запуск с путями к файлам: «Golos.exe --transcribe запись.mp4».
        var args = Environment.GetCommandLineArgs();
        var flag = Array.FindIndex(args, a => string.Equals(a, "--transcribe", StringComparison.OrdinalIgnoreCase));
        var files = flag >= 0 ? args.Skip(flag + 1).Where(File.Exists).ToList() : new List<string>();

        var app = new TrayApp(openSettings);
        if (files.Count > 0)
        {
            var timer = new System.Windows.Forms.Timer { Interval = 200 };
            timer.Tick += (_, _) => { timer.Stop(); timer.Dispose(); app.TranscribeFiles(files); };
            timer.Start();
        }
        Application.Run(app);
    }
}
