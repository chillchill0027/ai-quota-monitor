using System;

namespace AIQuotaMonitor.Models
{
    public class DeepSeekBalanceSnapshot
    {
        public bool IsAvailable { get; set; } = true;
        public string Currency { get; set; } = "CNY";
        public double TotalBalance { get; set; } = 0.0;
        public double GrantedBalance { get; set; } = 0.0;
        public double ToppedUpBalance { get; set; } = 0.0;
        public DateTime UpdatedAt { get; set; } = DateTime.MinValue;
        public ConnectionStatus Status { get; set; } = ConnectionStatus.NeedsSetup;
        public DataOrigin? Source { get; set; }
        public string? ErrorMessage { get; set; }

        public string CurrencySymbol => Currency.Equals("USD", StringComparison.OrdinalIgnoreCase) ? "$" : "¥";

        public static DeepSeekBalanceSnapshot Placeholder => new()
        {
            IsAvailable = true,
            Currency = "CNY",
            TotalBalance = 0.0,
            UpdatedAt = DateTime.MinValue,
            Status = ConnectionStatus.NeedsSetup
        };
    }

    public class MiMoBalanceSnapshot
    {
        public double CashBalance { get; set; } = 0.0;
        public double? PreviousBalance { get; set; }
        public string CurrencySymbol { get; set; } = "¥";
        public string? CurrencyCode { get; set; } = "CNY";
        public DateTime UpdatedAt { get; set; } = DateTime.MinValue;
        public ConnectionStatus Status { get; set; } = ConnectionStatus.NeedsSetup;
        public DataOrigin? Source { get; set; }
        public string? Note { get; set; } = "打开官方余额页；可手动录入或点击小窗读取明确现金余额";

        public double? DeltaFromPrevious => (PreviousBalance != null && PreviousBalance != CashBalance)
            ? CashBalance - PreviousBalance
            : null;

        public static MiMoBalanceSnapshot Placeholder => new()
        {
            CashBalance = 0.0,
            CurrencySymbol = "¥",
            CurrencyCode = "CNY",
            UpdatedAt = DateTime.MinValue,
            Status = ConnectionStatus.NeedsSetup
        };
    }

    public class QuotaWindowSnapshot
    {
        public double? FiveHourRemainingPercent { get; set; }
        public string? FiveHourResetText { get; set; }
        public double? WeeklyRemainingPercent { get; set; }
        public string? WeeklyResetText { get; set; }
        public DateTime? FiveHourResetsAt { get; set; }
        public DateTime? WeeklyResetsAt { get; set; }
        public string PlanLabel { get; set; } = "";
        public DateTime UpdatedAt { get; set; } = DateTime.MinValue;
        public ConnectionStatus Status { get; set; } = ConnectionStatus.NeedsSetup;
        public DataOrigin? Source { get; set; }
        public string? Note { get; set; }

        public double? CodexRemaining(bool weekly, DateTime? now = null)
        {
            var checkNow = now ?? DateTime.UtcNow;
            var reset = weekly ? WeeklyResetsAt : FiveHourResetsAt;
            if (reset != null && reset <= checkNow) return null;
            return weekly ? WeeklyRemainingPercent : FiveHourRemainingPercent;
        }

        public static QuotaWindowSnapshot DefaultGemini => new()
        {
            PlanLabel = "Google AI Pro",
            UpdatedAt = DateTime.MinValue,
            Status = ConnectionStatus.NeedsSetup,
            Note = "打开官方用量页；小窗读取或点开状态栏时同步已显示的配额"
        };

        public static QuotaWindowSnapshot DefaultChatGPT => new()
        {
            PlanLabel = "Codex（ChatGPT 订阅）",
            UpdatedAt = DateTime.MinValue,
            Status = ConnectionStatus.NeedsSetup,
            Note = "点开状态栏或点击查询，通过已登录的 Codex CLI 获取官方额度"
        };
    }

    public class AntigravityQuotaSnapshot
    {
        public double? FiveHourRemainingPercent { get; set; }
        public string? FiveHourResetText { get; set; }
        public DateTime? FiveHourResetsAt { get; set; }

        public double? WeeklyRemainingPercent { get; set; }
        public string? WeeklyResetText { get; set; }
        public DateTime? WeeklyResetsAt { get; set; }

        public double? ArgonWeeklyRemainingPercent { get; set; }
        public string? ArgonWeeklyResetText { get; set; }
        public DateTime? ArgonWeeklyResetsAt { get; set; }

        public double? ThirdPartyWeeklyRemainingPercent { get; set; }
        public string? ThirdPartyWeeklyResetText { get; set; }

        public DateTime UpdatedAt { get; set; } = DateTime.MinValue;
        public ConnectionStatus Status { get; set; } = ConnectionStatus.NeedsSetup;
        public DataOrigin? Source { get; set; } = DataOrigin.OfficialAPI;
        public string? Note { get; set; } = "点击「查询」读取本机 Antigravity 官方 Language Server 限额";

        public static AntigravityQuotaSnapshot Placeholder => new()
        {
            UpdatedAt = DateTime.MinValue,
            Status = ConnectionStatus.NeedsSetup
        };
    }
}
