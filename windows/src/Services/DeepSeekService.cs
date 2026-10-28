using System;
using System.Globalization;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading.Tasks;
using AIQuotaMonitor.Models;

namespace AIQuotaMonitor.Services
{
    public static class DeepSeekService
    {
        private static readonly HttpClient HttpClient = new(new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false
        })
        {
            Timeout = TimeSpan.FromSeconds(10)
        };

        public class FetchResult
        {
            public DeepSeekBalanceSnapshot Snapshot { get; set; } = DeepSeekBalanceSnapshot.Placeholder;
            public int? RetryAfter { get; set; }
            public bool RequiresUserAction { get; set; }
        }

        public static async Task<FetchResult> FetchBalanceAsync(string apiKey)
        {
            if (string.IsNullOrWhiteSpace(apiKey))
            {
                return new FetchResult
                {
                    Snapshot = DeepSeekBalanceSnapshot.Placeholder,
                    RequiresUserAction = true
                };
            }

            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.deepseek.com/user/balance");
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey.Trim());

                using var response = await HttpClient.SendAsync(request);
                int statusCode = (int)response.StatusCode;

                if (statusCode == 401 || statusCode == 403)
                {
                    var fail = DeepSeekBalanceSnapshot.Placeholder;
                    fail.Status = ConnectionStatus.Error;
                    fail.ErrorMessage = "API Key 无效或未授权 (401/403)";
                    return new FetchResult { Snapshot = fail, RequiresUserAction = true };
                }

                if (!response.IsSuccessStatusCode)
                {
                    var fail = DeepSeekBalanceSnapshot.Placeholder;
                    fail.Status = ConnectionStatus.Error;
                    fail.ErrorMessage = $"服务响应异常 (HTTP {statusCode})";
                    return new FetchResult { Snapshot = fail };
                }

                string content = await response.Content.ReadAsStringAsync();
                return new FetchResult { Snapshot = ParseBalance(content) };
            }
            catch (Exception ex)
            {
                var fail = DeepSeekBalanceSnapshot.Placeholder;
                fail.Status = ConnectionStatus.Error;
                fail.ErrorMessage = ex.Message;
                return new FetchResult { Snapshot = fail };
            }
        }

        internal static DeepSeekBalanceSnapshot ParseBalance(string content)
        {
            using var document = JsonDocument.Parse(content);
            var root = document.RootElement;
            bool isAvailable = root.GetProperty("is_available").GetBoolean();
            var balanceInfos = root.GetProperty("balance_infos");
            if (balanceInfos.ValueKind != JsonValueKind.Array) throw new FormatException("DeepSeek 余额格式异常");
            if (balanceInfos.GetArrayLength() == 0)
            {
                var empty = DeepSeekBalanceSnapshot.Placeholder;
                empty.Status = ConnectionStatus.Unavailable;
                empty.ErrorMessage = "未返回余额信息";
                return empty;
            }
            var first = balanceInfos[0];
            string? currency = first.GetProperty("currency").GetString();
            if (string.IsNullOrWhiteSpace(currency)) throw new FormatException("DeepSeek 未返回余额币种");
            return new DeepSeekBalanceSnapshot
            {
                IsAvailable = isAvailable,
                Currency = currency,
                TotalBalance = ReadMoney(first, "total_balance"),
                GrantedBalance = ReadMoney(first, "granted_balance"),
                ToppedUpBalance = ReadMoney(first, "topped_up_balance"),
                UpdatedAt = DateTime.UtcNow,
                Status = ConnectionStatus.Ready,
                Source = DataOrigin.OfficialAPI
            };
        }

        private static double ReadMoney(JsonElement element, string name)
        {
            var value = element.GetProperty(name);
            // API decimal strings always use '.', independently of Windows regional settings.
            double parsed;
            bool valid = value.ValueKind == JsonValueKind.Number ? value.TryGetDouble(out parsed)
                : double.TryParse(value.ValueKind == JsonValueKind.String ? value.GetString() : null,
                    NumberStyles.Float, CultureInfo.InvariantCulture, out parsed);
            if (!valid || !double.IsFinite(parsed)) throw new FormatException("DeepSeek 返回了无效余额，请稍后重试");
            return parsed;
        }
    }
}
