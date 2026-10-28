[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64',
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [string]$OutputDirectory,
    [switch]$NoRestore,
    [switch]$NoArchive
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $PSScriptRoot 'src\AIQuotaMonitor.csproj'
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot "dist\$Runtime"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

try {
    $dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    $dotnetPath = if ($dotnetCommand) { $dotnetCommand.Source } else { $null }
    if (-not $dotnetPath) {
        $fallback = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
        if (Test-Path -LiteralPath $fallback) {
            $dotnetPath = $fallback
        }
    }
    if (-not $dotnetPath) {
        throw 'Building from source requires the .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0'
    }

    $sdkList = & $dotnetPath --list-sdks
    if ($LASTEXITCODE -ne 0 -or -not ($sdkList | Where-Object { $_ -match '^([89]|[1-9][0-9])\.' })) {
        throw 'No compatible .NET SDK was found. Install the .NET 8 SDK, then retry.'
    }

    Write-Host "Publishing AI Quota Monitor ($Runtime) to $OutputDirectory"
    $publishArgs = @(
        'publish', $projectPath, '-c', $Configuration, '-r', $Runtime,
        '--self-contained', 'true', '-p:PublishSingleFile=true',
        '-p:IncludeNativeLibrariesForSelfExtract=true', '-p:DebugType=None',
        '-p:DebugSymbols=false', '-o', $OutputDirectory
    )
    if ($NoRestore) { $publishArgs += '--no-restore' }
    & $dotnetPath @publishArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'Publish failed. Check the build output above. First build needs access to NuGet; close the running app before replacing its executable.'
    }

    $executable = Join-Path $OutputDirectory 'AIQuotaMonitor.exe'
    if (-not (Test-Path -LiteralPath $executable)) {
        throw "Publish completed without the expected executable: $executable"
    }

    if (-not $NoArchive) {
        [xml]$project = Get-Content -LiteralPath $projectPath -Raw
        $version = $project.SelectSingleNode('/Project/PropertyGroup/Version').InnerText
        $architecture = $Runtime.Substring(4)
        $archiveName = "AIQuotaMonitor-$version-windows-$architecture.zip"
        $archivePath = Join-Path (Split-Path -Parent $OutputDirectory) $archiveName
        $publishFiles = @(Get-ChildItem -LiteralPath $OutputDirectory | Select-Object -ExpandProperty FullName)
        Compress-Archive -LiteralPath $publishFiles -DestinationPath $archivePath -Force
        $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText("$archivePath.sha256", "$hash  $archiveName`n", [Text.UTF8Encoding]::new($false))
        Write-Host "Archive: $archivePath"
        Write-Host "SHA256:  $hash"
    }

    Write-Host "Ready: $executable"
    exit 0
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
