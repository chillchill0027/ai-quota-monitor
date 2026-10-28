using System;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using AIQuotaMonitor.Controls;
using AIQuotaMonitor.Helpers;
using AIQuotaMonitor.Models;
using AIQuotaMonitor.Services;

namespace AIQuotaMonitor
{
    public partial class MainWindow : Window
    {
        private readonly QuotaManager _manager;
        private readonly WindowPlacementController _placement;
        private readonly DispatcherTimer _displayTimer;
        private bool _showingDialog;
        private bool _isTrayPopup;
        private bool _showingSettings;
        private bool _menuOpen;

        public MainWindow(QuotaManager manager)
        {
            DashboardTheme.EnsureInitialized();
            InitializeComponent();
            _manager = manager;
            _placement = new WindowPlacementController(this);
            WindowsGlassBackdrop.Attach(this, DashboardSurface, DashboardTheme.IsDark, 24);
            _manager.PropertyChanged += OnManagerChanged;
            DashboardTheme.Changed += OnThemeChanged;
            _displayTimer = new DispatcherTimer(TimeSpan.FromMinutes(1), DispatcherPriority.Background,
                (_, _) => UpdateUI(), Dispatcher);
            Loaded += (_, _) => { UpdateUI(); _placement.Apply(); };
            SizeChanged += (_, _) => _placement.Apply();
            Deactivated += (_, _) => Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
            {
                if (_isTrayPopup && !IsActive && !_showingDialog && !_menuOpen &&
                    !OwnedWindows.Cast<Window>().Any(w => w.IsActive)) Hide();
            }));
            PreviewKeyDown += (_, e) =>
            {
                if (e.Key == Key.Escape)
                {
                    if (_showingSettings) ToggleSettings();
                    else Hide();
                    e.Handled = true;
                }
            };
            Closing += (_, e) =>
            {
                if (Application.Current is not App app || app.IsExiting) return;
                e.Cancel = true;
                Hide();
            };
            Closed += (_, _) =>
            {
                _displayTimer.Stop();
                _manager.PropertyChanged -= OnManagerChanged;
                DashboardTheme.Changed -= OnThemeChanged;
            };
            UpdateUI();
        }

        private void OnManagerChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
        {
            if (!Dispatcher.HasShutdownStarted) Dispatcher.BeginInvoke(new Action(UpdateUI));
        }

        private void OnThemeChanged()
        {
            WindowsGlassBackdrop.SetTheme(this, DashboardTheme.IsDark);
            UpdateUI();
        }

        public void ToggleVisibility()
        {
            if (IsVisible) Hide();
            else ShowDashboard(isTrayPopup: true);
        }

        public void ShowDashboard(bool isTrayPopup = false)
        {
            _isTrayPopup = isTrayPopup;
            ShowInTaskbar = !isTrayPopup;
            Topmost = isTrayPopup;
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
            _placement.BeginPresentation(isTrayPopup);
            ConfigureViewport();
            Show();
            UpdateLayout();
            _placement.Apply();
            ConfigureViewport();
            UpdateLayout();
            _placement.Apply();
            Activate();
        }

        private void ConfigureViewport()
        {
            MaxHeight = Math.Max(100, Math.Min(920, _placement.AvailableHeight));
            double contentHeight = Math.Max(36, MaxHeight - 72);
            CardsScrollViewer.MaxHeight = contentHeight;
            SettingsScrollViewer.MaxHeight = contentHeight;
        }

        public void ToggleSettings()
        {
            _showingSettings = !_showingSettings;
            HeaderTitle.Text = _showingSettings ? "设置" : "AI 额度";
            SettingsGlyph.Text = _showingSettings ? "\uE711" : "\uE713";
            SettingsBtn.ToolTip = _showingSettings ? "返回看板" : "设置";
            AutomationProperties.SetName(SettingsBtn, _showingSettings ? "返回看板" : "设置");
            RefreshAllBtn.Visibility = _showingSettings ? Visibility.Collapsed : Visibility.Visible;
            CardsScrollViewer.Visibility = _showingSettings ? Visibility.Collapsed : Visibility.Visible;
            SettingsScrollViewer.Visibility = _showingSettings ? Visibility.Visible : Visibility.Collapsed;
            ConfigureViewport();
            UpdateLayout();
            _placement.Apply();
        }

        private void OnHeaderDrag(object sender, MouseButtonEventArgs e)
        {
            if (_isTrayPopup || e.ChangedButton != MouseButton.Left) return;
            if (e.OriginalSource is DependencyObject source)
            {
                for (var parent = source; parent != null; parent = VisualTreeHelper.GetParent(parent))
                    if (parent is ButtonBase) return;
            }
            try { DragMove(); }
            catch (InvalidOperationException) { return; }
            _placement.RememberUserPosition();
            ConfigureViewport();
        }

        private static void SetStatus(StatusBadge badge, ConnectionStatus status, string? note, DateTime updatedAt, bool refreshing)
        {
            badge.Status = status;
            badge.IsRefreshing = refreshing;
            // Older caches can still refer to the former inline action buttons.
            note = note?.Replace("「用量页登录」", "供应商菜单中的「打开用量小窗」")
                .Replace("「配置 Key」", "供应商菜单中的「配置 API Key」");
            badge.ToolTip = string.Join("\n", new[]
            {
                note,
                updatedAt == DateTime.MinValue ? "尚未读取到账户数据" : "上次读取：" + updatedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
            }.Where(s => !string.IsNullOrWhiteSpace(s)));
        }

        private static void SetQuota(QuotaBarRow row, double? value, DateTime? reset = null, string? resetText = null, string missing = "未读取")
        {
            row.RemainingPercent = value;
            row.MissingLabel = missing;
            row.ResetHint = reset.HasValue
                ? (reset.Value <= DateTime.UtcNow ? "已到重置时间，请刷新" : reset.Value.ToLocalTime().ToString("MM-dd HH:mm") + " 重置")
                : resetText ?? "未提供重置时间";
        }

        private void UpdateUI()
        {
            StatusBannerText.Text = _manager.StatusBanner;
            RefreshAllBtn.ToolTip = "刷新全部五家，包括重新加载并读取两个用量小窗\n" + _manager.StatusBanner;
            RefreshAllBtn.IsEnabled = !_manager.IsRefreshing;
            RefreshLabel.Text = _manager.IsRefreshing ? "刷新中" : "全部刷新";
            bool Refreshing(ProviderID provider) => _manager.RefreshingProviders.Contains(provider);

            DeepSeekAmount.Text = _manager.DeepSeek.UpdatedAt == DateTime.MinValue ? "—" : $"{_manager.DeepSeek.CurrencySymbol} {_manager.DeepSeek.TotalBalance:F2}";
            DeepSeekAmount.SetResourceReference(TextBlock.ForegroundProperty,
                _manager.DeepSeek.UpdatedAt != DateTime.MinValue && _manager.DeepSeek.TotalBalance < 5 ? "WarningBrush" : "PrimaryTextBrush");
            SetStatus(DeepSeekStatus, _manager.DeepSeek.Status, _manager.DeepSeek.ErrorMessage ?? "可供 API 调用", _manager.DeepSeek.UpdatedAt, Refreshing(ProviderID.DeepSeek));
            DeepSeekCard.Visibility = _manager.IsProviderVisible(ProviderID.DeepSeek) ? Visibility.Visible : Visibility.Collapsed;
            MiMoAmount.Text = _manager.MiMo.UpdatedAt == DateTime.MinValue ? "—" : $"{_manager.MiMo.CurrencySymbol} {_manager.MiMo.CashBalance:F2}";
            MiMoAmount.SetResourceReference(TextBlock.ForegroundProperty,
                _manager.MiMo.UpdatedAt != DateTime.MinValue && _manager.MiMo.CashBalance < 5 ? "WarningBrush" : "PrimaryTextBrush");
            SetStatus(MiMoStatus, _manager.MiMo.Status, _manager.MiMo.Note, _manager.MiMo.UpdatedAt, Refreshing(ProviderID.MiMo));
            MiMoCard.Visibility = _manager.IsProviderVisible(ProviderID.MiMo) ? Visibility.Visible : Visibility.Collapsed;

            string CodexMissing(DateTime? reset) => reset <= DateTime.UtcNow ? "已过期" :
                _manager.ChatGPT.Status is ConnectionStatus.Ready or ConnectionStatus.Unavailable ? "未提供" : "未读取";
            SetQuota(Codex5hRow, _manager.ChatGPT.CodexRemaining(false), _manager.ChatGPT.FiveHourResetsAt, _manager.ChatGPT.FiveHourResetText, CodexMissing(_manager.ChatGPT.FiveHourResetsAt));
            SetQuota(Codex7dRow, _manager.ChatGPT.CodexRemaining(true), _manager.ChatGPT.WeeklyResetsAt, _manager.ChatGPT.WeeklyResetText, CodexMissing(_manager.ChatGPT.WeeklyResetsAt));
            SetStatus(CodexStatus, _manager.ChatGPT.Status, _manager.ChatGPT.Note, _manager.ChatGPT.UpdatedAt, Refreshing(ProviderID.ChatGPT));
            CodexCard.Visibility = _manager.IsProviderVisible(ProviderID.ChatGPT) ? Visibility.Visible : Visibility.Collapsed;
            SetQuota(Gemini5hRow, _manager.Gemini.FiveHourRemainingPercent, _manager.Gemini.FiveHourResetsAt, _manager.Gemini.FiveHourResetText);
            SetQuota(Gemini7dRow, _manager.Gemini.WeeklyRemainingPercent, _manager.Gemini.WeeklyResetsAt, _manager.Gemini.WeeklyResetText);
            SetStatus(GeminiStatus, _manager.Gemini.Status, _manager.Gemini.Note, _manager.Gemini.UpdatedAt, Refreshing(ProviderID.Gemini));
            GeminiCard.Visibility = _manager.IsProviderVisible(ProviderID.Gemini) ? Visibility.Visible : Visibility.Collapsed;
            SetQuota(Agy5hRow, _manager.Antigravity.FiveHourRemainingPercent, _manager.Antigravity.FiveHourResetsAt, _manager.Antigravity.FiveHourResetText);
            SetQuota(AgyWeeklyRow, _manager.Antigravity.WeeklyRemainingPercent, _manager.Antigravity.WeeklyResetsAt, _manager.Antigravity.WeeklyResetText);
            SetQuota(AgyArgonRow, _manager.Antigravity.ArgonWeeklyRemainingPercent, _manager.Antigravity.ArgonWeeklyResetsAt, _manager.Antigravity.ArgonWeeklyResetText);
            SetStatus(AntigravityStatus, _manager.Antigravity.Status, _manager.Antigravity.Note, _manager.Antigravity.UpdatedAt, Refreshing(ProviderID.Antigravity));
            AntigravityCard.Visibility = _manager.IsProviderVisible(ProviderID.Antigravity) ? Visibility.Visible : Visibility.Collapsed;

            foreach (var toggle in new[] { CbDeepSeek, CbMiMo, CbCodex, CbGemini, CbAntigravity })
            {
                if (!Enum.TryParse<ProviderID>((string)toggle.Tag, out var provider)) continue;
                toggle.IsChecked = _manager.IsProviderVisible(provider);
                toggle.IsEnabled = _manager.CanToggleProvider(provider);
                toggle.ToolTip = toggle.IsEnabled ? provider.GetShortName() : "至少保留一个供应商";
                AutomationProperties.SetItemStatus(toggle, toggle.IsChecked == true ? "已显示" : "已隐藏");
            }
        }

        private void OnProviderMenuClick(object sender, RoutedEventArgs e)
        {
            if (sender is not Button button || !Enum.TryParse<ProviderID>((string)button.Tag, out var provider)) return;
            var menu = new ContextMenu { PlacementTarget = button, Placement = PlacementMode.Bottom, StaysOpen = false };
            void Item(string title, Action action, bool enabled = true)
            {
                var item = new MenuItem { Header = title, IsEnabled = enabled };
                item.Click += (_, _) => action();
                menu.Items.Add(item);
            }
            Item("刷新此项", async () => await _manager.RefreshSingleAsync(provider), !_manager.IsRefreshing);
            if (provider is ProviderID.MiMo or ProviderID.Gemini)
                Item("打开用量小窗", async () => await WebPageSessionManager.OpenLoginWindowAsync(provider));
            Item(provider == ProviderID.Antigravity ? "打开 Hub" : "打开官方用量页", () => OpenOfficialPage(provider));
            menu.Items.Add(new Separator());
            if (provider == ProviderID.DeepSeek) Item("配置 API Key", ConfigureKey);
            else if (provider != ProviderID.ChatGPT) Item("手动校准", () => Calibrate(provider));
            if (provider is ProviderID.DeepSeek or ProviderID.ChatGPT or ProviderID.Antigravity)
                Item("已处理账户，解除暂停", () => _manager.ResumeProvider(provider));
            Item("刷新详情", () => ShowDetails(provider));
            menu.Opened += (_, _) => _menuOpen = true;
            menu.Closed += (_, _) => _menuOpen = false;
            button.ContextMenu = menu;
            menu.IsOpen = true;
        }

        private void ConfigureKey()
        {
            _showingDialog = true;
            var dialog = new Views.KeyConfigDialog { Owner = this };
            try { dialog.ShowDialog(); }
            finally { _showingDialog = false; }
            Activate();
            if (dialog.Saved) _ = _manager.RefreshSingleAsync(ProviderID.DeepSeek);
        }

        private void Calibrate(ProviderID provider)
        {
            _showingDialog = true;
            try { new Views.CalibrationDialog(_manager, provider) { Owner = this }.ShowDialog(); }
            finally { _showingDialog = false; Activate(); }
            UpdateUI();
        }

        private void ShowDetails(ProviderID provider)
        {
            string note = provider switch
            {
                ProviderID.DeepSeek => DeepSeekStatus.ToolTip?.ToString() ?? "",
                ProviderID.MiMo => MiMoStatus.ToolTip?.ToString() ?? "",
                ProviderID.ChatGPT => CodexStatus.ToolTip?.ToString() ?? "",
                ProviderID.Gemini => GeminiStatus.ToolTip?.ToString() ?? "",
                _ => AntigravityStatus.ToolTip?.ToString() ?? ""
            };
            _showingDialog = true;
            try { MessageBox.Show(this, note, provider.GetShortName() + " · 刷新详情", MessageBoxButton.OK, MessageBoxImage.Information); }
            finally { _showingDialog = false; Activate(); }
        }

        private void OpenOfficialPage(ProviderID provider)
        {
            string url = provider == ProviderID.Antigravity
                ? $"http://127.0.0.1:{AntigravityQuotaService.FindAgyHubPort() ?? 62433}"
                : provider.GetConsoleUrl();
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { MessageBox.Show(this, "无法打开默认浏览器。", "AI 额度看板"); }
        }

        private async void OnRefreshAllClick(object sender, RoutedEventArgs e) => await _manager.RefreshAllAsync(true);
        private void OnSettingsToggleClick(object sender, RoutedEventArgs e) => ToggleSettings();
        private void OnHideClick(object sender, RoutedEventArgs e) => Hide();
        private void OnMinimizeClick(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
        private void OnProviderToggle(object sender, RoutedEventArgs e)
        {
            if (sender is ToggleButton toggle && Enum.TryParse<ProviderID>((string)toggle.Tag, out var provider))
                _manager.ToggleProviderVisibility(provider);
            UpdateUI();
        }
        private void OnExitClick(object sender, RoutedEventArgs e) { if (Application.Current is App app) app.ExitApp(); }
    }
}
