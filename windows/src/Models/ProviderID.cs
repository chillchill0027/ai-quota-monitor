using System;
using System.Collections.Generic;

namespace AIQuotaMonitor.Models
{
    public enum ProviderID
    {
        DeepSeek,
        MiMo,
        ChatGPT,
        Gemini,
        Antigravity
    }

    public static class ProviderExtensions
    {
        public static readonly IReadOnlyList<ProviderID> DashboardOrder = new[]
        {
            ProviderID.DeepSeek,
            ProviderID.MiMo,
            ProviderID.ChatGPT,
            ProviderID.Gemini,
            ProviderID.Antigravity
        };

        public static string GetShortName(this ProviderID provider) => provider switch
        {
            ProviderID.DeepSeek => "DeepSeek",
            ProviderID.MiMo => "小米 MiMo",
            ProviderID.ChatGPT => "OpenAI · Codex",
            ProviderID.Gemini => "Gemini",
            ProviderID.Antigravity => "Antigravity",
            _ => provider.ToString()
        };

        public static string GetDisplayName(this ProviderID provider) => provider switch
        {
            ProviderID.DeepSeek => "DeepSeek API",
            ProviderID.MiMo => "小米 MiMo (按量)",
            ProviderID.ChatGPT => "Codex（ChatGPT 订阅）",
            ProviderID.Gemini => "Google AI Pro (Gemini)",
            ProviderID.Antigravity => "谷歌反重力 (Antigravity)",
            _ => provider.ToString()
        };

        public static string GetConsoleUrl(this ProviderID provider) => provider switch
        {
            ProviderID.DeepSeek => "https://platform.deepseek.com/usage",
            ProviderID.MiMo => "https://platform.xiaomimimo.com/#/console/balance",
            ProviderID.ChatGPT => "https://chatgpt.com/codex/settings/usage",
            ProviderID.Gemini => "https://gemini.google.com/usage",
            ProviderID.Antigravity => "http://127.0.0.1:62433",
            _ => "https://google.com"
        };

        public static string GetIconResourcePath(this ProviderID provider) => provider switch
        {
            ProviderID.DeepSeek => "pack://application:,,,/Resources/ProviderIcons/deepseek.png",
            ProviderID.MiMo => "pack://application:,,,/Resources/ProviderIcons/mimo.png",
            ProviderID.ChatGPT => "pack://application:,,,/Resources/ProviderIcons/openai.png",
            ProviderID.Gemini => "pack://application:,,,/Resources/ProviderIcons/gemini.png",
            ProviderID.Antigravity => "pack://application:,,,/Resources/ProviderIcons/antigravity.png",
            _ => ""
        };
    }
}
