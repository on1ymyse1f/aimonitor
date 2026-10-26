using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace AIMonitor.Windows;

/// The Windows settings the macOS app gets from AppKit for free: dark mode,
/// the user's accent colour, and a title bar that matches the content.
static partial class NativeTheme
{
    const int DwmwaUseImmersiveDarkMode = 20;
    const int DwmwaCaptionColor = 35;
    const int DwmwaTextColor = 36;

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    public static bool AppsUseDarkTheme() =>
        Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "AppsUseLightTheme", 1) is int light && light == 0;

    /// The user's accent colour as #RRGGBB, for the page's switches, the way
    /// SwiftUI toggles take the macOS accent. Windows 11's default otherwise.
    public static string AccentHex()
    {
        if (Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM", "AccentColor", null) is int value)
        {
            var abgr = unchecked((uint)value);
            return $"#{abgr & 0xFF:X2}{(abgr >> 8) & 0xFF:X2}{(abgr >> 16) & 0xFF:X2}";
        }
        return "#0067C0";
    }

    /// Dark frame on Windows 10 20H1+; caption and title colours on Windows 11.
    /// Older systems ignore the attributes they don't know.
    public static void ApplyCaption(IntPtr hwnd, bool dark, Color caption, Color text)
    {
        var on = dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref on, sizeof(int));
        var captionRef = ColorTranslator.ToWin32(caption);
        DwmSetWindowAttribute(hwnd, DwmwaCaptionColor, ref captionRef, sizeof(int));
        var textRef = ColorTranslator.ToWin32(text);
        DwmSetWindowAttribute(hwnd, DwmwaTextColor, ref textRef, sizeof(int));
    }
}
