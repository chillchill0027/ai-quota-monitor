using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using AIQuotaMonitor.Models;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace AIQuotaMonitor.Services
{
    public class WebPageSessionManager
    {
        private static readonly string UserDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AIQuotaMonitor", "WebView2Profile");

        public static async Task OpenLoginWindowAsync(ProviderID provider)
        {
            var win = new Window
            {
                Title = $"{provider.GetDisplayName()} - 登录/用量页",
                Width = 980,
                Height = 720,
                WindowStartupLocation = WindowStartupLocation.CenterScreen
            };

            var webView = new WebView2();
            win.Content = webView;

            var env = await CoreWebView2Environment.CreateAsync(userDataFolder: UserDataFolder);
            await webView.EnsureCoreWebView2Async(env);

            webView.Source = new Uri(provider.GetConsoleUrl());
            win.Show();
        }

        public static async Task<string?> ReadPageTextHeadlessAsync(ProviderID provider)
        {
            try
            {
                var webView = new WebView2();
                var env = await CoreWebView2Environment.CreateAsync(userDataFolder: UserDataFolder);
                await webView.EnsureCoreWebView2Async(env);

                var tcs = new TaskCompletionSource<string?>();
                webView.NavigationCompleted += async (s, e) =>
                {
                    if (e.IsSuccess)
                    {
                        await Task.Delay(2500); // Wait for SPA DOM rendering
                        try
                        {
                            string text = await webView.ExecuteScriptAsync("document.body.innerText");
                            tcs.TrySetResult(System.Text.Json.JsonSerializer.Deserialize<string>(text));
                        }
                        catch
                        {
                            tcs.TrySetResult(null);
                        }
                    }
                    else
                    {
                        tcs.TrySetResult(null);
                    }
                };

                webView.Source = new Uri(provider.GetConsoleUrl());

                var completedTask = await Task.WhenAny(tcs.Task, Task.Delay(15000));
                if (completedTask == tcs.Task)
                {
                    return await tcs.Task;
                }
                return null;
            }
            catch
            {
                return null;
            }
        }
    }
}
