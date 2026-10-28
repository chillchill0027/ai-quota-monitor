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
        private static readonly string AppDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AIQuotaMonitor");
        private static readonly string StatePath = Path.Combine(AppDataFolder, "state.json");

        public DeepSeekBalanceSnapshot DeepSeek { get; set; } = DeepSeekBalanceSnapshot.Placeholder;
        public MiMoBalanceSnapshot MiMo { get; set; } = MiMoBalanceSnapshot.Placeholder;
        public QuotaWindowSnapshot ChatGPT { get; set; } = QuotaWindowSnapshot.DefaultChatGPT;
        public QuotaWindowSnapshot Gemini { get; set; } = QuotaWindowSnapshot.DefaultGemini;
        public AntigravityQuotaSnapshot Antigravity { get; set; } = AntigravityQuotaSnapshot.Placeholder;

        public HashSet<ProviderID> VisibleProviders { get; } = new(ProviderExtensions.DashboardOrder);
        public MenuBarDisplayStyle MenuBarStyle { get; set; } = MenuBarDisplayStyle.CompactBalances;

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

        public QuotaManager()
        {
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
                var dsTask = RefreshDeepSeekAsync(isManual);
                var codexTask = RefreshCodexAsync(isManual);
                var agyTask = RefreshAntigravityAsync(isManual);
                var mimoTask = RefreshMiMoAsync(isManual);
                var geminiTask = RefreshGeminiAsync(isManual);

                await Task.WhenAll(dsTask, codexTask, agyTask, mimoTask, geminiTask);

                StatusBanner = "刷新完成 · " + DateTime.Now.ToString("HH:mm:ss");
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
            try
            {
                switch (provider)
                {
                    case ProviderID.DeepSeek: await RefreshDeepSeekAsync(true); break;
                    case ProviderID.MiMo: await RefreshMiMoAsync(true); break;
                    case ProviderID.ChatGPT: await RefreshCodexAsync(true); break;
                    case ProviderID.Gemini: await RefreshGeminiAsync(true); break;
                    case ProviderID.Antigravity: await RefreshAntigravityAsync(true); break;
                }
                SaveState();
            }
            finally
            {
                IsRefreshing = false;
                OnPropertyChanged("");
            }
        }

        private async Task RefreshDeepSeekAsync(bool isManual)
        {
            string key = CredentialStorage.ReadDeepSeekKey();
            if (string.IsNullOrWhiteSpace(key)) return;
            if (_access.Begin("deepseek", isManual) != null) return;

            var result = await DeepSeekService.FetchBalanceAsync(key);
            DeepSeek = result.Snapshot;
            if (result.Snapshot.Status == ConnectionStatus.Ready) _access.Succeeded("deepseek");
            else _access.Failed("deepseek");
        }

        private async Task RefreshCodexAsync(bool isManual)
        {
            if (_access.Begin("codex", isManual) != null) return;
            try
            {
                ChatGPT = await CodexQuotaService.FetchQuotaAsync();
                _access.Succeeded("codex");
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
                Antigravity = await AntigravityQuotaService.FetchQuotaAsync();
                if (Antigravity.Status == ConnectionStatus.Ready) _access.Succeeded("antigravity");
                else _access.Failed("antigravity");
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
                    MiMo.CashBalance = money.Amount;
                    MiMo.CurrencyCode = money.Currency;
                    MiMo.CurrencySymbol = money.CurrencySymbol;
                    MiMo.Status = ConnectionStatus.Ready;
                    MiMo.Source = DataOrigin.Webpage;
                    MiMo.UpdatedAt = DateTime.UtcNow;
                    _access.Succeeded("mimo");
                    return;
                }
            }
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
                    Gemini.Status = ConnectionStatus.Ready;
                    Gemini.Source = DataOrigin.Webpage;
                    Gemini.UpdatedAt = DateTime.UtcNow;
                    _access.Succeeded("gemini");
                    return;
                }
            }
            _access.Failed("gemini");
        }

        public string GetTrayTooltip()
        {
            string ds = DeepSeek.UpdatedAt != DateTime.MinValue ? $"{DeepSeek.CurrencySymbol}{DeepSeek.TotalBalance:F1}" : "--";
            string mi = MiMo.UpdatedAt != DateTime.MinValue ? $"{MiMo.CurrencySymbol}{MiMo.CashBalance:F1}" : "--";
            string gem = Gemini.FiveHourRemainingPercent != null ? $"{Gemini.FiveHourRemainingPercent:F0}%" : "--";
            string codex = ChatGPT.FiveHourRemainingPercent != null ? $"{ChatGPT.FiveHourRemainingPercent:F0}%" : "--";
            string agy = Antigravity.FiveHourRemainingPercent != null ? $"{Antigravity.FiveHourRemainingPercent:F0}%" : "--";

            return $"AI 额度看板\nDeepSeek: {ds} | MiMo: {mi}\nCodex: {codex} | Gemini: {gem} | 反重力: {agy}";
        }

        public void SaveState()
        {
            try
            {
                if (!Directory.Exists(AppDataFolder)) Directory.CreateDirectory(AppDataFolder);
                var data = new
                {
                    DeepSeek,
                    MiMo,
                    ChatGPT,
                    Gemini,
                    Antigravity,
                    Visible = VisibleProviders.Select(p => p.ToString()).ToList(),
                    MenuBarStyle = MenuBarStyle.ToString()
                };
                File.WriteAllText(StatePath, JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }

        public void LoadState()
        {
            try
            {
                if (!File.Exists(StatePath)) return;
                string json = File.ReadAllText(StatePath);
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;
                if (root.TryGetProperty("DeepSeek", out var ds)) DeepSeek = JsonSerializer.Deserialize<DeepSeekBalanceSnapshot>(ds.GetRawText()) ?? DeepSeek;
                if (root.TryGetProperty("MiMo", out var mi)) MiMo = JsonSerializer.Deserialize<MiMoBalanceSnapshot>(mi.GetRawText()) ?? MiMo;
                if (root.TryGetProperty("ChatGPT", out var c)) ChatGPT = JsonSerializer.Deserialize<QuotaWindowSnapshot>(c.GetRawText()) ?? ChatGPT;
                if (root.TryGetProperty("Gemini", out var g)) Gemini = JsonSerializer.Deserialize<QuotaWindowSnapshot>(g.GetRawText()) ?? Gemini;
                if (root.TryGetProperty("Antigravity", out var a)) Antigravity = JsonSerializer.Deserialize<AntigravityQuotaSnapshot>(a.GetRawText()) ?? Antigravity;

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
