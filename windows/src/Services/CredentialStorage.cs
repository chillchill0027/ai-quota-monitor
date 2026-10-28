using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace AIQuotaMonitor.Services
{
    public static class CredentialStorage
    {
        private static readonly string AppDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AIQuotaMonitor");

        private static readonly string KeyFilePath = Path.Combine(AppDataFolder, "deepseek.dat");
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("AIQuotaMonitor.Entropy.v1");

        public static bool SaveDeepSeekKey(string apiKey)
        {
            try
            {
                if (!Directory.Exists(AppDataFolder))
                {
                    Directory.CreateDirectory(AppDataFolder);
                }

                if (string.IsNullOrWhiteSpace(apiKey))
                {
                    if (File.Exists(KeyFilePath)) File.Delete(KeyFilePath);
                    return true;
                }

                byte[] plainBytes = Encoding.UTF8.GetBytes(apiKey);
                byte[] encrypted = ProtectedData.Protect(plainBytes, Entropy, DataProtectionScope.CurrentUser);
                File.WriteAllBytes(KeyFilePath, encrypted);
                return true;
            }
            catch
            {
                return false;
            }
        }

        public static string ReadDeepSeekKey()
        {
            try
            {
                if (!File.Exists(KeyFilePath)) return string.Empty;
                byte[] encrypted = File.ReadAllBytes(KeyFilePath);
                byte[] plainBytes = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(plainBytes);
            }
            catch
            {
                return string.Empty;
            }
        }
    }
}
