using System.Text.Json;
using Microsoft.Win32;

namespace AIMonitor.Windows;

/// The tray icon and its menu (the macOS menu bar app, line for line), the
/// quota notifications, and the dashboard window, all fed by the agent's
/// messages. Everything here runs on the UI thread.
sealed class TrayApp : ApplicationContext
{
    /// What the page may ask the agent to do; anything else is dropped here,
    /// and the agent validates the arguments again.
    static readonly HashSet<string> PageCommands =
        ["refresh", "sync", "setFlowRange", "setTimelineProvider", "setSetting", "setRetention", "deleteAll"];

    readonly Options options;
    readonly AgentClient agent;
    readonly NotifyIcon tray;
    readonly DashboardWindow window;
    readonly Control ui = new();
    readonly RegisteredWaitHandle? showRequestWait;
    readonly Font headerFont;

    string? lastSnapshot;
    string appearance = "system";
    Dictionary<string, string> strings = [];
    UISnapshotMenu? lastMenu;
    bool menuRebuildPending;
    bool quitting;

    public int ExitCode { get; private set; }

    public TrayApp(string agentPath, Options options, EventWaitHandle? showRequest)
    {
        this.options = options;
        // A handle to marshal agent lines onto this (the UI) thread.
        _ = ui.Handle;

        var dataRoot = options.IsSmokeTest
            ? Path.GetFullPath(options.SmokeTestDir!)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AIMonitor");
        window = new DashboardWindow(Path.Combine(dataRoot, "WebView2"), interactive: !options.IsSmokeTest);
        window.MessageFromPage += OnPageMessage;

        tray = new NotifyIcon
        {
            Text = "AI Monitor",
            Icon = TrayIcon.Render("AI", SystemInformation.SmallIconSize.Width),
            ContextMenuStrip = new ContextMenuStrip(),
            Visible = true,
        };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) window.ShowDashboard(); };
        headerFont = new Font(tray.ContextMenuStrip.Font, FontStyle.Bold);
        // Like the macOS menu, an open menu keeps its lines until it closes.
        tray.ContextMenuStrip.Closed += (_, _) => { if (menuRebuildPending) RebuildMenu(); };
        RebuildMenu();

        if (showRequest is not null)
        {
            showRequestWait = ThreadPool.RegisterWaitForSingleObject(
                showRequest, (_, _) => OnUI(window.ShowDashboard), null, Timeout.Infinite, false);
        }
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

        agent = new AgentClient(agentPath, options.AgentArgs);
        agent.LineReceived += line => OnUI(() => OnAgentLine(line));
        agent.Exited += () => OnUI(OnAgentExited);
        agent.Start();

        if (!options.Background) window.ShowDashboard();
        if (options.IsSmokeTest) _ = SmokeTest.RunAsync(this, window, options);
    }

    void OnUI(Action action)
    {
        if (!ui.IsDisposed) ui.BeginInvoke(action);
    }

    // MARK: Agent → tray / page

    void OnAgentLine(string line)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(line); }
        catch (JsonException) { return; }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("type", out var type)) return;
            var data = root.TryGetProperty("data", out var d) ? d : default;
            switch (type.GetString())
            {
                case "snapshot":
                    lastSnapshot = line;
                    ApplySnapshot(data);
                    window.Post(line);
                    break;
                case "notification":
                    tray.ShowBalloonTip(10_000, Text(data, "title"), Text(data, "body"), ToolTipIcon.None);
                    break;
                case "cardExported":
                    window.Post(line);
                    break;
                case "error":
                    LastAgentError = Text(data, "message");
                    break;
            }
        }
    }

    public string? LastAgentError { get; private set; }
    public UISnapshotMenu? LastMenu => lastMenu;

    static string Text(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";

    void ApplySnapshot(JsonElement data)
    {
        strings = data.GetProperty("strings").EnumerateObject()
            .ToDictionary(p => p.Name, p => p.Value.GetString() ?? "");
        appearance = data.GetProperty("settings").GetProperty("appearance").GetString() ?? "system";
        window.ApplyAppearance(appearance);

        var menu = data.GetProperty("menu");
        lastMenu = new UISnapshotMenu(
            Text(menu, "title"),
            menu.GetProperty("items").EnumerateArray().Select(i => (Text(i, "kind"), Text(i, "text"))).ToList());

        var title = lastMenu.Title;
        var tip = $"AI Monitor — {title}";
        tray.Text = tip.Length > 127 ? tip[..127] : tip;
        var old = tray.Icon;
        tray.Icon = TrayIcon.Render(TrayIcon.ShortText(title), SystemInformation.SmallIconSize.Width);
        old?.Dispose();
        RebuildMenu();
    }

    /// The macOS status menu: AI Monitor, active now, today, usage shares,
    /// quotas, then Open Dashboard / Sync now / Quit.
    void RebuildMenu()
    {
        var menu = tray.ContextMenuStrip!;
        if (menu.Visible)
        {
            menuRebuildPending = true;
            return;
        }
        menuRebuildPending = false;
        var old = menu.Items.Cast<ToolStripItem>().ToList();
        menu.Items.Clear();
        foreach (var item in old) item.Dispose();

        static string Escape(string s) => s.Replace("&", "&&");
        foreach (var (kind, text) in lastMenu?.Items ?? [("header", "AI Monitor")])
        {
            switch (kind)
            {
                case "header":
                    menu.Items.Add(new ToolStripMenuItem(Escape(text)) { Enabled = false, Font = headerFont });
                    break;
                case "separator":
                    menu.Items.Add(new ToolStripSeparator());
                    break;
                default:
                    menu.Items.Add(new ToolStripMenuItem("   " + Escape(text)) { Enabled = false });
                    break;
            }
        }

        string L(string key, string fallback) => strings.TryGetValue(key, out var s) ? s : fallback;
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(Escape(L("openDashboard", "Open Dashboard")), null, (_, _) => window.ShowDashboard()));
        menu.Items.Add(new ToolStripMenuItem(Escape(L("syncNow", "Sync now")), null, (_, _) => agent.Send("""{"cmd":"sync"}""")));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(Escape(L("quit", "Quit")), null, (_, _) => Quit()));
    }

    // MARK: Page → agent

    void OnPageMessage(JsonElement message)
    {
        var cmd = Text(message, "cmd");
        if (cmd == "ready")
        {
            window.Post(JsonSerializer.Serialize(new { type = "host", data = new { accent = NativeTheme.AccentHex() } }));
            if (lastSnapshot is not null) window.Post(lastSnapshot);
        }
        else if (cmd == "exportCard")
        {
            // The real Desktop, which OneDrive may have moved.
            agent.Send(JsonSerializer.Serialize(new
            {
                cmd,
                provider = Text(message, "provider"),
                directory = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            }));
        }
        else if (PageCommands.Contains(cmd))
        {
            agent.Send(message.GetRawText());
        }
    }

    void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color)
            OnUI(() =>
            {
                window.ApplyAppearance(appearance);
                window.Post(JsonSerializer.Serialize(new { type = "host", data = new { accent = NativeTheme.AccentHex() } }));
            });
    }

    // MARK: Lifetime

    void OnAgentExited()
    {
        if (quitting) return;
        ExitCode = 1;
        if (!options.IsSmokeTest)
        {
            var detail = LastAgentError ?? agent.RecentErrors;
            MessageBox.Show(
                "AI Monitor's background agent stopped." + (string.IsNullOrWhiteSpace(detail) ? "" : "\n\n" + detail),
                "AI Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        Quit();
    }

    public void Quit(int? exitCode = null)
    {
        if (exitCode is { } code) ExitCode = code;
        quitting = true;
        tray.Visible = false;
        window.CloseForGood();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            showRequestWait?.Unregister(null);
            quitting = true;
            agent.Dispose();
            tray.Dispose();
            window.Dispose();
            headerFont.Dispose();
            ui.Dispose();
        }
        base.Dispose(disposing);
    }
}

/// The tray-relevant part of the agent's snapshot.
sealed record UISnapshotMenu(string Title, List<(string Kind, string Text)> Items);
