using System;
using System.Globalization;
using System.Management;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaMonitor.Models;

namespace AIQuotaMonitor.Services
{
    public static class AntigravityQuotaService
    {
        // Only loopback endpoints are used. The local language server has a self-signed certificate.
        private static readonly HttpClient HttpClient = new(new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseProxy = false,
            UseCookies = false,
            ServerCertificateCustomValidationCallback = (request, _, _, errors) =>
                request.RequestUri?.IsLoopback == true || errors == System.Net.Security.SslPolicyErrors.None
        }) { Timeout = TimeSpan.FromSeconds(15) };

        public class ConnectionInfo
        {
            public int HubPort { get; set; }
            public string CsrfToken { get; set; } = "";
        }

        internal static int? ParseHubPort(string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            if (int.TryParse(value, out int port) && port > 0 && port <= 65535) return port;
            if (Uri.TryCreate(value.Contains("://") ? value : "http://" + value, UriKind.Absolute, out var uri)
                && uri.IsLoopback && uri.Port > 0 && uri.Port <= 65535) return uri.Port;
            return null;
        }

        public static int? FindAgyHubPort()
        {
            int? configured = ParseHubPort(Environment.GetEnvironmentVariable("ANTIGRAVITY_LS_ADDRESS"))
                ?? ParseHubPort(Environment.GetEnvironmentVariable("ANTIGRAVITY_PORT"));
            if (configured != null) return configured;
            try
            {
                using var searcher = new ManagementObjectSearcher("SELECT CommandLine FROM Win32_Process WHERE Name = 'agy.exe' OR Name LIKE '%agy%'");
                searcher.Options.Timeout = TimeSpan.FromSeconds(3);
                using var results = searcher.Get();
                foreach (ManagementObject obj in results)
                {
                    using (obj)
                    {
                        string? command = obj["CommandLine"]?.ToString();
                        if (command == null) continue;
                        var match = Regex.Match(command, @"--hub-port(?:=|\s+)(\d+)");
                        if (match.Success && ParseHubPort(match.Groups[1].Value) is int port) return port;
                    }
                }
            }
            catch (ManagementException) { }
            catch (UnauthorizedAccessException) { }
            catch (System.Runtime.InteropServices.COMException) { }
            return null;
        }

        public static async Task<string> FetchCsrfTokenAsync(int hubPort, CancellationToken cancellationToken = default)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            string html = await HttpClient.GetStringAsync($"http://127.0.0.1:{hubPort}/", timeout.Token);
            var match = Regex.Match(html, "\"csrfToken\"\\s*:\\s*\"([^\"]+)\"");
            if (match.Success) return match.Groups[1].Value;
            throw new InvalidOperationException("未在 Antigravity Hub 页面中找到 CSRF Token");
        }

        public static async Task<AntigravityQuotaSnapshot> FetchQuotaAsync(CancellationToken cancellationToken = default)
        {
            // WMI is synchronous; keep process discovery off the WPF dispatcher.
            int? hubPort = await Task.Run(FindAgyHubPort, cancellationToken);
            if (hubPort == null)
            {
                var fail = AntigravityQuotaSnapshot.Placeholder;
                fail.Status = ConnectionStatus.Unavailable;
                fail.Note = "未检测到 Antigravity 运行中；请启动后重试";
                return fail;
            }
            string csrfToken;
            try { csrfToken = await FetchCsrfTokenAsync(hubPort.Value, cancellationToken); }
            catch (Exception ex) when (!cancellationToken.IsCancellationRequested
                && (ex is HttpRequestException || ex is OperationCanceledException || ex is InvalidOperationException))
            {
                csrfToken = Environment.GetEnvironmentVariable("ANTIGRAVITY_CSRF_TOKEN") ?? "";
                if (string.IsNullOrWhiteSpace(csrfToken)) throw new InvalidOperationException("未获取到 Antigravity 本地 CSRF 凭据；请检查本地服务", ex);
            }
            Exception? lastError = null;
            // Match the macOS client: try the Hub proxy, then the HTTPS language server at Hub + 5.
            foreach (string endpoint in CandidateEndpoints(hubPort.Value))
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
                    request.Headers.Add("Connect-Protocol-Version", "1");
                    request.Headers.Add("x-codeium-csrf-token", csrfToken);
                    request.Content = new StringContent("{}", Encoding.UTF8, "application/json");
                    using var response = await HttpClient.SendAsync(request, cancellationToken);
                    if (!response.IsSuccessStatusCode)
                    {
                        lastError = new InvalidOperationException($"Antigravity 本地服务错误 (HTTP {(int)response.StatusCode})");
                        continue;
                    }
                    return ParseResponse(await response.Content.ReadAsStringAsync(cancellationToken));
                }
                catch (Exception ex) when (!cancellationToken.IsCancellationRequested
                    && (ex is HttpRequestException || ex is OperationCanceledException || ex is JsonException))
                { lastError = ex; }
            }
            throw new InvalidOperationException("连接 Antigravity 本地配额服务失败；请确认兼容客户端已启动", lastError);
        }

        internal static string[] CandidateEndpoints(int hubPort)
        {
            if (hubPort < 1 || hubPort > 65535) throw new ArgumentOutOfRangeException(nameof(hubPort));
            const string rpc = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary";
            return hubPort <= 65530
                ? new[] { $"http://127.0.0.1:{hubPort}{rpc}", $"https://127.0.0.1:{hubPort + 5}{rpc}" }
                : new[] { $"http://127.0.0.1:{hubPort}{rpc}" };
        }

        internal static AntigravityQuotaSnapshot ParseResponse(string json)
        {
            var snapshot = AntigravityQuotaSnapshot.Placeholder;
            snapshot.UpdatedAt = DateTime.UtcNow;
            snapshot.Source = DataOrigin.OfficialAPI;
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("response", out var response)
                || response.ValueKind != JsonValueKind.Object || !response.TryGetProperty("groups", out var groups)
                || groups.ValueKind != JsonValueKind.Array || groups.GetArrayLength() == 0)
            {
                snapshot.Status = ConnectionStatus.Unavailable;
                snapshot.Note = "接口未返回配额分组";
                return snapshot;
            }
            foreach (var group in groups.EnumerateArray())
            {
                if (group.ValueKind != JsonValueKind.Object || !group.TryGetProperty("buckets", out var buckets)
                    || buckets.ValueKind != JsonValueKind.Array) continue;
                string name = Text(group, "displayName").ToLowerInvariant();
                foreach (var bucket in buckets.EnumerateArray())
                {
                    if (bucket.ValueKind != JsonValueKind.Object || !bucket.TryGetProperty("remainingFraction", out var fraction)
                        || fraction.ValueKind != JsonValueKind.Number || !fraction.TryGetDouble(out double remaining) || !double.IsFinite(remaining)) continue;
                    double percent = Math.Clamp(Math.Round(remaining * 100, 1), 0, 100);
                    DateTime? resetDate = DateTimeOffset.TryParse(Text(bucket, "resetTime"), CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal, out var reset) ? reset.UtcDateTime : null;
                    string window = Text(bucket, "window");
                    string displayName = Text(bucket, "displayName").ToLowerInvariant();
                    bool weekly = window == "weekly" || displayName.Contains("weekly");
                    if (name.Contains("gemini") && !name.Contains("argon"))
                    {
                        if (window == "5h" || displayName.Contains("five hour"))
                        {
                            snapshot.FiveHourRemainingPercent = percent;
                            snapshot.FiveHourResetsAt = resetDate;
                            snapshot.FiveHourResetText = FormatCountdown(resetDate);
                        }
                        else if (weekly)
                        {
                            snapshot.WeeklyRemainingPercent = percent;
                            snapshot.WeeklyResetsAt = resetDate;
                            snapshot.WeeklyResetText = FormatCountdown(resetDate);
                        }
                    }
                    else if (name.Contains("argon") && weekly)
                    {
                        snapshot.ArgonWeeklyRemainingPercent = percent;
                        snapshot.ArgonWeeklyResetsAt = resetDate;
                        snapshot.ArgonWeeklyResetText = FormatCountdown(resetDate);
                    }
                    else if ((name.Contains("claude") || name.Contains("gpt") || name.Contains("3p")) && weekly)
                    {
                        snapshot.ThirdPartyWeeklyRemainingPercent = percent;
                        snapshot.ThirdPartyWeeklyResetText = FormatCountdown(resetDate);
                    }
                }
            }
            bool hasData = snapshot.FiveHourRemainingPercent != null || snapshot.WeeklyRemainingPercent != null
                || snapshot.ArgonWeeklyRemainingPercent != null || snapshot.ThirdPartyWeeklyRemainingPercent != null;
            snapshot.Status = hasData ? ConnectionStatus.Ready : ConnectionStatus.Unavailable;
            snapshot.Note = hasData ? $"官方接口 · 本机 Language Server · {DateTime.Now:MM-dd HH:mm} 同步" : "未返回有效配额";
            return snapshot;
        }

        private static string Text(JsonElement element, string name) =>
            element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";

        private static string FormatCountdown(DateTime? resetDate)
        {
            if (resetDate == null) return "未知重置时间";
            var remaining = resetDate.Value - DateTime.UtcNow;
            if (remaining.TotalSeconds <= 0) return "即将重置";
            int totalMinutes = (int)Math.Min(int.MaxValue, Math.Ceiling(remaining.TotalMinutes));
            int days = totalMinutes / 1440;
            int hours = (totalMinutes % 1440) / 60;
            int minutes = totalMinutes % 60;
            if (days > 0) return $"重置剩余 {days}d {hours}h";
            if (hours > 0) return $"重置剩余 {hours}h {minutes}m";
            return $"重置剩余 {minutes}m";
        }
    }
}
