using System;
using System.Diagnostics;
using System.Management;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using AIQuotaMonitor.Models;

namespace AIQuotaMonitor.Services
{
    public static class AntigravityQuotaService
    {
        private static readonly HttpClient HttpClient = new()
        {
            Timeout = TimeSpan.FromSeconds(15)
        };

        public class ConnectionInfo
        {
            public int HubPort { get; set; }
            public string CsrfToken { get; set; } = "";
        }

        public static int? FindAgyHubPort()
        {
            // 1. Check environment variables
            string? envAddr = Environment.GetEnvironmentVariable("ANTIGRAVITY_LS_ADDRESS");
            if (!string.IsNullOrEmpty(envAddr))
            {
                var parts = envAddr.Split(':');
                if (int.TryParse(parts[^1], out int port)) return port;
            }
            string? envPort = Environment.GetEnvironmentVariable("ANTIGRAVITY_PORT");
            if (int.TryParse(envPort, out int ep)) return ep;

            // 2. Query running processes via WMI for --hub-port=(\d+)
            try
            {
                using var searcher = new ManagementObjectSearcher("SELECT CommandLine FROM Win32_Process WHERE Name = 'agy.exe' OR Name LIKE '%agy%'");
                foreach (ManagementObject obj in searcher.Get())
                {
                    string? cmdLine = obj["CommandLine"]?.ToString();
                    if (string.IsNullOrEmpty(cmdLine)) continue;

                    var match = Regex.Match(cmdLine, @"--hub-port=(\d+)");
                    if (match.Success && int.TryParse(match.Groups[1].Value, out int p))
                    {
                        return p;
                    }
                }
            }
            catch { }

            return null;
        }

        public static async Task<string> FetchCsrfTokenAsync(int hubPort)
        {
            string url = $"http://127.0.0.1:{hubPort}/";
            string html = await HttpClient.GetStringAsync(url);
            var match = Regex.Match(html, @"""csrfToken"":""([^""]+)""");
            if (match.Success)
            {
                return match.Groups[1].Value;
            }
            throw new InvalidOperationException("未在 Antigravity Hub 页面中找到 CSRF Token");
        }

        public static async Task<AntigravityQuotaSnapshot> FetchQuotaAsync()
        {
            int? hubPort = FindAgyHubPort();
            if (hubPort == null)
            {
                var fail = AntigravityQuotaSnapshot.Placeholder;
                fail.Status = ConnectionStatus.Unavailable;
                fail.Note = "未检测到 Antigravity 运行中；请启动后重试";
                return fail;
            }

            string csrfToken = await FetchCsrfTokenAsync(hubPort.Value);

            string rpcUrl = $"http://127.0.0.1:{hubPort.Value}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary";
            using var req = new HttpRequestMessage(HttpMethod.Post, rpcUrl);
            req.Headers.Add("Connect-Protocol-Version", "1");
            req.Headers.Add("x-codeium-csrf-token", csrfToken);
            req.Content = new StringContent("{}", System.Text.Encoding.UTF8, "application/json");

            using var resp = await HttpClient.SendAsync(req);
            if (!resp.IsSuccessStatusCode)
            {
                var fail = AntigravityQuotaSnapshot.Placeholder;
                fail.Status = ConnectionStatus.Error;
                fail.Note = $"本地服务错误 (HTTP {(int)resp.StatusCode})";
                return fail;
            }

            string json = await resp.Content.ReadAsStringAsync();
            return ParseResponse(json);
        }

        private static AntigravityQuotaSnapshot ParseResponse(string json)
        {
            var snap = AntigravityQuotaSnapshot.Placeholder;
            snap.UpdatedAt = DateTime.UtcNow;
            snap.Source = DataOrigin.OfficialAPI;

            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("response", out var respObj) ||
                !respObj.TryGetProperty("groups", out var groups) ||
                groups.GetArrayLength() == 0)
            {
                snap.Status = ConnectionStatus.Unavailable;
                snap.Note = "接口未返回配额分组";
                return snap;
            }

            foreach (var group in groups.EnumerateArray())
            {
                string groupName = (group.TryGetProperty("displayName", out var dn) ? dn.GetString() : "")?.ToLowerInvariant() ?? "";
                if (!group.TryGetProperty("buckets", out var buckets)) continue;

                if (groupName.Contains("gemini models") || (groupName.Contains("gemini") && !groupName.Contains("argon")))
                {
                    foreach (var b in buckets.EnumerateArray())
                    {
                        string window = b.TryGetProperty("window", out var w) ? w.GetString() ?? "" : "";
                        double frac = b.TryGetProperty("remainingFraction", out var rf) ? rf.GetDouble() : 0.0;
                        string? resetTimeStr = b.TryGetProperty("resetTime", out var rt) ? rt.GetString() : null;
                        DateTime? resetDate = DateTime.TryParse(resetTimeStr, null, System.Globalization.DateTimeStyles.RoundtripKind, out var dt) ? dt.ToUniversalTime() : null;

                        double percent = Math.Clamp(Math.Round(frac * 100.0, 1), 0.0, 100.0);

                        if (window == "5h")
                        {
                            snap.FiveHourRemainingPercent = percent;
                            snap.FiveHourResetsAt = resetDate;
                            snap.FiveHourResetText = FormatCountdown(resetDate);
                        }
                        else if (window == "weekly")
                        {
                            snap.WeeklyRemainingPercent = percent;
                            snap.WeeklyResetsAt = resetDate;
                            snap.WeeklyResetText = FormatCountdown(resetDate);
                        }
                    }
                }
                else if (groupName.Contains("argon"))
                {
                    foreach (var b in buckets.EnumerateArray())
                    {
                        double frac = b.TryGetProperty("remainingFraction", out var rf) ? rf.GetDouble() : 0.0;
                        string? resetTimeStr = b.TryGetProperty("resetTime", out var rt) ? rt.GetString() : null;
                        DateTime? resetDate = DateTime.TryParse(resetTimeStr, null, System.Globalization.DateTimeStyles.RoundtripKind, out var dt) ? dt.ToUniversalTime() : null;
                        snap.ArgonWeeklyRemainingPercent = Math.Clamp(Math.Round(frac * 100.0, 1), 0.0, 100.0);
                        snap.ArgonWeeklyResetsAt = resetDate;
                        snap.ArgonWeeklyResetText = FormatCountdown(resetDate);
                    }
                }
                else if (groupName.Contains("claude") || groupName.Contains("gpt") || groupName.Contains("3p"))
                {
                    foreach (var b in buckets.EnumerateArray())
                    {
                        double frac = b.TryGetProperty("remainingFraction", out var rf) ? rf.GetDouble() : 0.0;
                        snap.ThirdPartyWeeklyRemainingPercent = Math.Clamp(Math.Round(frac * 100.0, 1), 0.0, 100.0);
                    }
                }
            }

            bool hasData = snap.FiveHourRemainingPercent != null || snap.WeeklyRemainingPercent != null;
            snap.Status = hasData ? ConnectionStatus.Ready : ConnectionStatus.Unavailable;
            snap.Note = hasData ? $"官方接口 · 本机 Language Server · {DateTime.Now:MM-dd HH:mm} 同步" : "未返回有效配额";
            return snap;
        }

        private static string FormatCountdown(DateTime? resetDate)
        {
            if (resetDate == null) return "未知重置时间";
            var remaining = resetDate.Value - DateTime.UtcNow;
            if (remaining.TotalSeconds <= 0) return "即将重置";

            int totalMinutes = (int)Math.Ceiling(remaining.TotalMinutes);
            int days = totalMinutes / 1440;
            int hours = (totalMinutes % 1440) / 60;
            int minutes = totalMinutes % 60;

            if (days > 0) return $"重置剩余 {days}d {hours}h";
            if (hours > 0) return $"重置剩余 {hours}h {minutes}m";
            return $"重置剩余 {minutes}m";
        }
    }
}
