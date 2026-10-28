using System;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using AIQuotaMonitor.Helpers;
using AIQuotaMonitor.Services;
using Microsoft.Win32;

namespace AIQuotaMonitor.Views
{
    public partial class KeyConfigDialog : Window
    {
        private bool _loaded;
        private bool _revealing;
        private bool _hasStoredKey;
        public bool Saved { get; private set; }
        private string CurrentInput => _revealing ? RevealedKeyInput.Text : KeyInputBox.Password;

        public KeyConfigDialog()
        {
            InitializeComponent();
            WindowsGlassBackdrop.Attach(this, DialogSurface, WindowsGlassBackdrop.IsSystemDarkTheme(), 20);
            ApplyTheme();
            UpdateInputState();
            Loaded += OnLoaded;
            Closed += (_, _) =>
            {
                SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
                _loaded = false;
                _revealing = false;
                KeyInputBox.Clear();
                RevealedKeyInput.Clear();
            };
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            if (_loaded) return;
            _loaded = true;
            string storedKey = CredentialStorage.ReadDeepSeekKey();
            _hasStoredKey = !string.IsNullOrEmpty(storedKey);
            KeyInputBox.Password = storedKey;
            UpdateInputState();
            KeyInputBox.Focus();
            KeyInputBox.SelectAll();
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        }

        private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (!Dispatcher.HasShutdownStarted) Dispatcher.BeginInvoke(new Action(ApplyTheme));
        }

        private void ApplyTheme()
        {
            bool dark = WindowsGlassBackdrop.IsSystemDarkTheme();
            if (SystemParameters.HighContrast)
            {
                Resources["DialogText"] = SystemColors.WindowTextBrush;
                Resources["DialogSecondaryText"] = SystemColors.WindowTextBrush;
                Resources["DialogControlBackground"] = SystemColors.WindowBrush;
                Resources["DialogControlBorder"] = SystemColors.WindowTextBrush;
                Resources["DialogButtonBackground"] = SystemColors.ControlBrush;
                Resources["DialogDangerText"] = SystemColors.WindowTextBrush;
            }
            else
            {
                Resources["DialogText"] = Brush(dark ? "#F1F2F5" : "#20232C");
                Resources["DialogSecondaryText"] = Brush(dark ? "#A5ABB7" : "#737985");
                Resources["DialogControlBackground"] = Brush(dark ? "#35000000" : "#80FFFFFF");
                Resources["DialogControlBorder"] = Brush(dark ? "#35FFFFFF" : "#30000000");
                Resources["DialogButtonBackground"] = Brush(dark ? "#22FFFFFF" : "#70FFFFFF");
                Resources["DialogDangerText"] = Brush(dark ? "#FF999C" : "#BB3B43");
            }
            WindowsGlassBackdrop.SetTheme(this, dark);
        }

        private static SolidColorBrush Brush(string color)
        {
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
            brush.Freeze();
            return brush;
        }

        private void OnPasswordChanged(object sender, RoutedEventArgs e)
        {
            if (_loaded && !_revealing) UpdateInputState();
        }

        private void OnRevealedKeyChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
        {
            if (_loaded && _revealing) UpdateInputState();
        }

        private void UpdateInputState()
        {
            bool hasInput = !string.IsNullOrWhiteSpace(CurrentInput);
            KeyPlaceholder.Visibility = CurrentInput.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            SaveButton.IsEnabled = hasInput;
            ClearButton.IsEnabled = _hasStoredKey || hasInput;
            InlineError.Visibility = Visibility.Collapsed;
        }

        private void OnRevealClick(object sender, RoutedEventArgs e)
        {
            if (_revealing)
            {
                KeyInputBox.Password = RevealedKeyInput.Text;
                _revealing = false;
                RevealedKeyInput.Clear();
                RevealedKeyInput.Visibility = Visibility.Collapsed;
                KeyInputBox.Visibility = Visibility.Visible;
                KeyInputBox.Focus();
                KeyInputBox.SelectAll();
            }
            else
            {
                RevealedKeyInput.Text = KeyInputBox.Password;
                _revealing = true;
                KeyInputBox.Visibility = Visibility.Collapsed;
                RevealedKeyInput.Visibility = Visibility.Visible;
                RevealedKeyInput.Focus();
                RevealedKeyInput.SelectAll();
            }
            RevealButton.Content = _revealing ? "隐藏" : "显示";
            string label = _revealing ? "隐藏 API Key" : "显示 API Key";
            RevealButton.ToolTip = label;
            System.Windows.Automation.AutomationProperties.SetName(RevealButton, label);
            UpdateInputState();
        }

        private void OnSaveClick(object sender, RoutedEventArgs e)
        {
            string key = CurrentInput.Trim();
            if (key.Any(char.IsWhiteSpace))
            {
                ShowError("API Key 不能包含空格或换行，请检查后重试。");
                return;
            }
            SaveKey(key);
        }

        private void OnClearClick(object sender, RoutedEventArgs e) => SaveKey(string.Empty);

        private void SaveKey(string key)
        {
            try
            {
                if (!CredentialStorage.SaveDeepSeekKey(key))
                {
                    ShowError("无法保存，请检查本地应用数据目录是否可写。");
                    return;
                }
                Saved = true;
                Close();
            }
            catch (Exception)
            {
                ShowError("无法保存，请检查本地应用数据目录是否可写。");
            }
        }

        private void ShowError(string message)
        {
            InlineError.Text = message;
            InlineError.Visibility = Visibility.Visible;
        }

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            Saved = false;
            Close();
        }

        private void OnHeaderMouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton == MouseButton.Left && e.ButtonState == MouseButtonState.Pressed) DragMove();
        }
    }
}
