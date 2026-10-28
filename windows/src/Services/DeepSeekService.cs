using System;
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
                using var doc = JsonDocument.Parse(content);
                var root = doc.RootElement;

                bool isAvailable = root.GetProperty("is_available").GetBoolean();
                var balanceInfos = root.GetProperty("balance_infos");

                if (balanceInfos.GetArrayLength() == 0)
                {
                    var empty = DeepSeekBalanceSnapshot.Placeholder;
                    empty.Status = ConnectionStatus.Unavailable;
                    empty.ErrorMessage = "未返回余额信息";
                    return new FetchResult { Snapshot = empty };
                }

                var first = balanceInfos[0];
                string currency = first.GetProperty("currency").GetString() ?? "CNY";
                double total = double.TryParse(first.GetProperty("total_balance").GetString(), out var t) ? t : 0.0;
                double granted = double.TryParse(first.GetProperty("granted_balance").GetString(), out var g) ? g : 0.0;
                double toppedUp = double.TryParse(first.GetProperty("topped_up_balance").GetString(), out var top) ? top : 0.0;

                var snapshot = new DeepSeekBalanceSnapshot
                {
                    IsAvailable = isAvailable,
                    Currency = currency,
                    TotalBalance = total,
                    GrantedBalance = granted,
                    ToppedUpBalance = toppedUp,
                    UpdatedAt = DateTime.UtcNow,
                    Status = ConnectionStatus.Ready,
                    Source = DataOrigin.OfficialAPI
                };

                return new FetchResult { Snapshot = snapshot };
            }
            catch (Exception ex)
            {
                var fail = DeepSeekBalanceSnapshot.Placeholder;
                fail.Status = ConnectionStatus.Error;
                fail.ErrorMessage = ex.Message;
                return new FetchResult { Snapshot = fail };
            }
        }
    }
}
