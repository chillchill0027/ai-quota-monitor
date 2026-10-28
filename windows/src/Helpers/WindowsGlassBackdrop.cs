using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using Microsoft.Win32;

namespace AIQuotaMonitor.Helpers
{
    /// <summary>
    /// Uses Windows' compositor for real background Acrylic on Windows 11 22H2+.
    /// A non-layered window (AllowsTransparency=false) and transparent client area
    /// are required. Older systems and reduced-transparency settings get an opaque
    /// surface, rather than an unblurred translucent imitation.
    /// </summary>
    public sealed class WindowsGlassBackdrop : IDisposable
    {
        private const int DwmUseImmersiveDarkMode = 20;
        private const int DwmWindowCornerPreference = 33;
        private const int DwmBorderColor = 34;
        private const int DwmSystemBackdropType = 38;
        private static readonly ConditionalWeakTable<Window, WindowsGlassBackdrop> Instances = new();
        private static readonly DependencyPropertyKey IsNativeBackdropEnabledPropertyKey =
            DependencyProperty.RegisterAttachedReadOnly("IsNativeBackdropEnabled", typeof(bool),
                typeof(WindowsGlassBackdrop), new PropertyMetadata(false));

        public static readonly DependencyProperty IsNativeBackdropEnabledProperty = IsNativeBackdropEnabledPropertyKey.DependencyProperty;
        public static bool GetIsNativeBackdropEnabled(DependencyObject window) =>
            (bool)window.GetValue(IsNativeBackdropEnabledProperty);

        private readonly Window _window;
        private readonly WindowChrome _chrome;
        private Border _surface;
        private bool _isDark;
        private double _cornerRadius;
        private HwndSource? _source;
        private bool _disposed;
        private bool _applying;

        [StructLayout(LayoutKind.Sequential)]
        private struct Margins { public int Left, Right, Top, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRect { public int Left, Top, Right, Bottom; }

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
        [DllImport("dwmapi.dll")]
        private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
        [DllImport("dwmapi.dll")]
        private static extern int DwmIsCompositionEnabled([MarshalAs(UnmanagedType.Bool)] out bool enabled);
        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
        [DllImport("user32.dll")]
        private static extern int SetWindowRgn(IntPtr hwnd, IntPtr region, bool redraw);
        [DllImport("gdi32.dll")]
        private static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int ellipseWidth, int ellipseHeight);
        [DllImport("gdi32.dll")]
        private static extern bool DeleteObject(IntPtr handle);

        private WindowsGlassBackdrop(Window window, Border surface, bool isDark, double cornerRadius)
        {
            _window = window;
            _surface = surface;
            _isDark = isDark;
            _cornerRadius = cornerRadius;
            _chrome = new WindowChrome
            {
                CaptionHeight = 0,
                ResizeBorderThickness = new Thickness(0),
                GlassFrameThickness = new Thickness(0),
                // DWM owns the Win11 silhouette; a second WPF radius leaves
                // Acrylic visible between the two different corner curves.
                CornerRadius = new CornerRadius(0),
                UseAeroCaptionButtons = false
            };
            WindowChrome.SetWindowChrome(window, _chrome);
            PaintSurface(nativeAcrylic: false);
            window.SourceInitialized += OnSourceInitialized;
            window.SizeChanged += OnSizeChanged;
            window.Closed += OnClosed;
            if (new WindowInteropHelper(window).Handle != IntPtr.Zero) InitializeSource();
        }

        public static WindowsGlassBackdrop Attach(Window window, Border surface, bool isDark = false, double cornerRadius = 24)
        {
            ArgumentNullException.ThrowIfNull(window);
            ArgumentNullException.ThrowIfNull(surface);
            if (Instances.TryGetValue(window, out var existing))
            {
                existing._surface = surface;
                existing._cornerRadius = cornerRadius;
                existing._isDark = isDark;
                existing.Apply();
                return existing;
            }
            var backdrop = new WindowsGlassBackdrop(window, surface, isDark, cornerRadius);
            Instances.Add(window, backdrop);
            return backdrop;
        }

        public static void SetTheme(Window window, bool isDark)
        {
            if (!Instances.TryGetValue(window, out var backdrop)) return;
            backdrop._isDark = isDark;
            backdrop.Apply();
        }

        public static bool IsSystemDarkTheme()
        {
            try
            {
                return Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                    "AppsUseLightTheme", 1) is int value && value == 0;
            }
            catch { return false; }
        }

        private static bool TransparencyAllowed()
        {
            if (SystemParameters.HighContrast || SystemParameters.IsRemoteSession) return false;
            try
            {
                return Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                    "EnableTransparency", 1) is not int value || value != 0;
            }
            catch { return true; }
        }

        private void OnSourceInitialized(object? sender, EventArgs e) => InitializeSource();
        private void InitializeSource()
        {
            _source = HwndSource.FromHwnd(new WindowInteropHelper(_window).Handle);
            _source?.AddHook(WindowProc);
            Apply();
        }

        private IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            // Windows re-evaluates composition, accessibility and transparency.
            if (message is 0x031E or 0x031A or 0x001A)
                _window.Dispatcher.BeginInvoke(new Action(Apply));
            return IntPtr.Zero;
        }

        private void Apply()
        {
            if (_disposed || _applying) return;
            _applying = true;
            try
            {
                bool nativeAcrylic = false;
                var hwnd = new WindowInteropHelper(_window).Handle;
                bool supported = hwnd != IntPtr.Zero && !_window.AllowsTransparency &&
                    OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621) && TransparencyAllowed();

                if (hwnd != IntPtr.Zero && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
                {
                    int dark = _isDark ? 1 : 0;
                    int corners = 2; // DWMWCP_ROUND
                    int border = unchecked((int)0xFFFFFFFF); // DWMWA_COLOR_DEFAULT: system border and activation state
                    DwmSetWindowAttribute(hwnd, DwmUseImmersiveDarkMode, ref dark, sizeof(int));
                    DwmSetWindowAttribute(hwnd, DwmWindowCornerPreference, ref corners, sizeof(int));
                    DwmSetWindowAttribute(hwnd, DwmBorderColor, ref border, sizeof(int));
                }

                if (supported && DwmIsCompositionEnabled(out bool compositionEnabled) == 0 && compositionEnabled)
                {
                    _chrome.GlassFrameThickness = new Thickness(-1);
                    var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
                    int acrylic = 3; // DWMSBT_TRANSIENTWINDOW, Desktop Acrylic
                    nativeAcrylic = DwmExtendFrameIntoClientArea(hwnd, ref margins) == 0 &&
                        DwmSetWindowAttribute(hwnd, DwmSystemBackdropType, ref acrylic, sizeof(int)) == 0;
                }

                if (!nativeAcrylic && hwnd != IntPtr.Zero)
                {
                    if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621))
                    {
                        int none = 1;
                        DwmSetWindowAttribute(hwnd, DwmSystemBackdropType, ref none, sizeof(int));
                    }
                    // Keep DWM in charge of the outer shape even when the
                    // client is opaque. A zero glass frame makes WindowChrome
                    // install a rectangular HRGN, which disables DWM rounding.
                    int frame = OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) ? 1 : 0;
                    _chrome.GlassFrameThickness = new Thickness(frame);
                    // WindowChrome converts that nonzero DIP thickness to the
                    // current monitor's native pixels and extends the frame.
                    if (frame == 0)
                    {
                        var margins = new Margins();
                        DwmExtendFrameIntoClientArea(hwnd, ref margins);
                    }
                }

                _window.SetValue(IsNativeBackdropEnabledPropertyKey, nativeAcrylic);
                PaintSurface(nativeAcrylic);
                UpdateFallbackRegion();
            }
            catch (DllNotFoundException)
            {
                _window.SetValue(IsNativeBackdropEnabledPropertyKey, false);
                PaintSurface(nativeAcrylic: false);
            }
            catch (EntryPointNotFoundException)
            {
                _window.SetValue(IsNativeBackdropEnabledPropertyKey, false);
                PaintSurface(nativeAcrylic: false);
            }
            finally { _applying = false; }
        }

        private void PaintSurface(bool nativeAcrylic)
        {
            Color fallback = _isDark ? Color.FromRgb(35, 38, 45) : Color.FromRgb(242, 244, 249);
            _window.Background = nativeAcrylic ? Brushes.Transparent : new SolidColorBrush(fallback);
            if (_source?.CompositionTarget != null)
                _source.CompositionTarget.BackgroundColor = nativeAcrylic ? Colors.Transparent : fallback;

            // Fill the native client rectangle all the way to its edges. On
            // Win11 DWM clips it once and supplies the border/shadow, including
            // at fractional DPI. Do not draw another rounded panel on top.
            _surface.CornerRadius = new CornerRadius(0);
            _surface.BorderThickness = new Thickness(0);
            if (SystemParameters.HighContrast)
            {
                _window.Background = SystemColors.WindowBrush;
                _surface.Background = SystemColors.WindowBrush;
                _surface.BorderBrush = SystemColors.WindowTextBrush;
                return;
            }

            _surface.BorderBrush = new SolidColorBrush(_isDark ? Color.FromArgb(45, 255, 255, 255) : Color.FromArgb(165, 255, 255, 255));
            _surface.Background = new LinearGradientBrush(
                nativeAcrylic
                    ? (_isDark ? Color.FromArgb(41, 0, 0, 0) : Color.FromArgb(77, 255, 255, 255))
                    : (_isDark ? Color.FromRgb(48, 51, 59) : Color.FromRgb(249, 250, 253)),
                nativeAcrylic
                    ? (_isDark ? Color.FromArgb(26, 0, 0, 0) : Color.FromArgb(36, 255, 255, 255))
                    : fallback,
                new Point(0, 0), new Point(1, 1));
        }

        private void OnSizeChanged(object sender, SizeChangedEventArgs e) => UpdateFallbackRegion();
        private void UpdateFallbackRegion()
        {
            // Win11 DWM supplies rounded corners and a compositor shadow. Older
            // Windows needs a native rounded region for the opaque fallback.
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) return;
            var hwnd = new WindowInteropHelper(_window).Handle;
            if (hwnd == IntPtr.Zero || !GetWindowRect(hwnd, out var rect)) return;
            int diameter = (int)Math.Ceiling(_cornerRadius * 2 * VisualTreeHelper.GetDpi(_window).DpiScaleX);
            var region = CreateRoundRectRgn(0, 0, rect.Right - rect.Left + 1, rect.Bottom - rect.Top + 1, diameter, diameter);
            if (region != IntPtr.Zero && SetWindowRgn(hwnd, region, true) == 0) DeleteObject(region);
            // On success, Windows owns and frees the region.
        }

        private void OnClosed(object? sender, EventArgs e) => Dispose();
        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _source?.RemoveHook(WindowProc);
            _window.SourceInitialized -= OnSourceInitialized;
            _window.SizeChanged -= OnSizeChanged;
            _window.Closed -= OnClosed;
            Instances.Remove(_window);
        }
    }
}
