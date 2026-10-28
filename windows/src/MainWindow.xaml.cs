using System;
using System.Diagnostics;
using System.Windows;
using AIQuotaMonitor.Helpers;
using AIQuotaMonitor.Models;
using AIQuotaMonitor.Services;

namespace AIQuotaMonitor
{
    public partial class MainWindow : Window
    {
        private readonly QuotaManager _manager;

        public MainWindow(QuotaManager manager)
        {
            InitializeComponent();
            _manager = manager;
            _manager.PropertyChanged += (s, e) => Dispatcher.Invoke(UpdateUI);

            Loaded += (s, e) =>
            {
                GlassEffectHelper.EnableMicaOrAcrylic(this, isDark: true);
                UpdateUI();
            };

            Deactivated += (s, e) =>
            {
                Hide();
            };
        }

        public void ToggleVisibility()
        {
            if (IsVisible)
            {
                Hide();
            }
            else
            {
                PositionNearTray();
                Show();
                Activate();
            }
        }

        private void PositionNearTray()
        {
            // Position above the taskbar in the bottom-right corner
            var workArea = SystemParameters.WorkArea;
            Left = workArea.Right - Width - 12;
            Top = workArea.Bottom - Height - 12;
        }

        private void UpdateUI()
        {
            StatusBannerText.Text = _manager.StatusBanner;

            // DeepSeek
            DeepSeekAmount.Text = $"{_manager.DeepSeek.CurrencySymbol} {_manager.DeepSeek.TotalBalance:F2}";
            DeepSeekStatus.Text = _manager.DeepSeek.Status == ConnectionStatus.Ready ? "已同步" : _manager.DeepSeek.Status.ToString();
            DeepSeekCard.Visibility = _manager.IsProviderVisible(ProviderID.DeepSeek) ? Visibility.Visible : Visibility.Collapsed;

            // MiMo
            MiMoAmount.Text = $"{_manager.MiMo.CurrencySymbol} {_manager.MiMo.CashBalance:F2}";
            MiMoStatus.Text = _manager.MiMo.Status == ConnectionStatus.Ready ? "已同步" : _manager.MiMo.Status.ToString();
            MiMoCard.Visibility = _manager.IsProviderVisible(ProviderID.MiMo) ? Visibility.Visible : Visibility.Collapsed;

            // Codex
            Codex5hBar.Value = _manager.ChatGPT.FiveHourRemainingPercent ?? 0;
            Codex5hText.Text = _manager.ChatGPT.FiveHourRemainingPercent != null ? $"{_manager.ChatGPT.FiveHourRemainingPercent:F0}%" : "--";
            Codex7dBar.Value = _manager.ChatGPT.WeeklyRemainingPercent ?? 0;
            Codex7dText.Text = _manager.ChatGPT.WeeklyRemainingPercent != null ? $"{_manager.ChatGPT.WeeklyRemainingPercent:F0}%" : "--";
            CodexStatus.Text = _manager.ChatGPT.Status == ConnectionStatus.Ready ? "已同步" : _manager.ChatGPT.Status.ToString();
            CodexCard.Visibility = _manager.IsProviderVisible(ProviderID.ChatGPT) ? Visibility.Visible : Visibility.Collapsed;

            // Gemini
            Gemini5hBar.Value = _manager.Gemini.FiveHourRemainingPercent ?? 0;
            Gemini5hText.Text = _manager.Gemini.FiveHourRemainingPercent != null ? $"{_manager.Gemini.FiveHourRemainingPercent:F0}%" : "--";
            Gemini7dBar.Value = _manager.Gemini.WeeklyRemainingPercent ?? 0;
            Gemini7dText.Text = _manager.Gemini.WeeklyRemainingPercent != null ? $"{_manager.Gemini.WeeklyRemainingPercent:F0}%" : "--";
            GeminiStatus.Text = _manager.Gemini.Status == ConnectionStatus.Ready ? "已同步" : _manager.Gemini.Status.ToString();
            GeminiCard.Visibility = _manager.IsProviderVisible(ProviderID.Gemini) ? Visibility.Visible : Visibility.Collapsed;

            // Antigravity
            Agy5hBar.Value = _manager.Antigravity.FiveHourRemainingPercent ?? 0;
            Agy5hText.Text = _manager.Antigravity.FiveHourRemainingPercent != null ? $"{_manager.Antigravity.FiveHourRemainingPercent:F0}%" : "--";
            AgyWeeklyBar.Value = _manager.Antigravity.WeeklyRemainingPercent ?? 0;
            AgyWeeklyText.Text = _manager.Antigravity.WeeklyRemainingPercent != null ? $"{_manager.Antigravity.WeeklyRemainingPercent:F0}%" : "--";
            AgyArgonBar.Value = _manager.Antigravity.ArgonWeeklyRemainingPercent ?? 0;
            AgyArgonText.Text = _manager.Antigravity.ArgonWeeklyRemainingPercent != null ? $"{_manager.Antigravity.ArgonWeeklyRemainingPercent:F0}%" : "--";
            AntigravityStatus.Text = _manager.Antigravity.Status == ConnectionStatus.Ready ? "已同步" : _manager.Antigravity.Status.ToString();
            AntigravityCard.Visibility = _manager.IsProviderVisible(ProviderID.Antigravity) ? Visibility.Visible : Visibility.Collapsed;

            // Settings checkboxes
            CbDeepSeek.IsChecked = _manager.IsProviderVisible(ProviderID.DeepSeek);
            CbMiMo.IsChecked = _manager.IsProviderVisible(ProviderID.MiMo);
            CbCodex.IsChecked = _manager.IsProviderVisible(ProviderID.ChatGPT);
            CbGemini.IsChecked = _manager.IsProviderVisible(ProviderID.Gemini);
            CbAntigravity.IsChecked = _manager.IsProviderVisible(ProviderID.Antigravity);
        }

        private async void OnRefreshAllClick(object sender, RoutedEventArgs e)
        {
            await _manager.RefreshAllAsync(isManual: true);
        }

        private void OnSettingsToggleClick(object sender, RoutedEventArgs e)
        {
            if (SettingsPanel.Visibility == Visibility.Visible)
            {
                SettingsPanel.Visibility = Visibility.Collapsed;
                CardsContainer.Visibility = Visibility.Visible;
            }
            else
            {
                SettingsPanel.Visibility = Visibility.Visible;
                CardsContainer.Visibility = Visibility.Collapsed;
            }
        }

        private async void OnDeepSeekRefreshClick(object sender, RoutedEventArgs e) => await _manager.RefreshSingleAsync(ProviderID.DeepSeek);
        private async void OnMiMoRefreshClick(object sender, RoutedEventArgs e) => await _manager.RefreshSingleAsync(ProviderID.MiMo);
        private async void OnCodexRefreshClick(object sender, RoutedEventArgs e) => await _manager.RefreshSingleAsync(ProviderID.ChatGPT);
        private async void OnGeminiRefreshClick(object sender, RoutedEventArgs e) => await _manager.RefreshSingleAsync(ProviderID.Gemini);
        private async void OnAgyRefreshClick(object sender, RoutedEventArgs e) => await _manager.RefreshSingleAsync(ProviderID.Antigravity);

        private async void OnMiMoLoginClick(object sender, RoutedEventArgs e) => await WebPageSessionManager.OpenLoginWindowAsync(ProviderID.MiMo);
        private async void OnGeminiLoginClick(object sender, RoutedEventArgs e) => await WebPageSessionManager.OpenLoginWindowAsync(ProviderID.Gemini);

        private void OnDeepSeekKeyConfigClick(object sender, RoutedEventArgs e)
        {
            string current = CredentialStorage.ReadDeepSeekKey();
            var input = Microsoft.VisualBasic.Interaction.InputBox("请输入 DeepSeek API Key（将使用 Windows DPAPI 加密存于本机）：", "DeepSeek API Key 设置", current);
            if (!string.IsNullOrEmpty(input))
            {
                CredentialStorage.SaveDeepSeekKey(input.Trim());
                _ = _manager.RefreshSingleAsync(ProviderID.DeepSeek);
            }
        }

        private void OnAgyHubClick(object sender, RoutedEventArgs e)
        {
            int? port = AntigravityQuotaService.FindAgyHubPort() ?? 62433;
            Process.Start(new ProcessStartInfo($"http://127.0.0.1:{port}") { UseShellExecute = true });
        }

        private void OnProviderToggle(object sender, RoutedEventArgs e)
        {
            if (sender == CbDeepSeek) _manager.ToggleProviderVisibility(ProviderID.DeepSeek);
            else if (sender == CbMiMo) _manager.ToggleProviderVisibility(ProviderID.MiMo);
            else if (sender == CbCodex) _manager.ToggleProviderVisibility(ProviderID.ChatGPT);
            else if (sender == CbGemini) _manager.ToggleProviderVisibility(ProviderID.Gemini);
            else if (sender == CbAntigravity) _manager.ToggleProviderVisibility(ProviderID.Antigravity);
            UpdateUI();
        }

        private void OnExitClick(object sender, RoutedEventArgs e)
        {
            ((App)Application.Current).ExitApp();
        }
    }
}
