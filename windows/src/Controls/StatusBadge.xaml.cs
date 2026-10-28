using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using AIQuotaMonitor.Models;

namespace AIQuotaMonitor.Controls
{
    /// <summary>Quiet 10-point capsule status indicator matching the shared dashboard.</summary>
    public partial class StatusBadge : UserControl
    {
        public static readonly DependencyProperty StatusProperty = DependencyProperty.Register(
            nameof(Status), typeof(ConnectionStatus), typeof(StatusBadge),
            new PropertyMetadata(ConnectionStatus.NeedsSetup, OnStatusChanged));
        public static readonly DependencyProperty IsRefreshingProperty = DependencyProperty.Register(
            nameof(IsRefreshing), typeof(bool), typeof(StatusBadge), new PropertyMetadata(false, OnStatusChanged));

        public ConnectionStatus Status { get => (ConnectionStatus)GetValue(StatusProperty); set => SetValue(StatusProperty, value); }
        public bool IsRefreshing { get => (bool)GetValue(IsRefreshingProperty); set => SetValue(IsRefreshingProperty, value); }
        public string DisplayText => StatusTitle.Text;

        public StatusBadge()
        {
            InitializeComponent();
            UpdateBadge();
        }

        private static void OnStatusChanged(DependencyObject sender, DependencyPropertyChangedEventArgs e)
        {
            var badge = (StatusBadge)sender;
            if (badge.StatusTitle != null) badge.UpdateBadge();
        }

        private void UpdateBadge()
        {
            bool loading = IsRefreshing || Status == ConnectionStatus.Loading;
            StatusTitle.Text = loading ? "刷新中" : Status switch
            {
                ConnectionStatus.Ready => "已刷新",
                ConnectionStatus.Cached => "缓存",
                ConnectionStatus.ManualCalibrated => "手动",
                ConnectionStatus.NeedsSetup => "待配置",
                ConnectionStatus.Error => "失败",
                ConnectionStatus.Unavailable => "未提供",
                _ => "待配置"
            };
            string colorKey = loading ? "AccentBrush" : Status switch
            {
                ConnectionStatus.Ready => "SuccessBrush",
                ConnectionStatus.Error => "ErrorBrush",
                ConnectionStatus.ManualCalibrated => "ManualBrush",
                _ => "SecondaryTextBrush"
            };
            BadgeBackground.SetResourceReference(Border.BackgroundProperty, colorKey);
            StatusDot.SetResourceReference(Shape.FillProperty, colorKey);
            Spinner.SetResourceReference(Shape.StrokeProperty, colorKey);
            StatusDot.Visibility = loading ? Visibility.Collapsed : Visibility.Visible;
            Spinner.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
            IndicatorHost.Width = loading ? 8 : 4;
            if (loading)
            {
                SpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.8))
                { RepeatBehavior = RepeatBehavior.Forever });
            }
            else SpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, null);
            AutomationProperties.SetName(this, "刷新状态：" + StatusTitle.Text);
        }
    }
}
