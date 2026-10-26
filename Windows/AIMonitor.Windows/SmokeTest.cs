using System.Text.Json;

namespace AIMonitor.Windows;

/// `--smoke-test <dir>`: the end-to-end check CI runs on Windows. Starts the
/// real agent, waits for the dashboard page to render its first snapshot,
/// screenshots every page, writes what the page and the tray showed, and exits
/// 0 when every `--expect` text appears on some page.
static class SmokeTest
{
    static readonly string[] Pages = ["dashboard", "timeline", "models", "settings"];

    public static async Task RunAsync(TrayApp app, DashboardWindow window, Options options)
    {
        var dir = Directory.CreateDirectory(options.SmokeTestDir!).FullName;
        var log = new List<string>();
        string? report = null;

        try
        {
            var deadline = DateTime.UtcNow.AddSeconds(120);
            while (report is null && DateTime.UtcNow < deadline)
            {
                await Task.Delay(500);
                if (window.InitializationError is not null) break;
                if (!window.IsPageReady) continue;
                var raw = await window.EvaluateAsync("window.__aimonitor ? window.__aimonitor.report() : null");
                // ExecuteScriptAsync returns the result as JSON; the report is a JSON string.
                if (raw is null or "null") continue;
                var text = JsonSerializer.Deserialize<string>(raw);
                if (text is null) continue;
                using var doc = JsonDocument.Parse(text);
                if (doc.RootElement.GetProperty("rendered").GetBoolean()) report = text;
            }

            if (report is null)
            {
                log.Add(window.InitializationError ?? "page never rendered a snapshot");
                if (app.LastAgentError is { } error) log.Add("agent error: " + error);
            }
            else
            {
                await File.WriteAllTextAsync(Path.Combine(dir, "report.json"), report);
                foreach (var page in Pages)
                {
                    await window.EvaluateAsync($"window.__aimonitor.show('{page}')");
                    await Task.Delay(400);
                    await window.CapturePngAsync(Path.Combine(dir, page + ".png"));
                }
                if (app.LastMenu is { } menu)
                {
                    await File.WriteAllLinesAsync(Path.Combine(dir, "tray.txt"),
                        menu.Items.Select(i => i.Kind == "separator" ? "-----" : i.Text).Prepend("title: " + menu.Title));
                }
                foreach (var expected in options.SmokeExpect)
                    if (!report.Contains(expected, StringComparison.Ordinal))
                        log.Add($"expected text not found: {expected}");
            }
        }
        catch (Exception e)
        {
            log.Add(e.ToString());
        }

        var passed = report is not null && log.Count == 0;
        await File.WriteAllLinesAsync(Path.Combine(dir, "result.txt"), log.Prepend(passed ? "pass" : "fail"));
        app.Quit(passed ? 0 : 1);
    }
}
