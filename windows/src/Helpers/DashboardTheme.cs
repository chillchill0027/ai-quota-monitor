using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace AIQuotaMonitor.Helpers
{
    public static class DashboardTheme
    {
        private static bool _initialized;
        public static bool IsDark { get; private set; }
        public static event Action? Changed;

        public static void EnsureInitialized()
        {
            if (_initialized) return;
            _initialized = true;
            Apply(WindowsGlassBackdrop.IsSystemDarkTheme());
            Application.Current.Resources.MergedDictionaries.Add(new ResourceDictionary
            {
                Source = new Uri("/AIQuotaMonitor;component/Resources/MacTheme.xaml", UriKind.Relative)
            });
            SystemEvents.UserPreferenceChanged += (_, _) =>
            {
                var dispatcher = Application.Current?.Dispatcher;
                if (dispatcher != null && !dispatcher.HasShutdownStarted)
                    dispatcher.BeginInvoke(new Action(() => Apply(WindowsGlassBackdrop.IsSystemDarkTheme())));
            };
        }

        public static void Apply(bool dark)
        {
            IsDark = dark;
            var resources = Application.Current.Resources;
            void Brush(string key, string value) => resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(value));
            Brush("PrimaryTextBrush", dark ? "#F2F2F7" : "#22232A");
            Brush("SecondaryTextBrush", dark ? "#A1A1AA" : "#74747E");
            Brush("QuotaTrackBrush", dark ? "#12FFFFFF" : "#12000000");
            Brush("AccentBrush", dark ? "#0A84FF" : "#007AFF");
            Brush("WarningBrush", dark ? "#FF9F0A" : "#D57600");
            Brush("SuccessBrush", dark ? "#30D158" : "#248A3D");
            Brush("ManualBrush", dark ? "#40C8E0" : "#007F91");
            Brush("ErrorBrush", dark ? "#FF453A" : "#D9322B");
            Brush("ControlBrush", dark ? "#16FFFFFF" : "#45FFFFFF");
            Brush("ControlHoverBrush", dark ? "#25FFFFFF" : "#75FFFFFF");
            Brush("ControlPressedBrush", dark ? "#35FFFFFF" : "#A0FFFFFF");
            Brush("OutlineBrush", dark ? "#21FFFFFF" : "#A6FFFFFF");
            Brush("DividerBrush", dark ? "#1AFFFFFF" : "#17000000");
            Brush("SelectionBrush", dark ? "#1F0A84FF" : "#1F007AFF");
            Brush("InactiveTileBrush", dark ? "#0AFFFFFF" : "#0A000000");
            Brush("MenuSurfaceBrush", dark ? "#F52B2B31" : "#FAF6F6F8");
            Brush("InputSurfaceBrush", dark ? "#35000000" : "#70FFFFFF");
            resources["CardSurfaceBrush"] = new LinearGradientBrush(
                (Color)ColorConverter.ConvertFromString(dark ? "#29000000" : "#4DFFFFFF"),
                (Color)ColorConverter.ConvertFromString(dark ? "#1A000000" : "#24FFFFFF"),
                new Point(0, 0), new Point(1, 1));
            if (SystemParameters.HighContrast)
            {
                resources["PrimaryTextBrush"] = SystemColors.WindowTextBrush;
                resources["SecondaryTextBrush"] = SystemColors.WindowTextBrush;
                resources["CardSurfaceBrush"] = SystemColors.WindowBrush;
                resources["OutlineBrush"] = SystemColors.WindowTextBrush;
            }
            Changed?.Invoke();
        }
    }
}
