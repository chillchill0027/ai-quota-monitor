using System;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace AIQuotaMonitor.Controls
{
    /// <summary>The compact label/remaining-value/capsule row shared with the macOS dashboard.</summary>
    public partial class QuotaBarRow : UserControl
    {
        public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
            nameof(Label), typeof(string), typeof(QuotaBarRow), new PropertyMetadata("", OnRowChanged));
        public static readonly DependencyProperty RemainingPercentProperty = DependencyProperty.Register(
            nameof(RemainingPercent), typeof(double?), typeof(QuotaBarRow), new PropertyMetadata(null, OnRowChanged));
        public static readonly DependencyProperty ResetHintProperty = DependencyProperty.Register(
            nameof(ResetHint), typeof(string), typeof(QuotaBarRow), new PropertyMetadata("未提供重置时间", OnRowChanged));
        public static readonly DependencyProperty MissingLabelProperty = DependencyProperty.Register(
            nameof(MissingLabel), typeof(string), typeof(QuotaBarRow), new PropertyMetadata("未读取", OnRowChanged));
        public static readonly DependencyProperty TintProperty = DependencyProperty.Register(
            nameof(Tint), typeof(Brush), typeof(QuotaBarRow), new PropertyMetadata(null, OnRowChanged));

        public string Label { get => (string)GetValue(LabelProperty); set => SetValue(LabelProperty, value); }
        public double? RemainingPercent { get => (double?)GetValue(RemainingPercentProperty); set => SetValue(RemainingPercentProperty, value); }
        public string ResetHint { get => (string)GetValue(ResetHintProperty); set => SetValue(ResetHintProperty, value); }
        public string MissingLabel { get => (string)GetValue(MissingLabelProperty); set => SetValue(MissingLabelProperty, value); }
        public Brush? Tint { get => (Brush?)GetValue(TintProperty); set => SetValue(TintProperty, value); }
        public ProgressBar Bar => QuotaBar;
        public string DisplayText => ValueLabel.Text;

        public QuotaBarRow()
        {
            InitializeComponent();
            UpdateRow();
        }

        protected override void OnPropertyChanged(DependencyPropertyChangedEventArgs e)
        {
            base.OnPropertyChanged(e);
            if (e.Property == ForegroundProperty && ValueLabel != null) UpdateRow();
        }

        private static void OnRowChanged(DependencyObject sender, DependencyPropertyChangedEventArgs e)
        {
            var row = (QuotaBarRow)sender;
            if (row.ValueLabel != null) row.UpdateRow();
        }

        private void UpdateRow()
        {
            bool available = RemainingPercent.HasValue && double.IsFinite(RemainingPercent.Value);
            double percent = available ? Math.Clamp(RemainingPercent!.Value, 0, 100) : 0;
            QuotaBar.Value = percent;
            ValueLabel.Text = available ? percent.ToString("F0", CultureInfo.CurrentCulture) + "% 剩余" : MissingLabel;
            ValueLabel.FontWeight = available ? FontWeights.SemiBold : FontWeights.Normal;
            ValueLabel.SetResourceReference(TextBlock.ForegroundProperty,
                available ? (percent < 20 ? "WarningBrush" : "PrimaryTextBrush") : "SecondaryTextBrush");
            if (available && percent < 20)
                QuotaBar.SetResourceReference(ProgressBar.ForegroundProperty, "WarningBrush");
            else
                QuotaBar.Foreground = Gradient(Tint ?? Foreground);
            ToolTip = ResetHint;
            AutomationProperties.SetName(this, Label + "，" + ValueLabel.Text);
            AutomationProperties.SetHelpText(this, ResetHint);
        }

        private static Brush Gradient(Brush brush)
        {
            if (brush is not SolidColorBrush solid) return brush;
            Color end = solid.Color;
            Color start = Color.FromArgb((byte)Math.Round(end.A * 0.82), end.R, end.G, end.B);
            var gradient = new LinearGradientBrush(start, end, new Point(0, 0), new Point(1, 0));
            gradient.Freeze();
            return gradient;
        }
    }
}
