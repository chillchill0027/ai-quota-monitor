using System;
using System.Drawing;
using System.Security.Principal;
using System.Threading;
using System.Windows;
using System.Windows.Forms;
using AIQuotaMonitor.Services;
using Application = System.Windows.Application;

namespace AIQuotaMonitor
{
    public partial class App : Application
    {
        private Mutex? _instanceMutex;
        private bool _ownsMutex;
        private EventWaitHandle? _activationEvent;
        private RegisteredWaitHandle? _activationWait;
        private NotifyIcon? _notifyIcon;
        private MainWindow? _mainWindow;
        public static QuotaManager Manager { get; } = new();
        public bool IsExiting { get; private set; }

        protected override void OnStartup(StartupEventArgs e)
        {
            // Scope instances to the current Windows user and login session.
            string instanceName = @"Local\AIQuotaMonitor_" + WindowsIdentity.GetCurrent().User?.Value;
            _instanceMutex = new Mutex(false, instanceName);
            try { _ownsMutex = _instanceMutex.WaitOne(0); }
            catch (AbandonedMutexException) { _ownsMutex = true; }
            if (!_ownsMutex)
            {
                try
                {
                    using var activation = EventWaitHandle.OpenExisting(instanceName + "_Activate");
                    activation.Set();
                }
                catch (WaitHandleCannotBeOpenedException) { }
                Shutdown();
                return;
            }

            base.OnStartup(e);
            _mainWindow = new MainWindow(Manager);
            MainWindow = _mainWindow;
            InitTrayIcon();
            _activationEvent = new EventWaitHandle(false, EventResetMode.AutoReset, instanceName + "_Activate");
            _activationWait = ThreadPool.RegisterWaitForSingleObject(_activationEvent,
                (_, _) => Dispatcher.BeginInvoke(new Action(() => _mainWindow?.ShowDashboard())),
                null, Timeout.Infinite, false);

            // Opening the app shows cached data; account access is an explicit refresh.
            _mainWindow.ShowDashboard();
        }

        private void InitTrayIcon()
        {
            _notifyIcon = new NotifyIcon { Text = "AI 额度看板", Visible = true };
            try
            {
                using var stream = GetResourceStream(new Uri("pack://application:,,,/Resources/AppIcon.ico"))?.Stream;
                _notifyIcon.Icon = stream != null ? new Icon(stream) : SystemIcons.Application;
            }
            catch { _notifyIcon.Icon = SystemIcons.Application; }

            var contextMenu = new ContextMenuStrip();
            contextMenu.Items.Add("打开看板", null, (_, _) => _mainWindow?.ShowDashboard());
            contextMenu.Items.Add("立即刷新全部", null, async (_, _) => await Manager.RefreshAllAsync(isManual: true));
            contextMenu.Items.Add(new ToolStripSeparator());
            contextMenu.Items.Add("退出", null, (_, _) => ExitApp());
            _notifyIcon.ContextMenuStrip = contextMenu;
            _notifyIcon.MouseClick += (_, e) =>
            {
                if (e.Button == MouseButtons.Left) _mainWindow?.ToggleVisibility();
            };
        }

        public void ExitApp()
        {
            if (IsExiting) return;
            IsExiting = true;
            Manager.SaveState();
            Shutdown();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            IsExiting = true;
            _activationWait?.Unregister(null);
            _activationEvent?.Dispose();
            if (_notifyIcon != null)
            {
                _notifyIcon.Visible = false;
                _notifyIcon.Dispose();
            }
            if (_ownsMutex) _instanceMutex?.ReleaseMutex();
            _instanceMutex?.Dispose();
            base.OnExit(e);
        }
    }
}
