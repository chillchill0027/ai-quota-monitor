using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading.Tasks;
using AIQuotaMonitor.Models;

namespace AIQuotaMonitor.Services
{
    public class QuotaManager : INotifyPropertyChanged
    {
        private readonly string _appDataFolder;
        private readonly string _statePath;

        public DeepSeekBalanceSnapshot DeepSeek { get; set; } = DeepSeekBalanceSnapshot.Placeholder;
        public MiMoBalanceSnapshot MiMo { get; set; } = MiMoBalanceSnapshot.Placeholder;
        public QuotaWindowSnapshot ChatGPT { get; set; } = QuotaWindowSnapshot.DefaultChatGPT;
        public QuotaWindowSnapshot Gemini { get; set; } = QuotaWindowSnapshot.DefaultGemini;
        public AntigravityQuotaSnapshot Antigravity { get; set; } = AntigravityQuotaSnapshot.Placeholder;

        public HashSet<ProviderID> VisibleProviders { get; } = new(ProviderExtensions.DashboardOrder);
        public HashSet<ProviderID> RefreshingProviders { get; } = new();

        private bool _isRefreshing;
        public bool IsRefreshing
        {
            get => _isRefreshing;
            set { _isRefreshing = value; OnPropertyChanged(); }
        }

        private string _statusBanner = "就绪 · 手动刷新无普通冷却";
        public string StatusBanner
        {
            get => _statusBanner;
            set { _statusBanner = value; OnPropertyChanged(); }
        }

        private readonly AccessPolicyStore _access = new();

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

        public QuotaManager(string? stateDirectory = null)
        {
            _appDataFolder = stateDirectory ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AIQuotaMonitor");
            _statePath = Path.Combine(_appDataFolder, "state.json");
            LoadState();
        }

        public bool IsProviderVisible(ProviderID p) => VisibleProviders.Contains(p);
        public bool CanToggleProvider(ProviderID p) => !VisibleProviders.Contains(p) || VisibleProviders.Count > 1;

        public bool ToggleProviderVisibility(ProviderID p)
        {
            if (!CanToggleProvider(p)) return false;
            if (VisibleProviders.Contains(p)) VisibleProviders.Remove(p);
            else VisibleProviders.Add(p);
            SaveState();
            OnPropertyChanged(nameof(VisibleProviders));
            return true;
        }

        public async Task RefreshAllAsync(bool isManual = true)
        {
            if (IsRefreshing) return;
            IsRefreshing = true;
            StatusBanner = isManual ? "正在刷新各家额度（手动无普通冷却）…" : "自动刷新中…";

            try
            {
                var dsTask = RefreshProviderAsync(ProviderID.DeepSeek, isManual);
                var codexTask = RefreshProviderAsync(ProviderID.ChatGPT, isManual);
                var agyTask = RefreshProviderAsync(ProviderID.Antigravity, isManual);
                var mimoTask = RefreshProviderAsync(ProviderID.MiMo, isManual);
                var geminiTask = RefreshProviderAsync(ProviderID.Gemini, isManual);

                await Task.WhenAll(dsTask, codexTask, agyTask, mimoTask, geminiTask);

                StatusBanner = "刷新完成 · 失败原因可悬停查看 · " + DateTime.Now.ToString("HH:mm:ss");
                SaveState();
            }
            finally
            {
                IsRefreshing = false;
                OnPropertyChanged("");
            }
        }

        public async Task RefreshSingleAsync(ProviderID provider)
        {
            if (IsRefreshing) return;
            IsRefreshing = true;
            StatusBanner = $"正在刷新 {provider.GetShortName()}…";
            try
            {
                await RefreshProviderAsync(provider, true);
                StatusBanner = $"{provider.GetShortName()} 刷新完成 · {DateTime.Now:HH:mm:ss}";
                SaveState();
            }
            finally
            {
                IsRefreshing = false;
                OnPropertyChanged("");
            }
        }

        private async Task RefreshProviderAsync(ProviderID provider, bool isManual)
        {
            RefreshingProviders.Add(provider);
            OnPropertyChanged(nameof(RefreshingProviders));
            try
            {
                switch (provider)
                {
                    case ProviderID.DeepSeek: await RefreshDeepSeekAsync(isManual); break;
                    case ProviderID.MiMo: await RefreshMiMoAsync(isManual); break;
                    case ProviderID.ChatGPT: await RefreshCodexAsync(isManual); break;
                    case ProviderID.Gemini: await RefreshGeminiAsync(isManual); break;
                    case ProviderID.Antigravity: await RefreshAntigravityAsync(isManual); break;
                }
            }
            catch (Exception ex)
            {
                // One provider failing must not interrupt the other providers or lose cache.
                switch (provider)
                {
                    case ProviderID.DeepSeek: DeepSeek.Status = ConnectionStatus.Error; DeepSeek.ErrorMessage = ex.Message; break;
                    case ProviderID.MiMo: MiMo.Status = ConnectionStatus.Error; MiMo.Note = ex.Message; break;
                    case ProviderID.ChatGPT: ChatGPT.Status = ConnectionStatus.Error; ChatGPT.Note = ex.Message; break;
                    case ProviderID.Gemini: Gemini.Status = ConnectionStatus.Error; Gemini.Note = ex.Message; break;
                    case ProviderID.Antigravity: Antigravity.Status = ConnectionStatus.Error; Antigravity.Note = ex.Message; break;
                }
            }
            finally
            {
                RefreshingProviders.Remove(provider);
                OnPropertyChanged(nameof(RefreshingProviders));
            }
        }

        private async Task RefreshDeepSeekAsync(bool isManual)
        {
            string key = CredentialStorage.ReadDeepSeekKey();
            if (string.IsNullOrWhiteSpace(key))
            {
                DeepSeek.Status = ConnectionStatus.NeedsSetup;
                DeepSeek.ErrorMessage = "点击供应商名称，在菜单选择「配置 API Key」填写密钥。";
                return;
            }
            if (_access.Begin("deepseek", isManual) != null) return;

            var result = await DeepSeekService.FetchBalanceAsync(key);
            if (result.Snapshot.Status == ConnectionStatus.Ready)
            {
                DeepSeek = result.Snapshot;
                _access.Succeeded("deepseek");
            }
            else
            {
                DeepSeek.Status = result.Snapshot.Status;
                DeepSeek.ErrorMessage = result.Snapshot.ErrorMessage;
                _access.Failed("deepseek");
            }
        }

        private async Task RefreshCodexAsync(bool isManual)
        {
            if (_access.Begin("codex", isManual) != null) return;
            try
            {
                var result = await CodexQuotaService.FetchQuotaAsync();
                if (result.Status == ConnectionStatus.Ready)
                {
                    ChatGPT = result;
                    _access.Succeeded("codex");
                }
                else
                {
                    ChatGPT.Status = result.Status;
                    ChatGPT.Note = result.Note;
                    _access.Failed("codex");
                }
            }
            catch (Exception ex)
            {
                ChatGPT.Status = ConnectionStatus.Error;
                ChatGPT.Note = ex.Message;
                _access.Failed("codex");
            }
        }

        private async Task RefreshAntigravityAsync(bool isManual)
        {
            if (_access.Begin("antigravity", isManual) != null) return;
            try
            {
                var result = await AntigravityQuotaService.FetchQuotaAsync();
                if (result.Status == ConnectionStatus.Ready)
                {
                    Antigravity = result;
                    _access.Succeeded("antigravity");
                }
                else
                {
                    Antigravity.Status = result.Status;
                    Antigravity.Note = result.Note;
                    _access.Failed("antigravity");
                }
            }
            catch (Exception ex)
            {
                Antigravity.Status = ConnectionStatus.Error;
                Antigravity.Note = ex.Message;
                _access.Failed("antigravity");
            }
        }

        private async Task RefreshMiMoAsync(bool isManual)
        {
            if (_access.Begin("mimo", isManual) != null) return;
            string? text = await WebPageSessionManager.ReadPageTextHeadlessAsync(ProviderID.MiMo);
            if (text != null)
            {
                var money = WebQuotaParser.ParseMiMoBalance(text);
                if (money != null)
                {
                    MiMo.PreviousBalance = MiMo.UpdatedAt != DateTime.MinValue ? MiMo.CashBalance : null;
                    MiMo.CashBalance = money.Amount;
                    MiMo.CurrencyCode = money.Currency;
                    MiMo.CurrencySymbol = money.CurrencySymbol;
                    MiMo.Status = ConnectionStatus.Ready;
                    MiMo.Source = DataOrigin.Webpage;
                    MiMo.UpdatedAt = DateTime.UtcNow;
                    MiMo.Note = "已读取官方页面中的现金余额。";
                    _access.Succeeded("mimo");
                    return;
                }
            }
            MiMo.Status = MiMo.UpdatedAt == DateTime.MinValue ? ConnectionStatus.NeedsSetup : ConnectionStatus.Error;
            MiMo.Note = "未读到明确现金余额。请在供应商菜单选择「打开用量小窗」完成登录，确认页面显示现金余额后再刷新。";
            _access.Failed("mimo");
        }

        private async Task RefreshGeminiAsync(bool isManual)
        {
            if (_access.Begin("gemini", isManual) != null) return;
            string? text = await WebPageSessionManager.ReadPageTextHeadlessAsync(ProviderID.Gemini);
            if (text != null)
            {
                var quota = WebQuotaParser.ParseGemini(text);
                if (quota.FiveHour != null || quota.Weekly != null)
                {
                    Gemini.FiveHourRemainingPercent = quota.FiveHour?.RemainingPercent;
                    Gemini.WeeklyRemainingPercent = quota.Weekly?.RemainingPercent;
                    Gemini.FiveHourResetText = quota.FiveHour?.ResetText;
                    Gemini.WeeklyResetText = quota.Weekly?.ResetText;
                    Gemini.Status = ConnectionStatus.Ready;
                    Gemini.Source = DataOrigin.Webpage;
                    Gemini.UpdatedAt = DateTime.UtcNow;
                    Gemini.Note = "已读取官方用量页。";
                    _access.Succeeded("gemini");
                    return;
                }
            }
            Gemini.Status = Gemini.UpdatedAt == DateTime.MinValue ? ConnectionStatus.NeedsSetup : ConnectionStatus.Error;
            Gemini.Note = "未读到页面明确显示的配额。请在供应商菜单选择「打开用量小窗」登录；若平台限制内嵌登录，请在浏览器查看官方用量页。";
            _access.Failed("gemini");
        }

        public void ResumeProvider(ProviderID provider)
        {
            string key = provider == ProviderID.ChatGPT ? "codex" : provider.ToString().ToLowerInvariant();
            _access.ClearSuspension(key);
            StatusBanner = "已解除本地认证暂停；需要时点击刷新，服务端等待时间继续有效。";
        }

        public bool TryApplyManualCalibration(ProviderID provider, double? first, double? weekly, double? argon,
            string currency, out string error)
        {
            error = "";
            if (IsRefreshing) { error = "正在刷新，请刷新完成后再校准。"; return false; }
            if (provider == ProviderID.MiMo)
            {
                if (!first.HasValue || !double.IsFinite(first.Value) || currency is not ("CNY" or "USD"))
                { error = "请输入有效现金余额和币种；余额可以为负数。"; return false; }
                MiMo.PreviousBalance = MiMo.UpdatedAt != DateTime.MinValue ? MiMo.CashBalance : null;
                MiMo.CashBalance = first.Value;
                MiMo.CurrencyCode = currency;
                MiMo.CurrencySymbol = currency == "USD" ? "$" : "¥";
                MiMo.UpdatedAt = DateTime.UtcNow;
                MiMo.Status = ConnectionStatus.ManualCalibrated;
                MiMo.Source = DataOrigin.Manual;
                MiMo.Note = "手动校准的现金余额；下次成功读取官方页面后更新。";
            }
            else if (provider is ProviderID.Gemini or ProviderID.Antigravity)
            {
                bool Invalid(double? value) => value.HasValue && (!double.IsFinite(value.Value) || value < 0 || value > 100);
                if (Invalid(first) || Invalid(weekly) || Invalid(argon))
                { error = "请输入 0–100 的剩余百分比；未知可留空。"; return false; }
                if (provider == ProviderID.Gemini)
                {
                    Gemini.FiveHourRemainingPercent = first;
                    Gemini.WeeklyRemainingPercent = weekly;
                    Gemini.FiveHourResetsAt = Gemini.WeeklyResetsAt = null;
                    Gemini.FiveHourResetText = Gemini.WeeklyResetText = "手动校准，重置时间以官方页面为准";
                    Gemini.Status = ConnectionStatus.ManualCalibrated;
                    Gemini.Source = DataOrigin.Manual;
                    Gemini.UpdatedAt = DateTime.UtcNow;
                    Gemini.Note = "手动校准的剩余额度；下次成功读取官方页面后更新。";
                }
                else
                {
                    Antigravity.FiveHourRemainingPercent = first;
                    Antigravity.WeeklyRemainingPercent = weekly;
                    Antigravity.ArgonWeeklyRemainingPercent = argon;
                    Antigravity.FiveHourResetsAt = Antigravity.WeeklyResetsAt = Antigravity.ArgonWeeklyResetsAt = null;
                    Antigravity.FiveHourResetText = Antigravity.WeeklyResetText = Antigravity.ArgonWeeklyResetText = "手动校准，重置时间以官方页面为准";
                    Antigravity.Status = ConnectionStatus.ManualCalibrated;
                    Antigravity.Source = DataOrigin.Manual;
                    Antigravity.UpdatedAt = DateTime.UtcNow;
                    Antigravity.Note = "手动校准的剩余额度；下次成功读取本地服务后更新。";
                }
            }
            else { error = "此供应商不支持手动校准。"; return false; }
            SaveState();
            OnPropertyChanged("");
            return true;
        }

        public void SaveState()
        {
            try
            {
                Directory.CreateDirectory(_appDataFolder);
                var data = new
                {
                    DeepSeek,
                    MiMo,
                    ChatGPT,
                    Gemini,
                    Antigravity,
                    Visible = VisibleProviders.Select(p => p.ToString()).ToList()
                };
                string temporaryPath = _statePath + ".tmp";
                File.WriteAllText(temporaryPath, JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
                File.Move(temporaryPath, _statePath, overwrite: true);
            }
            catch { }
        }

        public void LoadState()
        {
            try
            {
                if (!File.Exists(_statePath)) return;
                string json = File.ReadAllText(_statePath);
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;
                if (root.TryGetProperty("DeepSeek", out var ds)) DeepSeek = JsonSerializer.Deserialize<DeepSeekBalanceSnapshot>(ds.GetRawText()) ?? DeepSeek;
                if (root.TryGetProperty("MiMo", out var mi)) MiMo = JsonSerializer.Deserialize<MiMoBalanceSnapshot>(mi.GetRawText()) ?? MiMo;
                if (root.TryGetProperty("ChatGPT", out var c)) ChatGPT = JsonSerializer.Deserialize<QuotaWindowSnapshot>(c.GetRawText()) ?? ChatGPT;
                if (root.TryGetProperty("Gemini", out var g)) Gemini = JsonSerializer.Deserialize<QuotaWindowSnapshot>(g.GetRawText()) ?? Gemini;
                if (root.TryGetProperty("Antigravity", out var a)) Antigravity = JsonSerializer.Deserialize<AntigravityQuotaSnapshot>(a.GetRawText()) ?? Antigravity;

                if (root.TryGetProperty("Visible", out var visible) && visible.ValueKind == JsonValueKind.Array)
                {
                    var providers = visible.EnumerateArray()
                        .Where(item => item.ValueKind == JsonValueKind.String)
                        .Select(item => Enum.TryParse<ProviderID>(item.GetString(), out var value) && Enum.IsDefined(value)
                            ? (ProviderID?)value : null)
                        .Where(value => value.HasValue).Select(value => value!.Value).ToHashSet();
                    if (providers.Count > 0)
                    {
                        VisibleProviders.Clear();
                        VisibleProviders.UnionWith(providers);
                    }
                }
                if (DeepSeek.Status == ConnectionStatus.Ready) DeepSeek.Status = ConnectionStatus.Cached;
                if (MiMo.Status == ConnectionStatus.Ready) MiMo.Status = ConnectionStatus.Cached;
                if (ChatGPT.Status == ConnectionStatus.Ready) ChatGPT.Status = ConnectionStatus.Cached;
                if (Gemini.Status == ConnectionStatus.Ready) Gemini.Status = ConnectionStatus.Cached;
                if (Antigravity.Status == ConnectionStatus.Ready) Antigravity.Status = ConnectionStatus.Cached;
            }
            catch { }
        }
    }
}
