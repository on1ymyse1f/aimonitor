using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace AIMonitor.Windows;

/// The tray icon's picture. The macOS status item shows free text ("82%",
/// "2.73M", "41m"); a tray icon is a 16-px square, so it shows the tightest
/// quota's number when that is the title, and "AI" otherwise. The full title
/// goes in the tooltip.
static partial class TrayIcon
{
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyIcon(IntPtr handle);

    [GeneratedRegex(@"^\d{1,3}%$")]
    private static partial Regex Percent();

    public static string ShortText(string title) => Percent().IsMatch(title) ? title.TrimEnd('%') : "AI";

    /// A terracotta tile with white text.
    public static Icon Render(string text, int size)
    {
        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

            var radius = size * 0.22f;
            using var tile = new GraphicsPath();
            tile.AddArc(0, 0, 2 * radius, 2 * radius, 180, 90);
            tile.AddArc(size - 2 * radius, 0, 2 * radius, 2 * radius, 270, 90);
            tile.AddArc(size - 2 * radius, size - 2 * radius, 2 * radius, 2 * radius, 0, 90);
            tile.AddArc(0, size - 2 * radius, 2 * radius, 2 * radius, 90, 90);
            tile.CloseFigure();
            using var fill = new SolidBrush(Palette.Accent);
            g.FillPath(fill, tile);

            var fontSize = size * (text.Length >= 3 ? 0.40f : 0.56f);
            using var font = new Font("Segoe UI", fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
            using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString(text, font, Brushes.White, new RectangleF(0, size * 0.03f, size, size), format);
        }

        var handle = bitmap.GetHicon();
        try
        {
            using var borrowed = Icon.FromHandle(handle);
            return (Icon)borrowed.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }
}
