using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using AIQuotaMonitor;
using AIQuotaMonitor.Controls;
using AIQuotaMonitor.Helpers;
using AIQuotaMonitor.Models;
using AIQuotaMonitor.Services;

internal static class Program
{
    private static int _checks;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception(description);
        _checks++;
        Console.WriteLine("PASS " + description);
    }

    private static void SettleLayout(Window window)
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
        window.UpdateLayout();
    }

    private static bool SamePoint(Point actual, Point expected) =>
        Math.Abs(actual.X - expected.X) <= 1 && Math.Abs(actual.Y - expected.Y) <= 1;

    private static Point TopLeft(Window window) => new(window.Left, window.Top);
    private static Point BottomRight(Window window) => new(window.Left + window.ActualWidth, window.Top + window.ActualHeight);

    private static Point NativeAnchor(Window window, bool isTrayPopup)
    {
        if (!GetWindowRect(new WindowInteropHelper(window).Handle, out var rect))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return isTrayPopup ? new Point(rect.Right, rect.Bottom) : new Point(rect.Left, rect.Top);
    }

    private static void CheckSettingsRoundTrips(MainWindow window, bool isTrayPopup)
    {
        Point anchor = isTrayPopup ? BottomRight(window) : TopLeft(window);
        Point nativeAnchor = NativeAnchor(window, isTrayPopup);
        for (int cycle = 1; cycle <= 2; cycle++)
        {
            window.ToggleSettings();
            SettleLayout(window);
            Check(SamePoint(isTrayPopup ? BottomRight(window) : TopLeft(window), anchor),
                $"{(isTrayPopup ? "tray bottom-right" : "main top-left")} anchor survives settings entry {cycle}");
            Check(SamePoint(NativeAnchor(window, isTrayPopup), nativeAnchor),
                $"{(isTrayPopup ? "tray bottom-right" : "main top-left")} HWND anchor stays within one pixel on settings entry {cycle}");
            window.ToggleSettings();
            SettleLayout(window);
            Check(SamePoint(isTrayPopup ? BottomRight(window) : TopLeft(window), anchor),
                $"{(isTrayPopup ? "tray bottom-right" : "main top-left")} anchor survives settings return {cycle}");
            Check(SamePoint(NativeAnchor(window, isTrayPopup), nativeAnchor),
                $"{(isTrayPopup ? "tray bottom-right" : "main top-left")} HWND anchor stays within one pixel on settings return {cycle}");
        }
    }

    [STAThread]
    private static int Main()
    {
        string folder = Path.Combine(Path.GetTempPath(), "AIQuotaMonitor-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var original = new QuotaManager(folder);
            foreach (var provider in ProviderExtensions.DashboardOrder.Where(p => p != ProviderID.ChatGPT))
                original.ToggleProviderVisibility(provider);
            Check(!original.ToggleProviderVisibility(ProviderID.ChatGPT), "last visible provider cannot be hidden");
            original.ChatGPT.FiveHourRemainingPercent = 42;
            original.ChatGPT.UpdatedAt = DateTime.UtcNow;
            original.ChatGPT.Status = ConnectionStatus.Ready;
            original.SaveState();
            var restored = new QuotaManager(folder);
            Check(restored.VisibleProviders.SetEquals(new[] { ProviderID.ChatGPT }), "provider selection survives restart");
            Check(restored.ChatGPT.FiveHourRemainingPercent == 42 && restored.ChatGPT.Status == ConnectionStatus.Cached,
                "restart restores quota as cached, not live");
            Check(!File.Exists(Path.Combine(folder, "state.json.tmp")), "state replacement leaves no partial file");

            File.WriteAllText(Path.Combine(folder, "state.json"), JsonSerializer.Serialize(new
            {
                Visible = new[] { "999", "Unknown" },
                MenuBarStyle = "999",
                ChatGPT = original.ChatGPT
            }));
            var invalid = new QuotaManager(folder);
            Check(invalid.VisibleProviders.Count == 5, "unknown saved providers cannot hide every card");
            Check(invalid.ChatGPT.FiveHourRemainingPercent == 42 && invalid.ChatGPT.Status == ConnectionStatus.Cached,
                "legacy display-style field does not interfere with loading cached quotas");
            File.WriteAllText(Path.Combine(folder, "state.json"), "incomplete JSON");
            Check(new QuotaManager(folder).VisibleProviders.Count == 5, "corrupt cache does not prevent startup");

            string calibrationFolder = Path.Combine(folder, "manual-calibration");
            var calibrated = new QuotaManager(calibrationFolder);
            Check(calibrated.TryApplyManualCalibration(ProviderID.MiMo, -12.75, null, null, "CNY", out string calibrationError)
                && calibrationError == "", "manual MiMo calibration accepts a negative cash balance");
            Check(calibrated.MiMo.CashBalance == -12.75 && calibrated.MiMo.CurrencyCode == "CNY"
                && calibrated.MiMo.Source == DataOrigin.Manual && calibrated.MiMo.Status == ConnectionStatus.ManualCalibrated,
                "negative MiMo balance is labeled as manual data");
            Check(new QuotaManager(calibrationFolder).MiMo.CashBalance == -12.75,
                "negative manual MiMo balance survives restart");

            calibrated.Gemini.FiveHourRemainingPercent = 63;
            calibrated.Gemini.WeeklyRemainingPercent = 28;
            calibrated.Gemini.UpdatedAt = DateTime.UtcNow.AddHours(-1);
            calibrated.Gemini.Status = ConnectionStatus.Cached;
            calibrated.Gemini.Source = DataOrigin.Webpage;
            calibrated.Gemini.FiveHourResetsAt = DateTime.UtcNow.AddHours(2);
            calibrated.SaveState();
            string priorGemini = JsonSerializer.Serialize(calibrated.Gemini);
            string priorSavedState = File.ReadAllText(Path.Combine(calibrationFolder, "state.json"));
            foreach (var values in new[] { (first: -0.1, weekly: 20.0), (first: 20.0, weekly: 100.1), (first: double.NaN, weekly: 20.0) })
            {
                Check(!calibrated.TryApplyManualCalibration(ProviderID.Gemini, values.first, values.weekly, null, "CNY", out calibrationError)
                    && !string.IsNullOrWhiteSpace(calibrationError), "invalid manual percentage is rejected with an explanation");
                Check(JsonSerializer.Serialize(calibrated.Gemini) == priorGemini
                    && File.ReadAllText(Path.Combine(calibrationFolder, "state.json")) == priorSavedState,
                    "rejected calibration preserves cached values, timestamps and saved state");
            }
            Check(calibrated.TryApplyManualCalibration(ProviderID.Gemini, 44.5, 81, null, "CNY", out calibrationError),
                "valid Gemini percentages can be calibrated manually");
            var calibratedAfterRestart = new QuotaManager(calibrationFolder);
            Check(calibratedAfterRestart.Gemini.FiveHourRemainingPercent == 44.5
                && calibratedAfterRestart.Gemini.WeeklyRemainingPercent == 81
                && calibratedAfterRestart.Gemini.Status == ConnectionStatus.ManualCalibrated
                && calibratedAfterRestart.Gemini.Source == DataOrigin.Manual,
                "Gemini manual values, status and data source survive restart");
            Check(calibratedAfterRestart.Gemini.FiveHourResetsAt == null,
                "manual Gemini data does not retain the previous official reset time");

            calibrated.Gemini.FiveHourResetsAt = DateTime.UtcNow.AddHours(2);
            calibrated.Gemini.WeeklyResetsAt = DateTime.UtcNow.AddDays(4);
            calibrated.SaveState();
            Check(calibrated.TryApplyManualCalibration(ProviderID.Gemini, null, null, null, "CNY", out calibrationError)
                && calibrationError == "", "empty Gemini calibration clears its quota to unknown");
            var clearedGemini = new QuotaManager(calibrationFolder).Gemini;
            Check(clearedGemini.FiveHourRemainingPercent == null && clearedGemini.WeeklyRemainingPercent == null
                && clearedGemini.FiveHourResetsAt == null && clearedGemini.WeeklyResetsAt == null
                && clearedGemini.Status == ConnectionStatus.ManualCalibrated && clearedGemini.Source == DataOrigin.Manual,
                "cleared Gemini quotas and reset times persist as unknown manual data");

            calibrated.Antigravity.FiveHourRemainingPercent = 66;
            calibrated.Antigravity.WeeklyRemainingPercent = 47;
            calibrated.Antigravity.ArgonWeeklyRemainingPercent = 24;
            calibrated.Antigravity.FiveHourResetsAt = DateTime.UtcNow.AddHours(1);
            calibrated.Antigravity.WeeklyResetsAt = DateTime.UtcNow.AddDays(2);
            calibrated.Antigravity.ArgonWeeklyResetsAt = DateTime.UtcNow.AddDays(3);
            calibrated.Antigravity.Status = ConnectionStatus.Cached;
            calibrated.SaveState();
            Check(calibrated.TryApplyManualCalibration(ProviderID.Antigravity, null, null, null, "CNY", out calibrationError)
                && calibrationError == "", "empty Antigravity calibration clears all three quota windows");
            var clearedAntigravity = new QuotaManager(calibrationFolder).Antigravity;
            Check(clearedAntigravity.FiveHourRemainingPercent == null && clearedAntigravity.WeeklyRemainingPercent == null
                && clearedAntigravity.ArgonWeeklyRemainingPercent == null && clearedAntigravity.FiveHourResetsAt == null
                && clearedAntigravity.WeeklyResetsAt == null && clearedAntigravity.ArgonWeeklyResetsAt == null
                && clearedAntigravity.Status == ConnectionStatus.ManualCalibrated && clearedAntigravity.Source == DataOrigin.Manual,
                "cleared Antigravity quotas and reset times persist as unknown manual data");

            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var window = new MainWindow(restored);
            window.ShowDashboard();
            SettleLayout(window);
            uint measuredDpi = GetDpiForWindow(new WindowInteropHelper(window).Handle);
            Console.WriteLine($"Native window DPI: {measuredDpi} ({measuredDpi / 96.0:P0} scale)");
            Check(window.IsVisible && double.IsFinite(window.Top) && double.IsFinite(window.Left),
                "dashboard opens with finite coordinates after SizeToContent");
            Check(window.ShowInTaskbar && !window.Topmost, "startup dashboard stays discoverable in Windows taskbar");
            var row = (QuotaBarRow)window.FindName("Codex5hRow");
            Check(row.RemainingPercent == 42 && row.Bar.Value == 42, "restored quota is rendered in dashboard");
            Check(row.DisplayText == "42% 剩余", "quota row uses the macOS-style remaining label");
            Check(((FrameworkElement)window.FindName("DeepSeekCard")).Visibility == Visibility.Collapsed,
                "saved provider visibility is applied to dashboard");
            using var icon = Application.GetResourceStream(new Uri("pack://application:,,,/AIQuotaMonitor;component/Resources/AppIcon.ico"))?.Stream;
            Check(icon != null && icon.Length > 0, "Windows tray icon is embedded");

            Point mainAnchor = TopLeft(window);
            CheckSettingsRoundTrips(window, isTrayPopup: false);
            restored.ToggleProviderVisibility(ProviderID.DeepSeek);
            SettleLayout(window);
            Check(SamePoint(TopLeft(window), mainAnchor), "main top-left stays fixed when a provider card is added");
            restored.ToggleProviderVisibility(ProviderID.DeepSeek);
            SettleLayout(window);
            Check(SamePoint(TopLeft(window), mainAnchor), "main top-left stays fixed when a provider card is hidden");

            window.Hide();
            window.ShowDashboard(isTrayPopup: true);
            SettleLayout(window);
            Check(!window.ShowInTaskbar && window.Topmost, "tray popup remains compact and topmost");
            CheckSettingsRoundTrips(window, isTrayPopup: true);
            Point trayAnchor = BottomRight(window);
            restored.ToggleProviderVisibility(ProviderID.DeepSeek);
            SettleLayout(window);
            Check(SamePoint(BottomRight(window), trayAnchor), $"tray anchor stays fixed when a provider card is added (visible {window.IsVisible}, expected {trayAnchor}, actual {BottomRight(window)})");
            restored.ToggleProviderVisibility(ProviderID.DeepSeek);
            SettleLayout(window);
            Check(SamePoint(BottomRight(window), trayAnchor), "tray anchor stays fixed when a provider card is hidden");
            window.Hide();
            window.ShowDashboard();
            SettleLayout(window);
            Check(SamePoint(TopLeft(window), mainAnchor), "reopening main dashboard restores its anchor after tray use");
            window.Hide();
            window.Close();

            // Simulate cursor movement without moving the user's actual cursor.
            var fixture = new Window { Width = 200, Height = 180, ShowInTaskbar = false, ShowActivated = false };
            int pointReads = 0;
            var simulatedPoint = new System.Drawing.Point(100, 100);
            var placement = new WindowPlacementController(fixture, () => { pointReads++; return simulatedPoint; });
            placement.BeginPresentation(isTrayPopup: true);
            fixture.Show();
            fixture.UpdateLayout();
            placement.Apply();
            Point capturedAnchor = BottomRight(fixture);
            simulatedPoint = new System.Drawing.Point(int.MaxValue, int.MaxValue);
            fixture.Height = 240;
            fixture.UpdateLayout();
            placement.Apply();
            Check(pointReads == 1, "content resizing never reads the cursor or chooses another monitor");
            Check(SamePoint(BottomRight(fixture), capturedAnchor), "popup resizing reuses its captured presentation anchor");
            fixture.Close();
            app.Shutdown();
            Console.WriteLine($"Desktop tests passed: {_checks}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
        finally
        {
            // Delete only the unique temporary fixture created above.
            Directory.Delete(folder, recursive: true);
        }
    }
}
