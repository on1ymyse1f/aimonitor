namespace AIMonitor.Windows;

/// The Windows front end: a tray icon (the macOS menu bar app) and a dashboard
/// window (the macOS SwiftUI app). Both are driven by `aimonitor agent`, which
/// does all syncing, quota fetching and formatting in the shared Swift core, so
/// the numbers and words match macOS exactly. This process only presents them.
static class Program
{
    const string InstanceName = @"Local\AIMonitor.Windows";

    [STAThread]
    static int Main(string[] args)
    {
        Options options;
        try
        {
            options = Options.Parse(args);
        }
        catch (ArgumentException e)
        {
            MessageBox.Show(e.Message, "AI Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        // One tray icon per session. A second launch asks the first to show its
        // dashboard. The smoke test runs alongside a real instance.
        using var mutex = new Mutex(true, InstanceName, out var first);
        using var showRequest = new EventWaitHandle(false, EventResetMode.AutoReset, InstanceName + ".Show");
        if (!first && !options.IsSmokeTest)
        {
            showRequest.Set();
            return 0;
        }

        ApplicationConfiguration.Initialize();

        var agentPath = AgentLocator.Find(options.AgentPath);
        if (agentPath is null)
        {
            const string message = "Could not find aimonitor.exe.\n\nBuild it with `swift build -c release` in the " +
                "repository root, place it next to AIMonitor.exe, or pass --agent <path>.";
            if (options.IsSmokeTest)
            {
                Directory.CreateDirectory(options.SmokeTestDir!);
                File.WriteAllLines(Path.Combine(options.SmokeTestDir!, "result.txt"), ["fail", message]);
            }
            else
            {
                MessageBox.Show(message, "AI Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            return 1;
        }

        using var app = new TrayApp(agentPath, options, options.IsSmokeTest ? null : showRequest);
        Application.Run(app);
        return app.ExitCode;
    }
}

/// Command line: `AIMonitor.exe [--background] [--agent <aimonitor.exe>]
/// [--smoke-test <dir> [--expect <text>]...] [-- <agent options>]`.
sealed record Options(
    bool Background,
    string? AgentPath,
    string? SmokeTestDir,
    IReadOnlyList<string> SmokeExpect,
    IReadOnlyList<string> AgentArgs)
{
    public bool IsSmokeTest => SmokeTestDir is not null;

    public static Options Parse(string[] args)
    {
        bool background = false;
        string? agent = null, smoke = null;
        var expect = new List<string>();
        var agentArgs = new List<string>();

        for (var i = 0; i < args.Length; i++)
        {
            string Value() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value.");
            switch (args[i])
            {
                case "--background": background = true; break;
                case "--agent": agent = Value(); break;
                case "--smoke-test": smoke = Value(); break;
                case "--expect": expect.Add(Value()); break;
                case "--": agentArgs.AddRange(args[(i + 1)..]); i = args.Length; break;
                default: throw new ArgumentException($"Unknown option '{args[i]}'.");
            }
        }
        return new Options(background, agent, smoke, expect, agentArgs);
    }
}

static class AgentLocator
{
    /// `aimonitor.exe`: an explicit path; `AIMONITOR_AGENT`; next to this exe
    /// (installed layout); or a SwiftPM build in an enclosing checkout
    /// (development), release before debug.
    public static string? Find(string? explicitPath)
    {
        if (explicitPath is not null) return File.Exists(explicitPath) ? Path.GetFullPath(explicitPath) : null;

        var fromEnv = Environment.GetEnvironmentVariable("AIMONITOR_AGENT");
        if (!string.IsNullOrEmpty(fromEnv) && File.Exists(fromEnv)) return Path.GetFullPath(fromEnv);

        var sibling = Path.Combine(AppContext.BaseDirectory, "aimonitor.exe");
        if (File.Exists(sibling)) return sibling;

        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var build = Path.Combine(dir.FullName, ".build");
            if (!Directory.Exists(build)) continue;
            // `.build/release` is a link SwiftPM may not create on Windows; the
            // triple directory (`.build/x86_64-unknown-windows-msvc/release`) is real.
            var roots = new[] { build }.Concat(Directory.GetDirectories(build)).ToList();
            foreach (var config in new[] { "release", "debug" })
                foreach (var root in roots)
                {
                    var candidate = Path.Combine(root, config, "aimonitor.exe");
                    if (File.Exists(candidate)) return candidate;
                }
        }
        return null;
    }
}
