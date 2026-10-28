using System;
using System.Drawing;
using System.Threading;
using System.Windows;
using System.Windows.Forms;
using AIQuotaMonitor.Services;
using Application = System.Windows.Application;

namespace AIQuotaMonitor
{
    public partial class App : Application
    {
        private static Mutex? _instanceMutex;
        private NotifyIcon? _notifyIcon;
        private MainWindow? _mainWindow;
        public static QuotaManager Manager { get; } = new();

        protected override void OnStartup(StartupEventArgs e)
        {
            const string mutexName = @"Global\AIQuotaMonitor_SingleInstance_Mutex";
            _instanceMutex = new Mutex(true, mutexName, out bool isNewInstance);
            if (!isNewInstance)
            {
                System.Windows.MessageBox.Show("AI 额度看板已经在后台运行中，请检查任务栏右下角托盘图标。", "AI 额度看板", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
            }

            base.OnStartup(e);

            _mainWindow = new MainWindow(Manager);

            InitTrayIcon();

            // Initial refresh
            _ = Manager.RefreshAllAsync(isManual: false);
        }

        private void InitTrayIcon()
        {
            _notifyIcon = new NotifyIcon
            {
                Text = "AI 额度看板",
                Visible = true
            };

            try
            {
                using var stream = GetResourceStream(new Uri("pack://application:,,,/Resources/AppIcon.ico"))?.Stream;
                if (stream != null)
                {
                    _notifyIcon.Icon = new Icon(stream);
                }
                else
                {
                    _notifyIcon.Icon = SystemIcons.Application;
                }
            }
            catch
            {
                _notifyIcon.Icon = SystemIcons.Application;
            }

            var contextMenu = new ContextMenuStrip();
            contextMenu.Items.Add("打开看板", null, (s, e) => _mainWindow?.ToggleVisibility());
            contextMenu.Items.Add("立即刷新全部", null, async (s, e) => await Manager.RefreshAllAsync(isManual: true));
            contextMenu.Items.Add(new ToolStripSeparator());
            contextMenu.Items.Add("退出", null, (s, e) => ExitApp());

            _notifyIcon.ContextMenuStrip = contextMenu;
            _notifyIcon.MouseClick += (s, e) =>
            {
                if (e.Button == MouseButtons.Left)
                {
                    _mainWindow?.ToggleVisibility();
                }
            };
        }

        public void ExitApp()
        {
            if (_notifyIcon != null)
            {
                _notifyIcon.Visible = false;
                _notifyIcon.Dispose();
            }
            _instanceMutex?.ReleaseMutex();
            Shutdown();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _notifyIcon?.Dispose();
            _instanceMutex?.Dispose();
            base.OnExit(e);
        }
    }
}
