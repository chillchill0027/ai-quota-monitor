[CmdletBinding()]
param([switch]$Rebuild)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$runtime = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$executable = Join-Path $repoRoot "dist\$runtime\AIQuotaMonitor.exe"

try {
    if ($Rebuild -or -not (Test-Path -LiteralPath $executable)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-windows.ps1') -Runtime $runtime -NoArchive
        if ($LASTEXITCODE -ne 0) { throw 'The build failed. The application was not started.' }
    }
    Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable) -WindowStyle Normal
    Write-Host 'AI Quota Monitor started. Use the notification-area icon to open the dashboard.'
    exit 0
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
