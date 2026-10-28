using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaMonitor.Models;

namespace AIQuotaMonitor.Services
{
    public static class CodexQuotaService
    {
        public static async Task<QuotaWindowSnapshot> FetchQuotaAsync(CancellationToken cancellationToken = default)
        {
            var psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/c codex app-server",
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };

            using var process = new Process { StartInfo = psi };
            try
            {
                process.Start();
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException($"无法启动 Codex CLI: {ex.Message}");
            }

            using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);

            try
            {
                var stdin = process.StandardInput;
                var stdout = process.StandardOutput;

                // 1. Send initialize
                string initMsg = "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"ai_quota_monitor_win\",\"title\":\"AI额度看板\",\"version\":\"1.4.4\"}}}\n";
                await stdin.WriteAsync(initMsg.AsMemory(), linkedCts.Token);
                await stdin.FlushAsync();

                // Wait for initialize response
                while (!stdout.EndOfStream)
                {
                    string? line = await stdout.ReadLineAsync(linkedCts.Token);
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    using var doc = JsonDocument.Parse(line);
                    if (doc.RootElement.TryGetProperty("id", out var idProp) && idProp.GetInt32() == 1)
                    {
                        break;
                    }
                }

                // 2. Send account/rateLimits/read
                string queryMsg = "{\"id\":2,\"method\":\"account/rateLimits/read\"}\n";
                await stdin.WriteAsync(queryMsg.AsMemory(), linkedCts.Token);
                await stdin.FlushAsync();

                while (!stdout.EndOfStream)
                {
                    string? line = await stdout.ReadLineAsync(linkedCts.Token);
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    using var doc = JsonDocument.Parse(line);
                    if (doc.RootElement.TryGetProperty("id", out var idProp) && idProp.GetInt32() == 2)
                    {
                        if (doc.RootElement.TryGetProperty("error", out var errorProp))
                        {
                            string msg = errorProp.GetProperty("message").GetString() ?? "RPC error";
                            throw new InvalidOperationException(msg);
                        }

                        if (doc.RootElement.TryGetProperty("result", out var resultProp))
                        {
                            return ParseRateLimits(resultProp);
                        }
                    }
                }

                throw new InvalidOperationException("未接收到 Codex 有效限额数据");
            }
            finally
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch { }
            }
        }

        private static QuotaWindowSnapshot ParseRateLimits(JsonElement result)
        {
            var snapshot = QuotaWindowSnapshot.DefaultChatGPT;
            snapshot.UpdatedAt = DateTime.UtcNow;
            snapshot.Source = DataOrigin.OfficialAPI;

            JsonElement rootLimits = result;
            if (result.TryGetProperty("rateLimitsByLimitId", out var byId) && byId.TryGetProperty("codex", out var codexLimit))
            {
                rootLimits = codexLimit;
            }
            else if (result.TryGetProperty("rateLimits", out var legacyLimits))
            {
                rootLimits = legacyLimits;
            }

            void InspectBucket(JsonElement bucket)
            {
                if (bucket.ValueKind != JsonValueKind.Object) return;
                int duration = bucket.TryGetProperty("windowDurationMins", out var dProp) ? dProp.GetInt32() : 0;
                double used = bucket.TryGetProperty("usedPercent", out var uProp) ? uProp.GetDouble() : 0.0;
                long resetsAt = bucket.TryGetProperty("resetsAt", out var rProp) ? rProp.GetInt64() : 0;
                DateTime? resetDate = resetsAt > 0 ? DateTimeOffset.FromUnixTimeSeconds(resetsAt).UtcDateTime : null;

                double remaining = Math.Clamp(100.0 - used, 0.0, 100.0);

                if (duration == 300)
                {
                    snapshot.FiveHourRemainingPercent = remaining;
                    snapshot.FiveHourResetsAt = resetDate;
                }
                else if (duration == 10080)
                {
                    snapshot.WeeklyRemainingPercent = remaining;
                    snapshot.WeeklyResetsAt = resetDate;
                }
            }

            if (rootLimits.TryGetProperty("primary", out var primary)) InspectBucket(primary);
            if (rootLimits.TryGetProperty("secondary", out var secondary)) InspectBucket(secondary);

            bool hasData = snapshot.FiveHourRemainingPercent != null || snapshot.WeeklyRemainingPercent != null;
            snapshot.Status = hasData ? ConnectionStatus.Ready : ConnectionStatus.Unavailable;
            snapshot.Note = hasData ? "官方接口 · 本机 Codex CLI" : "Codex 未返回有效额度窗口";
            return snapshot;
        }
    }
}
