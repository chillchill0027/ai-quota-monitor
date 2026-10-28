using System;
using System.Text.RegularExpressions;
using AIQuotaMonitor.Models;

namespace AIQuotaMonitor.Services
{
    public static class WebQuotaParser
    {
        public record Money(double Amount, string Currency, string CurrencySymbol);
        public record QuotaWindow(double RemainingPercent, string? ResetText);
        public record GeminiQuota(QuotaWindow? FiveHour, QuotaWindow? Weekly);

        public static Money? ParseMiMoBalance(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;

            // Look for Cash Balance / 现金余额 / 账户现金余额 followed by amount
            var match = Regex.Match(text, @"(?:Cash Balance|现金余额|账户现金余额)[^\r\n0-9−\-\$¥￥]*([\$¥￥])?\s*([−\-]?[0-9,]+(?:\.[0-9]+)?)", RegexOptions.IgnoreCase);
            if (!match.Success) return null;

            string symbol = match.Groups[1].Value;
            string numStr = match.Groups[2].Value.Replace(",", "").Replace("−", "-");

            if (!double.TryParse(numStr, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out double amount))
            {
                return null;
            }

            string currency = (symbol == "$" || text.Contains("(USD)", StringComparison.OrdinalIgnoreCase)) ? "USD" : "CNY";
            string currencySymbol = currency == "USD" ? "$" : "¥";

            return new Money(amount, currency, currencySymbol);
        }

        public static GeminiQuota ParseGemini(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return new GeminiQuota(null, null);

            QuotaWindow? fiveHour = null;
            QuotaWindow? weekly = null;

            // 5-hour pattern
            var m5 = Regex.Match(text, @"(?:5-hour limit|5小时窗口|5 hours)[\s\S]*?(?:(\d+)%\s*used|Remaining:?\s*(\d+)%|(\d+)%\s*剩余)", RegexOptions.IgnoreCase);
            if (m5.Success)
            {
                if (int.TryParse(m5.Groups[1].Value, out int used))
                {
                    fiveHour = new QuotaWindow(Math.Clamp(100 - used, 0, 100), null);
                }
                else if (int.TryParse(m5.Groups[2].Value, out int rem1))
                {
                    fiveHour = new QuotaWindow(Math.Clamp(rem1, 0, 100), null);
                }
                else if (int.TryParse(m5.Groups[3].Value, out int rem2))
                {
                    fiveHour = new QuotaWindow(Math.Clamp(rem2, 0, 100), null);
                }
            }

            // Weekly pattern
            var mw = Regex.Match(text, @"(?:Weekly limit|周配额窗口|Weekly|7 天窗口)[\s\S]*?(?:(\d+)%\s*used|Remaining:?\s*(\d+)%|(\d+)%\s*剩余)", RegexOptions.IgnoreCase);
            if (mw.Success)
            {
                if (int.TryParse(mw.Groups[1].Value, out int used))
                {
                    weekly = new QuotaWindow(Math.Clamp(100 - used, 0, 100), null);
                }
                else if (int.TryParse(mw.Groups[2].Value, out int rem1))
                {
                    weekly = new QuotaWindow(Math.Clamp(rem1, 0, 100), null);
                }
                else if (int.TryParse(mw.Groups[3].Value, out int rem2))
                {
                    weekly = new QuotaWindow(Math.Clamp(rem2, 0, 100), null);
                }
            }

            return new GeminiQuota(fiveHour, weekly);
        }
    }
}
