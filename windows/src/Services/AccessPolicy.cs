using System;
using System.Collections.Generic;

namespace AIQuotaMonitor.Services
{
    public class AccessPolicyStore
    {
        private static readonly TimeSpan DefaultCooldown = TimeSpan.FromSeconds(300);
        private readonly Dictionary<string, DateTime> _lastAccess = new();
        private readonly Dictionary<string, string> _suspensions = new();

        public string? Begin(string action, bool isManual = false)
        {
            if (_suspensions.TryGetValue(action, out string? reason))
            {
                return $"已暂停：{reason}";
            }

            if (isManual)
            {
                return null;
            }

            if (_lastAccess.TryGetValue(action, out var lastTime))
            {
                var elapsed = DateTime.UtcNow - lastTime;
                if (elapsed < DefaultCooldown)
                {
                    int remain = (int)Math.Ceiling((DefaultCooldown - elapsed).TotalSeconds);
                    return $"冷却中（剩余 {remain}s）";
                }
            }

            _lastAccess[action] = DateTime.UtcNow;
            return null;
        }

        public void Succeeded(string action)
        {
            _lastAccess[action] = DateTime.UtcNow;
        }

        public void Failed(string action, string? suspendReason = null)
        {
            _lastAccess[action] = DateTime.UtcNow;
            if (!string.IsNullOrEmpty(suspendReason))
            {
                _suspensions[action] = suspendReason;
            }
        }

        public void ClearSuspension(string action)
        {
            _suspensions.Remove(action);
        }
    }
}
