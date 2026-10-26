using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace AIMonitor.Windows;

/// The dashboard: a fixed 400 × 600 window, like the macOS app's, showing the
/// local page in `ui/` through WebView2. The page can reach nothing but its own
/// files: navigation off the virtual host is cancelled and pop-ups are refused.
sealed class DashboardWindow : Form
{
    const string Origin = "https://aimonitor.example";

    readonly WebView2 web = new() { Dock = DockStyle.Fill };
    readonly string userDataFolder;
    readonly bool interactive;
    Task? initialization;
    bool allowClose;
    bool dark;

    /// A message from the page, already parsed.
    public event Action<JsonElement>? MessageFromPage;

    /// The page has loaded and asked for state (`ready`); posts reach it now.
    public bool IsPageReady { get; private set; }

    /// Why WebView2 could not start, if it could not.
    public string? InitializationError { get; private set; }

    /// - Parameter interactive: false (the smoke test) reports failures through
    ///   `InitializationError` instead of a dialog nobody would dismiss.
    public DashboardWindow(string userDataFolder, bool interactive)
    {
        this.userDataFolder = userDataFolder;
        this.interactive = interactive;
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(400, 600);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Text = "AI Monitor";
        Icon = TrayIcon.Render("AI", 32);
        Controls.Add(web);
        ResumeLayout(false);
        ApplyAppearance("system");
    }

    public void ShowDashboard()
    {
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
        _ = EnsureInitializedAsync();
    }

    public Task EnsureInitializedAsync() => initialization ??= InitializeAsync();

    async Task InitializeAsync()
    {
        try
        {
            var environment = await CoreWebView2Environment.CreateAsync(null, userDataFolder);
            await web.EnsureCoreWebView2Async(environment);
        }
        catch (Exception e) when (e is WebView2RuntimeNotFoundException or COMException or InvalidOperationException)
        {
            InitializationError = e is WebView2RuntimeNotFoundException
                ? "AI Monitor needs the Microsoft Edge WebView2 Runtime, which ships with Windows 11 " +
                  "and current Windows 10. Install it from https://go.microsoft.com/fwlink/p/?LinkId=2124703."
                : "The dashboard could not start WebView2: " + e.Message;
            if (interactive) MessageBox.Show(InitializationError, "AI Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        var core = web.CoreWebView2;
        var settings = core.Settings;
        settings.AreDefaultContextMenusEnabled = false;
        settings.AreDevToolsEnabled = false;
        settings.AreBrowserAcceleratorKeysEnabled = false;
        settings.IsStatusBarEnabled = false;
        settings.IsZoomControlEnabled = false;
        settings.IsGeneralAutofillEnabled = false;
        settings.IsPasswordAutosaveEnabled = false;
        // Local pages only: no SmartScreen lookups.
        settings.IsReputationCheckingRequired = false;

        core.SetVirtualHostNameToFolderMapping(
            new Uri(Origin).Host, Path.Combine(AppContext.BaseDirectory, "ui"), CoreWebView2HostResourceAccessKind.Deny);
        core.NavigationStarting += (_, e) =>
        {
            IsPageReady = false;
            if (!e.Uri.StartsWith(Origin + "/", StringComparison.Ordinal)) e.Cancel = true;
        };
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.WebMessageReceived += (_, e) =>
        {
            if (!e.Source.StartsWith(Origin + "/", StringComparison.Ordinal)) return;
            try
            {
                using var doc = JsonDocument.Parse(e.WebMessageAsJson);
                if (doc.RootElement.ValueKind != JsonValueKind.Object) return;
                // The page attaches its listener before it says `ready`, so
                // from here on posts are delivered.
                if (doc.RootElement.TryGetProperty("cmd", out var cmd) && cmd.ValueKind == JsonValueKind.String
                    && cmd.GetString() == "ready")
                    IsPageReady = true;
                MessageFromPage?.Invoke(doc.RootElement.Clone());
            }
            catch (JsonException)
            {
                // Not ours.
            }
        };
        core.Navigate(Origin + "/index.html");
    }

    /// Sends a message (a JSON object) to the page once it is listening.
    /// Earlier messages are dropped; the page asks for the latest state with
    /// `ready` when it loads.
    public void Post(string json)
    {
        if (web.CoreWebView2 is { } core && IsPageReady) core.PostWebMessageAsJson(json);
    }

    public Task<string> EvaluateAsync(string script) => web.CoreWebView2.ExecuteScriptAsync(script);

    public async Task CapturePngAsync(string path)
    {
        await using var file = File.Create(path);
        await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, file);
    }

    /// Matches the window frame and the pre-paint background to the page
    /// (system / light / dark), so dark mode never flashes white.
    public void ApplyAppearance(string appearance)
    {
        dark = appearance == "dark" || (appearance == "system" && NativeTheme.AppsUseDarkTheme());
        var background = dark ? Palette.WindowDark : Palette.WindowLight;
        BackColor = background;
        web.DefaultBackgroundColor = background;
        if (IsHandleCreated) NativeTheme.ApplyCaption(Handle, dark, background, dark ? Palette.TextDark : Palette.TextLight);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        NativeTheme.ApplyCaption(Handle, dark, BackColor, dark ? Palette.TextDark : Palette.TextLight);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // Closing the window keeps the tray app running, as on macOS the menu
        // bar app outlives the dashboard.
        if (!allowClose && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnFormClosing(e);
    }

    public void CloseForGood()
    {
        allowClose = true;
        Close();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            web.Dispose();
            Icon?.Dispose();
        }
        base.Dispose(disposing);
    }
}

/// The few Theme.swift colours the native side needs.
static class Palette
{
    public static readonly Color WindowLight = Color.FromArgb(0xF5, 0xF4, 0xEF);
    public static readonly Color WindowDark = Color.FromArgb(0x1E, 0x1D, 0x1A);
    public static readonly Color TextLight = Color.FromArgb(0x1B, 0x19, 0x15);
    public static readonly Color TextDark = Color.FromArgb(0xEC, 0xE9, 0xE2);
    public static readonly Color Accent = Color.FromArgb(0xD9, 0x77, 0x57);
}
