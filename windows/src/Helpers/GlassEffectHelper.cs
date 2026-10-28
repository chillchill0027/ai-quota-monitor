using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace AIQuotaMonitor.Helpers
{
    public static class GlassEffectHelper
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;

        public static void EnableMicaOrAcrylic(Window window, bool isDark = false)
        {
            try
            {
                var helper = new WindowInteropHelper(window);
                var hwnd = helper.EnsureHandle();

                int darkMode = isDark ? 1 : 0;
                DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int));

                // 2 = Mica, 3 = Acrylic, 4 = Mica Alt
                int backdrop = 3;
                DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
            }
            catch { }
        }
    }
}
