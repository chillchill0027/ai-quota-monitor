using System;

namespace AIQuotaMonitor.Models
{
    public enum ConnectionStatus
    {
        Ready,
        Unavailable,
        Cached,
        Loading,
        NeedsSetup,
        ManualCalibrated,
        Error
    }

    public enum DataOrigin
    {
        OfficialAPI,
        Webpage,
        Manual
    }

    public enum MenuBarDisplayStyle
    {
        IconOnly,
        CompactBalances,
        AllFour,
        AllFive
    }
}
