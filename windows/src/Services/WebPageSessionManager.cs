using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using AIQuotaMonitor.Models;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace AIQuotaMonitor.Services
{
    public static class WebPageSessionManager
    {
        private static readonly string UserDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AIQuotaMonitor", "WebView2Profile");

        private static readonly Dictionary<ProviderID, Window> LoginWindows = new();
        private static Task<CoreWebView2Environment>? _environment;

        private static Task<CoreWebView2Environment> GetEnvironmentAsync()
        {
            if (_environment == null || _environment.IsFaulted || _environment.IsCanceled)
                _environment = CoreWebView2Environment.CreateAsync(userDataFolder: UserDataFolder);
            return _environment;
        }

        public static async Task OpenLoginWindowAsync(ProviderID provider)
        {
            if (LoginWindows.TryGetValue(provider, out var existing))
            {
                if (existing.WindowState == WindowState.Minimized) existing.WindowState = WindowState.Normal;
                existing.Activate();
                return;
            }

            var webView = new WebView2();
            var win = new Window
            {
                Title = $"{provider.GetDisplayName()} - 登录/用量页",
                Width = Math.Min(980, SystemParameters.WorkArea.Width),
                Height = Math.Min(720, SystemParameters.WorkArea.Height),
                WindowStartupLocation = WindowStartupLocation.CenterScreen,
                Content = webView
            };
            if (Application.Current.MainWindow?.IsVisible == true)
                win.Owner = Application.Current.MainWindow;
            LoginWindows[provider] = win;
            bool closed = false;
            win.Closed += (_, _) =>
            {
                closed = true;
                LoginWindows.Remove(provider);
                webView.Dispose();
            };

            // WPF WebView2 needs a presentation source (HWND) before initialization.
            win.Show();
            try
            {
                var environment = await GetEnvironmentAsync().WaitAsync(TimeSpan.FromSeconds(20));
                if (closed) return;
                await webView.EnsureCoreWebView2Async(environment).WaitAsync(TimeSpan.FromSeconds(20));
                if (closed) return;
                webView.Source = new Uri(provider.GetConsoleUrl());
            }
            catch (Exception ex)
            {
                if (closed) return;
                win.Close();
                MessageBox.Show($"无法打开用量页。请确认已安装 Microsoft Edge WebView2 运行时。\n{ex.Message}",
                    "AI 额度看板", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }

        public static async Task<string?> ReadPageTextHeadlessAsync(ProviderID provider)
        {
            // Do not query a webpage before the user has opened its login window.
            if (!Directory.Exists(UserDataFolder)) return null;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            using var webView = new WebView2();
            var host = new Window
            {
                Width = 980, Height = 720, Left = -32000, Top = -32000,
                ShowActivated = false, ShowInTaskbar = false,
                WindowStyle = WindowStyle.None, Opacity = 0,
                Content = webView
            };
            try
            {
                // A detached WPF WebView2 may wait forever during initialization.
                host.Show();
                var environment = await GetEnvironmentAsync().WaitAsync(timeout.Token);
                await webView.EnsureCoreWebView2Async(environment).WaitAsync(timeout.Token);
                var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e) =>
                    loaded.TrySetResult(e.IsSuccess);
                webView.NavigationCompleted += OnNavigationCompleted;
                try
                {
                    webView.Source = new Uri(provider.GetConsoleUrl());
                    if (!await loaded.Task.WaitAsync(timeout.Token)) return null;
                    // SPA data may appear after navigation. Read only visible DOM text.
                    while (true)
                    {
                        string json = await webView.ExecuteScriptAsync("document.body ? document.body.innerText : ''")
                            .WaitAsync(timeout.Token);
                        string? text = JsonSerializer.Deserialize<string>(json);
                        if (provider == ProviderID.MiMo && WebQuotaParser.ParseMiMoBalance(text ?? "") != null)
                            return text;
                        if (provider == ProviderID.Gemini)
                        {
                            var quota = WebQuotaParser.ParseGemini(text ?? "");
                            if (quota.FiveHour != null || quota.Weekly != null) return text;
                        }
                        await Task.Delay(500, timeout.Token);
                    }
                }
                finally { webView.NavigationCompleted -= OnNavigationCompleted; }
            }
            catch
            {
                return null;
            }
            finally { host.Close(); }
        }
    }
}
