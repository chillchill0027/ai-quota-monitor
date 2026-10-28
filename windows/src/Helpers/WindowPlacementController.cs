using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace AIQuotaMonitor.Helpers
{
    /// <summary>
    /// Saves a presentation's screen and anchor, rather than following the cursor
    /// every time settings or provider cards change the window's measured height.
    /// All native coordinates in this class are physical screen pixels.
    /// </summary>
    public sealed class WindowPlacementController
    {
        private const int Margin = 12;
        private readonly Window _window;
        private readonly Func<System.Drawing.Point> _getPresentationPoint;
        private System.Drawing.Rectangle _workArea;
        private System.Drawing.Rectangle _mainWorkArea;
        private bool _hasPresentation;
        private bool _isTrayPopup;
        private bool _hasMainPosition;
        private bool _applying;
        private bool _placementQueued;
        private int _mainLeft;
        private int _mainTop;
        private double _dpiScaleY = 1;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativePoint { public int X, Y; }
        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(NativePoint point, uint flags);
        [DllImport("shcore.dll")]
        private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);

        public WindowPlacementController(Window window, Func<System.Drawing.Point>? getPresentationPoint = null)
        {
            _window = window;
            _getPresentationPoint = getPresentationPoint ?? (() => Forms.Cursor.Position);
        }

        /// <summary>Maximum presentation height in WPF device-independent units.</summary>
        public double AvailableHeight
        {
            get
            {
                int top = !_isTrayPopup && _hasMainPosition
                    ? ClampTopEdge(_mainTop)
                    : _workArea.Top + Margin;
                return Math.Max(1, (_workArea.Bottom - Margin - top) / _dpiScaleY);
            }
        }

        /// <summary>
        /// Call before showing the window. A tray click captures its display once;
        /// the main window reuses the position chosen initially or by a user drag.
        /// </summary>
        public void BeginPresentation(bool isTrayPopup)
        {
            _isTrayPopup = isTrayPopup;
            if (isTrayPopup)
            {
                _workArea = Forms.Screen.FromPoint(_getPresentationPoint()).WorkingArea;
            }
            else if (_hasMainPosition)
            {
                // A removed display should not leave the main window unreachable.
                var savedScreen = Forms.Screen.FromPoint(new System.Drawing.Point(_mainLeft, _mainTop));
                _mainWorkArea = savedScreen.WorkingArea;
                _workArea = _mainWorkArea;
            }
            else
            {
                _workArea = Forms.Screen.FromPoint(_getPresentationPoint()).WorkingArea;
                _mainWorkArea = _workArea;
            }
            _dpiScaleY = GetPresentationDpiScale();
            _hasPresentation = true;
        }

        /// <summary>
        /// Call after Show/UpdateLayout and on SizeChanged. A main window keeps its
        /// top-left; a popup keeps the captured work area's bottom-right anchor.
        /// </summary>
        public void Apply()
        {
            ApplyCore();
            if (_placementQueued || !_hasPresentation || !_window.IsVisible || _window.Dispatcher.HasShutdownStarted) return;
            // SizeChanged can precede the HWND's native resize. Coalesce one
            // placement after WPF has finished layout and updated the native rect.
            _placementQueued = true;
            _window.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
            {
                _placementQueued = false;
                ApplyCore();
            }));
        }

        private void ApplyCore()
        {
            if (!_hasPresentation || !_window.IsVisible || _applying) return;
            var handle = new WindowInteropHelper(_window).Handle;
            if (handle == IntPtr.Zero || !GetWindowRect(handle, out var rect)) return;
            int width = rect.Right - rect.Left;
            int height = rect.Bottom - rect.Top;
            if (width <= 0 || height <= 0) return;

            int left;
            int top;
            if (_isTrayPopup)
            {
                left = _workArea.Right - width - Margin;
                top = _workArea.Bottom - height - Margin;
            }
            else
            {
                if (!_hasMainPosition)
                {
                    _mainLeft = _workArea.Left + (_workArea.Width - width) / 2;
                    _mainTop = _workArea.Top + (_workArea.Height - height) / 2;
                    _hasMainPosition = true;
                }
                left = _mainLeft;
                top = _mainTop;
            }

            left = ClampToWorkArea(left, width, _workArea.Left, _workArea.Right);
            // The content viewport limits a normal window's height to AvailableHeight.
            // Its top edge must not move when that viewport grows or shrinks.
            top = _isTrayPopup
                ? ClampToWorkArea(top, height, _workArea.Top, _workArea.Bottom)
                : ClampTopEdge(top);
            if (rect.Left == left && rect.Top == top) return;
            _applying = true;
            try
            {
                // SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE.
                SetWindowPos(handle, IntPtr.Zero, left, top, 0, 0, 0x0015);
            }
            finally { _applying = false; }
        }

        /// <summary>Call after an explicit user DragMove, not every LocationChanged.</summary>
        public void RememberUserPosition()
        {
            if (_isTrayPopup || _applying) return;
            var handle = new WindowInteropHelper(_window).Handle;
            if (handle == IntPtr.Zero || !GetWindowRect(handle, out var rect)) return;
            _mainLeft = rect.Left;
            _mainTop = rect.Top;
            _hasMainPosition = true;
            _mainWorkArea = Forms.Screen.FromHandle(handle).WorkingArea;
            _workArea = _mainWorkArea;
            _dpiScaleY = GetPresentationDpiScale();
        }

        private static int ClampToWorkArea(int position, int size, int start, int end)
        {
            int minimum = start + Margin;
            int maximum = Math.Max(minimum, end - size - Margin);
            return Math.Clamp(position, minimum, maximum);
        }

        private int ClampTopEdge(int top) => Math.Clamp(top, _workArea.Top + Margin,
            Math.Max(_workArea.Top + Margin, _workArea.Bottom - Margin - 1));

        private double GetPresentationDpiScale()
        {
            try
            {
                var monitor = MonitorFromPoint(new NativePoint
                {
                    X = _workArea.Left + _workArea.Width / 2,
                    Y = _workArea.Top + _workArea.Height / 2
                }, 2);
                if (GetDpiForMonitor(monitor, 0, out _, out uint dpiY) == 0 && dpiY > 0)
                    return dpiY / 96.0;
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
            return VisualTreeHelper.GetDpi(_window).DpiScaleY;
        }
    }
}
