using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using AIQuotaMonitor.Helpers;
using AIQuotaMonitor.Models;
using AIQuotaMonitor.Services;

namespace AIQuotaMonitor.Views
{
    public sealed class CalibrationDialog : Window
    {
        private readonly QuotaManager _manager;
        private readonly ProviderID _provider;
        private readonly List<TextBox> _inputs = new();
        private readonly ComboBox? _currency;
        private readonly TextBlock _error;

        public CalibrationDialog(QuotaManager manager, ProviderID provider)
        {
            DashboardTheme.EnsureInitialized();
            _manager = manager;
            _provider = provider;
            Title = provider.GetShortName() + " · 手动校准";
            Width = provider == ProviderID.MiMo ? 300 : 320;
            SizeToContent = SizeToContent.Height;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            AllowsTransparency = false;
            Background = Brushes.Transparent;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
            SetResourceReference(ForegroundProperty, "PrimaryTextBrush");
            var panel = new StackPanel();
            var surface = new Border { Padding = new Thickness(16), Child = panel };
            Content = surface;
            var heading = new TextBlock
            {
                Text = provider.GetShortName() + (provider == ProviderID.MiMo ? " 现金余额" : " 剩余额度"),
                FontSize = 14, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 14)
            };
            heading.MouseLeftButtonDown += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed) DragMove(); };
            panel.Children.Add(heading);

            if (provider == ProviderID.MiMo)
            {
                _currency = new ComboBox { ItemsSource = new[] { "人民币 CNY", "美元 USD" }, SelectedIndex = manager.MiMo.CurrencyCode == "USD" ? 1 : 0, Margin = new Thickness(0, 0, 0, 10), Padding = new Thickness(6, 4, 6, 4), FontSize = 12 };
                panel.Children.Add(_currency);
                AddInput(panel, "余额", manager.MiMo.UpdatedAt == DateTime.MinValue ? null : manager.MiMo.CashBalance);
            }
            else
            {
                AddInput(panel, "5 小时", provider == ProviderID.Gemini ? manager.Gemini.FiveHourRemainingPercent : manager.Antigravity.FiveHourRemainingPercent);
                AddInput(panel, "7 天", provider == ProviderID.Gemini ? manager.Gemini.WeeklyRemainingPercent : manager.Antigravity.WeeklyRemainingPercent);
                if (provider == ProviderID.Antigravity) AddInput(panel, "Argon · 7 天", manager.Antigravity.ArgonWeeklyRemainingPercent);
                var hint = new TextBlock { Text = "填写剩余百分比（0–100），未提供的窗口可留空。", FontSize = 10, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 8) };
                hint.SetResourceReference(TextBlock.ForegroundProperty, "SecondaryTextBrush");
                panel.Children.Add(hint);
            }
            _error = new TextBlock { FontSize = 11, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 2, 0, 10) };
            _error.SetResourceReference(TextBlock.ForegroundProperty, "ErrorBrush");
            panel.Children.Add(_error);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 6, 0, 0) };
            var cancel = new Button { Content = "取消", IsCancel = true, Style = (Style)FindResource("GlassButton"), Margin = new Thickness(0, 0, 8, 0) };
            cancel.Click += (_, _) => Close();
            var save = new Button { Content = "保存", IsDefault = true, Style = (Style)FindResource("GlassButton"), Foreground = Brushes.White, Tag = "Primary" };
            save.Click += (_, _) => Save();
            actions.Children.Add(cancel);
            actions.Children.Add(save);
            panel.Children.Add(actions);
            WindowsGlassBackdrop.Attach(this, surface, DashboardTheme.IsDark, 18);
            DashboardTheme.Changed += UpdateTheme;
            Closed += (_, _) => DashboardTheme.Changed -= UpdateTheme;
            Loaded += (_, _) => { _inputs[0].Focus(); _inputs[0].SelectAll(); };
        }

        private void UpdateTheme() => WindowsGlassBackdrop.SetTheme(this, DashboardTheme.IsDark);

        private void AddInput(Panel panel, string title, double? value)
        {
            var grid = new Grid { Margin = new Thickness(0, 0, 0, 10) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            if (_provider != ProviderID.MiMo) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var label = new TextBlock { Text = title, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
            var input = new TextBox { Text = value?.ToString(_provider == ProviderID.MiMo ? "F2" : "G", CultureInfo.CurrentCulture) ?? "", FontSize = 12, Padding = new Thickness(7, 5, 7, 5), BorderThickness = new Thickness(0.5) };
            input.SetResourceReference(TextBox.BackgroundProperty, "InputSurfaceBrush");
            input.SetResourceReference(TextBox.ForegroundProperty, "PrimaryTextBrush");
            input.SetResourceReference(TextBox.BorderBrushProperty, "OutlineBrush");
            System.Windows.Automation.AutomationProperties.SetName(input, title);
            Grid.SetColumn(input, 1);
            grid.Children.Add(label);
            grid.Children.Add(input);
            if (_provider != ProviderID.MiMo)
            {
                var suffix = new TextBlock { Text = "%", FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
                suffix.SetResourceReference(TextBlock.ForegroundProperty, "SecondaryTextBrush");
                Grid.SetColumn(suffix, 2);
                grid.Children.Add(suffix);
            }
            panel.Children.Add(grid);
            _inputs.Add(input);
        }

        private void Save()
        {
            var values = new double?[3];
            for (int index = 0; index < _inputs.Count; index++)
            {
                string text = _inputs[index].Text.Trim();
                if (text.Length == 0) continue;
                if (!double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out double value) &&
                    !double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value))
                { ShowError("请输入有效数字。"); return; }
                values[index] = value;
            }
            if (!_manager.TryApplyManualCalibration(_provider, values[0], values[1], values[2], _currency?.SelectedIndex == 1 ? "USD" : "CNY", out string error))
            { ShowError(error); return; }
            DialogResult = true;
        }

        private void ShowError(string error) { _error.Text = error; _error.Visibility = Visibility.Visible; }
    }
}
