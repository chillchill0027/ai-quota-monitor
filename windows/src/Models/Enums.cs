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
}
