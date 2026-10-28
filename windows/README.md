# AI 额度看板 (Windows 版)

这是 **AI 额度看板** 的 Windows 原生实现，基于 **.NET 8 (WPF) + Microsoft.Web.WebView2** 构建。

集中查看 DeepSeek、小米 MiMo、OpenAI Codex、Gemini 和 Antigravity 的余额与用量。

---

## 特性与实现

1. **系统托盘与常驻后台**：
   - 启动后常驻 Windows 任务栏右下角通知区域系统托盘。
   - 左键点击托盘图标弹出磨砂亚克力（Acrylic/Mica）卡片窗口。
   - 点击外部区域自动收起，按 Escape 键可快速关闭。
2. **五大供应商全支持**：
   - **DeepSeek**：官方 REST API，API Key 使用 Windows DPAPI 加密存于本机。
   - **OpenAI · Codex**：直连本机已登录的 `codex.exe app-server` 标准输入输出 RPC。
   - **谷歌反重力 (Antigravity)**：枚举进程获取 `agy.exe --hub-port`，直连本地 Hub 与 Connect RPC 端点。
   - **小米 MiMo**：内置 Microsoft Edge WebView2 安全小窗登录与 DOM 语义现金余额读取。
   - **Gemini**：内置 WebView2 读取 5 小时与每周限额。
3. **单文件绿色版免安装**：
   - 单文件发布（Self-Contained Single File），无需额外配置运行环境，解压即用。

---

## 本地编译与构建

需要安装 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)。

双击运行 `build-windows.bat` 或在终端执行：

```powershell
dotnet publish src\AIQuotaMonitor.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist\win-x64
```

产物生成于 `dist\win-x64\AIQuotaMonitor.exe`。

---

## 自动化构建与持续集成 (CI/CD)

通过 GitHub Actions 流程 `.github/workflows/build-windows.yml`，每次推送或发布 Release 时，GitHub 官方 Windows 虚拟机将自动编译并打包生成 `AIQuotaMonitor-1.4.4-windows-x64.zip`。
