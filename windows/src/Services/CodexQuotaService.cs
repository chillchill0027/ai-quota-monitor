using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaMonitor.Models;

namespace AIQuotaMonitor.Services
{
    /// <summary>Reads account metadata only; never creates a thread or model turn.</summary>
    public static class CodexQuotaService
    {
        public static Task<QuotaWindowSnapshot> FetchQuotaAsync(CancellationToken cancellationToken = default)
        {
            string executable = FindExecutable() ?? throw new InvalidOperationException(
                "未找到 Codex CLI；请安装并运行 codex login 登录 ChatGPT，或设置 CODEX_CLI_PATH");
            return QueryAsync(CreateStartInfo(executable), TimeSpan.FromSeconds(20), cancellationToken);
        }

        internal static string? FindExecutable()
        {
            var candidates = new List<string>();
            string? configured = Environment.GetEnvironmentVariable("CODEX_CLI_PATH");
            if (!string.IsNullOrWhiteSpace(configured)) candidates.Add(configured.Trim().Trim('"'));
            foreach (string directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            {
                if (string.IsNullOrWhiteSpace(directory)) continue;
                string clean = Environment.ExpandEnvironmentVariables(directory.Trim().Trim('"'));
                foreach (string name in new[] { "codex.exe", "codex.cmd", "codex.bat" })
                    candidates.Add(Path.Combine(clean, name));
            }
            candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "codex.cmd"));

            // The Windows desktop app ships a versioned CLI even when Explorer's PATH is stale.
            string desktopBin = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenAI", "Codex", "bin");
            try
            {
                if (Directory.Exists(desktopBin))
                {
                    var versions = new DirectoryInfo(desktopBin).GetDirectories();
                    Array.Sort(versions, (a, b) => b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc));
                    foreach (var directory in versions) candidates.Add(Path.Combine(directory.FullName, "codex.exe"));
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }

            foreach (string candidate in candidates)
            {
                if (Path.IsPathFullyQualified(candidate) && File.Exists(candidate)) return candidate;
            }
            return null;
        }

        internal static ProcessStartInfo CreateStartInfo(string executable)
        {
            bool isScript = Path.GetExtension(executable).Equals(".cmd", StringComparison.OrdinalIgnoreCase)
                || Path.GetExtension(executable).Equals(".bat", StringComparison.OrdinalIgnoreCase);
            var startInfo = new ProcessStartInfo
            {
                FileName = isScript ? Path.Combine(Environment.SystemDirectory, "cmd.exe") : executable,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false),
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                CreateNoWindow = true,
                WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            };
            if (isScript)
                startInfo.Arguments = $"/d /s /c \"\"{executable}\" app-server\"";
            else
                startInfo.ArgumentList.Add("app-server");
            return startInfo;
        }

        // Injectable launch information lets offline tests exercise stalled/noisy child processes.
        internal static async Task<QuotaWindowSnapshot> QueryAsync(ProcessStartInfo startInfo, TimeSpan timeout, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var process = new Process { StartInfo = startInfo };
            try { process.Start(); }
            catch (Exception ex) when (ex is System.ComponentModel.Win32Exception || ex is InvalidOperationException)
            {
                throw new InvalidOperationException("无法启动 Codex CLI；请检查安装或 CODEX_CLI_PATH", ex);
            }

            using var timeoutCts = new CancellationTokenSource(timeout);
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
            var token = linkedCts.Token;
            // Drain stderr without retaining its contents, which can include local diagnostics.
            var stderrDrain = DrainAsync(process.StandardError, token);
            try
            {
                await SendAsync(process.StandardInput,
                    "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"ai_quota_monitor_win\",\"title\":\"AI额度看板\",\"version\":\"1.4.4\"}}}", token);
                await ReadResponseAsync(process.StandardOutput, 1, token);
                await SendAsync(process.StandardInput, "{\"method\":\"initialized\",\"params\":{}}", token);
                await SendAsync(process.StandardInput, "{\"id\":2,\"method\":\"account/rateLimits/read\"}", token);
                return ParseRateLimits(await ReadResponseAsync(process.StandardOutput, 2, token));
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new InvalidOperationException("Codex 额度查询超时；查询进程已结束，可稍后重试");
            }
            finally
            {
                linkedCts.Cancel();
                try { process.StandardInput.Close(); } catch (IOException) { }
                try
                {
                    if (!process.HasExited) process.Kill(entireProcessTree: true);
                    await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
                }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
                catch (TimeoutException) { }
                try { await stderrDrain.WaitAsync(TimeSpan.FromMilliseconds(100)); }
                catch (OperationCanceledException) { }
                catch (TimeoutException) { }
                catch (IOException) { }
            }
        }

        private static async Task SendAsync(StreamWriter writer, string message, CancellationToken token)
        {
            await writer.WriteLineAsync(message.AsMemory(), token);
            await writer.FlushAsync(token);
        }

        private static async Task DrainAsync(StreamReader reader, CancellationToken token)
        {
            char[] buffer = new char[4096];
            while (await reader.ReadAsync(buffer.AsMemory(), token) > 0) { }
        }

        private static async Task<JsonElement> ReadResponseAsync(StreamReader reader, int expectedId, CancellationToken token)
        {
            // EndOfStream performs a synchronous pipe read and can defeat cancellation on Windows.
            while (true)
            {
                string? line = await reader.ReadLineAsync(token);
                if (line == null) throw new InvalidOperationException("Codex CLI 已退出，未返回有效额度；请检查 codex login 登录状态");
                if (line.Length > 2_000_000) throw new InvalidOperationException("Codex CLI 返回了过大的响应");
                JsonDocument document;
                try { document = JsonDocument.Parse(line); }
                catch (JsonException) { continue; }
                using (document)
                {
                    var root = document.RootElement;
                    if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("id", out var id)
                        || id.ValueKind != JsonValueKind.Number || !id.TryGetInt32(out int numericId) || numericId != expectedId) continue;
                    if (root.TryGetProperty("error", out var error) && error.ValueKind != JsonValueKind.Null)
                        throw new InvalidOperationException("Codex 官方接口拒绝查询；请检查 codex login 登录状态或更新 CLI");
                    if (root.TryGetProperty("result", out var result) && result.ValueKind == JsonValueKind.Object)
                        return result.Clone();
                    throw new InvalidOperationException("Codex CLI 返回了无效响应");
                }
            }
        }

        internal static QuotaWindowSnapshot ParseRateLimits(JsonElement result)
        {
            var snapshot = QuotaWindowSnapshot.DefaultChatGPT;
            snapshot.UpdatedAt = DateTime.UtcNow;
            snapshot.Source = DataOrigin.OfficialAPI;
            JsonElement rootLimits = default;
            if (result.ValueKind == JsonValueKind.Object)
            {
                if (result.TryGetProperty("rateLimitsByLimitId", out var byId) && byId.ValueKind != JsonValueKind.Null)
                {
                    if (byId.ValueKind == JsonValueKind.Object && byId.TryGetProperty("codex", out var codex)) rootLimits = codex;
                }
                else if (result.TryGetProperty("rateLimits", out var legacy) && legacy.ValueKind == JsonValueKind.Object
                    && (!legacy.TryGetProperty("limitId", out var limitId) || limitId.ValueKind == JsonValueKind.Null
                        || (limitId.ValueKind == JsonValueKind.String && limitId.GetString() == "codex"))) rootLimits = legacy;
            }

            void InspectBucket(JsonElement bucket)
            {
                if (bucket.ValueKind != JsonValueKind.Object
                    || !bucket.TryGetProperty("windowDurationMins", out var durationProperty) || durationProperty.ValueKind != JsonValueKind.Number || !durationProperty.TryGetInt32(out int duration)
                    || !bucket.TryGetProperty("usedPercent", out var usedProperty) || usedProperty.ValueKind != JsonValueKind.Number
                    || !usedProperty.TryGetDouble(out double used) || !double.IsFinite(used)) return;
                DateTime? resetDate = null;
                if (bucket.TryGetProperty("resetsAt", out var resets) && resets.ValueKind == JsonValueKind.Number
                    && resets.TryGetDouble(out double seconds) && double.IsFinite(seconds) && seconds > 0 && seconds <= 253402300799)
                    resetDate = DateTimeOffset.FromUnixTimeSeconds((long)seconds).UtcDateTime;
                double remaining = Math.Clamp(100.0 - used, 0.0, 100.0);
                if (duration == 300) { snapshot.FiveHourRemainingPercent = remaining; snapshot.FiveHourResetsAt = resetDate; }
                else if (duration == 10080) { snapshot.WeeklyRemainingPercent = remaining; snapshot.WeeklyResetsAt = resetDate; }
            }
            if (rootLimits.ValueKind == JsonValueKind.Object)
            {
                if (rootLimits.TryGetProperty("primary", out var primary)) InspectBucket(primary);
                if (rootLimits.TryGetProperty("secondary", out var secondary)) InspectBucket(secondary);
            }
            bool hasData = snapshot.FiveHourRemainingPercent != null || snapshot.WeeklyRemainingPercent != null;
            snapshot.Status = hasData ? ConnectionStatus.Ready : ConnectionStatus.Unavailable;
            snapshot.Note = hasData ? "官方接口 · 本机 Codex CLI" : "Codex 未返回有效的 5 小时 / 7 天额度窗口";
            return snapshot;
        }
    }
}
