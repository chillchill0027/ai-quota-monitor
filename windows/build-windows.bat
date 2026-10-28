@echo off
cd /d "%~dp0"
echo 正在发布 AI 额度看板 Windows x64 单文件绿色版...

dotnet publish src\AIQuotaMonitor.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o dist\win-x64

if %ERRORLEVEL% equ 0 (
    echo.
    echo ✅ 编译成功！输出路径：dist\win-x64\AIQuotaMonitor.exe
) else (
    echo.
    echo ❌ 编译失败，请检查 .NET 8 SDK 是否已安装。
)
pause
