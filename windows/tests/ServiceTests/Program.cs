using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using AIQuotaMonitor.Models;
using AIQuotaMonitor.Services;

if (args.Length > 0 && args[0] == "--fake-codex")
{
    string mode = args[1];
    if (args.Length > 2) File.WriteAllText(args[2], Environment.ProcessId.ToString());
    if (mode == "silent") { await Task.Delay(30000); return; }
    if (mode == "exit") return;
    string? init = await Console.In.ReadLineAsync();
    if (init == null || !init.Contains("initialize")) Environment.Exit(11);
    if (mode == "reject") { Console.WriteLine("{\"id\":1,\"error\":{\"message\":\"synthetic\"}}"); return; }
    await Console.Error.WriteAsync(new string('x', 200000));
    await Console.Error.FlushAsync();
    Console.WriteLine("non-JSON startup diagnostic");
    Console.WriteLine("{\"id\":\"notification\"}");
    Console.WriteLine("{\"id\":1,\"result\":{}}");
    string? initialized = await Console.In.ReadLineAsync();
    if (initialized == null || !initialized.Contains("\"method\":\"initialized\"")) Environment.Exit(12);
    string? query = await Console.In.ReadLineAsync();
    if (query == null || !query.Contains("account/rateLimits/read")) Environment.Exit(13);
    Console.WriteLine("{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"windowDurationMins\":300,\"usedPercent\":25,\"resetsAt\":1999999999}}}}");
    await Task.Delay(30000);
    return;
}
if (args.Contains("--live-codex"))
{
    var live = await CodexQuotaService.FetchQuotaAsync();
    Console.WriteLine($"Live Codex metadata query: {live.Status}; 5-hour available={live.FiveHourRemainingPercent.HasValue}; weekly available={live.WeeklyRemainingPercent.HasValue}");
    return;
}

int passed = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new Exception("FAIL: " + message);
    passed++;
    Console.WriteLine("PASS: " + message);
}
QuotaWindowSnapshot ParseCodex(string json)
{
    using var document = JsonDocument.Parse(json);
    return CodexQuotaService.ParseRateLimits(document.RootElement);
}
ProcessStartInfo Fake(string mode, string? pidPath = null)
{
    var info = CodexQuotaService.CreateStartInfo(Environment.ProcessPath!);
    info.ArgumentList.Clear();
    info.ArgumentList.Add("--fake-codex");
    info.ArgumentList.Add(mode);
    if (pidPath != null) info.ArgumentList.Add(pidPath);
    return info;
}
async Task Rejects(Func<Task> action, string message)
{
    try { await action(); } catch (InvalidOperationException) { Check(true, message); return; }
    throw new Exception("FAIL: " + message);
}
bool IsGone(int pid)
{
    try { using var process = Process.GetProcessById(pid); return process.HasExited; }
    catch (ArgumentException) { return true; }
}

var valid = ParseCodex("""{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":20,"resetsAt":1999999999},"secondary":{"windowDurationMins":10080,"usedPercent":40,"resetsAt":null}}}""");
Check(valid.FiveHourRemainingPercent == 80 && valid.WeeklyRemainingPercent == 60 && valid.Status == ConnectionStatus.Ready, "Codex 5-hour and weekly windows");
Check(valid.WeeklyResetsAt == null, "Codex nullable reset time");
var unknown = ParseCodex("""{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":null},"secondary":null}}""");
Check(unknown.FiveHourRemainingPercent == null && unknown.Status == ConnectionStatus.Unavailable, "Codex null usage stays unavailable");
var bucket = ParseCodex("""{"rateLimitsByLimitId":{"other":{"primary":{"windowDurationMins":300,"usedPercent":1}}},"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":1}}}""");
Check(bucket.Status == ConnectionStatus.Unavailable, "Codex never substitutes a model-specific or legacy bucket when multi-bucket view exists");
Check(ParseCodex("""{"rateLimits":{"limitId":"other","primary":{"windowDurationMins":300,"usedPercent":1}}}""").Status == ConnectionStatus.Unavailable, "Codex rejects a model-specific legacy bucket");
Check(ParseCodex("""{"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":300,"usedPercent":150}}}}""").FiveHourRemainingPercent == 0, "Codex clamps remaining allowance");
Check(AntigravityQuotaService.ParseHubPort("127.0.0.1:42100") == 42100 && AntigravityQuotaService.ParseHubPort("http://localhost:42100/") == 42100, "Antigravity accepts local port/address forms");
Check(AntigravityQuotaService.ParseHubPort("65536") == null && AntigravityQuotaService.ParseHubPort("https://remote.example:42100") == null, "Antigravity rejects invalid and remote ports");
Check(AntigravityQuotaService.CandidateEndpoints(42100)[1].StartsWith("https://127.0.0.1:42105/"), "Antigravity HTTPS fallback uses Hub + 5");
Check(AntigravityQuotaService.CandidateEndpoints(65535).Length == 1, "Antigravity avoids overflowing fallback port");
var agy = AntigravityQuotaService.ParseResponse("""{"response":{"groups":[{"displayName":"Gemini models","buckets":[{"window":"5h","remainingFraction":null},{"displayName":"Weekly quota","remainingFraction":0.42,"resetTime":null}]},{"displayName":"Argon","buckets":[{"window":"daily","remainingFraction":0.9},{"window":"weekly","remainingFraction":0.2}]}]}}""");
Check(agy.FiveHourRemainingPercent == null && agy.WeeklyRemainingPercent == 42 && agy.ArgonWeeklyRemainingPercent == 20 && agy.Status == ConnectionStatus.Ready, "Antigravity null fractions, named weekly window and Argon week");
Check(AntigravityQuotaService.ParseResponse("""{"response":{"groups":[{"displayName":"Gemini","buckets":[{"window":"5h","remainingFraction":null}]}]}}""").Status == ConnectionStatus.Unavailable, "Antigravity missing quota never becomes zero");

var previousCulture = CultureInfo.CurrentCulture;
try
{
    CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("de-DE");
    var money = DeepSeekService.ParseBalance("""{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12.34","granted_balance":"0.5","topped_up_balance":"11.84"}]}""");
    Check(money.TotalBalance == 12.34 && money.GrantedBalance == 0.5 && money.ToppedUpBalance == 11.84, "DeepSeek decimal parsing ignores Windows regional separators");
    bool malformedRejected = false;
    try { DeepSeekService.ParseBalance("""{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":null,"granted_balance":"0","topped_up_balance":"0"}]}"""); }
    catch (FormatException) { malformedRejected = true; }
    Check(malformedRejected, "DeepSeek malformed balance never becomes zero");
}
finally { CultureInfo.CurrentCulture = previousCulture; }

var response = await CodexQuotaService.QueryAsync(Fake("success"), TimeSpan.FromSeconds(5));
Check(response.FiveHourRemainingPercent == 75, "Codex handshake survives noisy stdout and full stderr pipe");
await Rejects(() => CodexQuotaService.QueryAsync(Fake("reject"), TimeSpan.FromSeconds(3)), "Codex initialize rejection ends query");
await Rejects(() => CodexQuotaService.QueryAsync(Fake("exit"), TimeSpan.FromSeconds(3)), "Codex early EOF ends query");

string temporary = Path.Combine(Path.GetTempPath(), "AIQuotaMonitor service tests " + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temporary);
try
{
    string pidFile = Path.Combine(temporary, "timeout.pid");
    var timer = Stopwatch.StartNew();
    await Rejects(() => CodexQuotaService.QueryAsync(Fake("silent", pidFile), TimeSpan.FromMilliseconds(500)), "Codex silent process respects query timeout");
    Check(timer.Elapsed < TimeSpan.FromSeconds(4) && IsGone(int.Parse(File.ReadAllText(pidFile))), "Codex timeout cleans up child process");
    using var cancelled = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
    bool cancellationObserved = false;
    try { await CodexQuotaService.QueryAsync(Fake("silent"), TimeSpan.FromSeconds(20), cancelled.Token); }
    catch (OperationCanceledException) { cancellationObserved = true; }
    Check(cancellationObserved, "Codex caller cancellation is preserved");
    string shim = Path.Combine(temporary, "中文 & codex.cmd");
    File.WriteAllText(shim, "@echo off\r\nchcp 65001 >nul\r\n\"" + Environment.ProcessPath + "\" --fake-codex success\r\n", new UTF8Encoding(false));
    var shimResult = await CodexQuotaService.QueryAsync(CodexQuotaService.CreateStartInfo(shim), TimeSpan.FromSeconds(5));
    Check(shimResult.FiveHourRemainingPercent == 75, "Codex npm cmd shim works in a path with spaces and special characters");
}
finally { Directory.Delete(temporary, true); }
Console.WriteLine($"All {passed} service checks passed.");
