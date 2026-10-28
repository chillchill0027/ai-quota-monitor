using System;
using System.Windows;
using AIQuotaMonitor.Helpers;
using AIQuotaMonitor.Services;

namespace AIQuotaMonitor.Views
{
    public partial class KeyConfigDialog : Window
    {
        public bool Saved { get; private set; }

        public KeyConfigDialog()
        {
            InitializeComponent();
            Loaded += (s, e) =>
            {
                GlassEffectHelper.EnableMicaOrAcrylic(this, isDark: true);
                KeyInputBox.Text = CredentialStorage.ReadDeepSeekKey();
                KeyInputBox.Focus();
                KeyInputBox.SelectAll();
            };
        }

        private void OnSaveClick(object sender, RoutedEventArgs e)
        {
            string key = KeyInputBox.Text.Trim();
            CredentialStorage.SaveDeepSeekKey(key);
            Saved = true;
            Close();
        }

        private void OnClearClick(object sender, RoutedEventArgs e)
        {
            CredentialStorage.SaveDeepSeekKey(string.Empty);
            Saved = true;
            Close();
        }

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            Saved = false;
            Close();
        }
    }
}
