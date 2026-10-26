using System.Diagnostics;
using System.Text;

namespace AIMonitor.Windows;

/// The `aimonitor agent` child process: one JSON object per line, both ways,
/// over stdin/stdout. No sockets: the agent has no listener. Lines arrive on a
/// background thread; the owner marshals them onto the UI thread.
sealed class AgentClient : IDisposable
{
    readonly Process process;
    readonly object writeLock = new();
    readonly Queue<string> recentErrors = new();

    public event Action<string>? LineReceived;
    /// Raised once stdout has ended, after every line the agent wrote has been
    /// delivered — so a last error line is never lost to the race with exit.
    public event Action? Exited;

    public AgentClient(string path, IEnumerable<string> extraArgs)
    {
        var info = new ProcessStartInfo(path)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false),
            WorkingDirectory = Path.GetDirectoryName(path)!,
        };
        info.ArgumentList.Add("agent");
        foreach (var arg in extraArgs) info.ArgumentList.Add(arg);
        process = new Process { StartInfo = info };
    }

    /// The last few lines the agent wrote to stderr, for an error dialog.
    public string RecentErrors
    {
        get { lock (recentErrors) return string.Join(Environment.NewLine, recentErrors); }
    }

    public void Start()
    {
        process.Start();
        process.StandardInput.NewLine = "\n";
        _ = Task.Run(async () =>
        {
            while (await process.StandardOutput.ReadLineAsync() is { } line)
                if (line.Length > 0) LineReceived?.Invoke(line);
            Exited?.Invoke();
        });
        _ = Task.Run(async () =>
        {
            while (await process.StandardError.ReadLineAsync() is { } line)
                lock (recentErrors)
                {
                    recentErrors.Enqueue(line);
                    if (recentErrors.Count > 10) recentErrors.Dequeue();
                }
        });
    }

    public void Send(string json)
    {
        lock (writeLock)
        {
            try
            {
                process.StandardInput.WriteLine(json);
                process.StandardInput.Flush();
            }
            catch (Exception e) when (e is IOException or InvalidOperationException)
            {
                // The agent is gone; Exited reports it.
            }
        }
    }

    public void Dispose()
    {
        // Closing stdin is the agent's signal to exit.
        try { process.StandardInput.Close(); } catch (Exception e) when (e is IOException or InvalidOperationException) { }
        try
        {
            if (!process.HasExited && !process.WaitForExit(3000)) process.Kill();
        }
        catch (InvalidOperationException)
        {
            // Never started.
        }
        process.Dispose();
    }
}
