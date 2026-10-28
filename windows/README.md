# AI 额度看板 · Windows

Windows 原生客户端使用 .NET 8 WPF、系统通知区域图标和 Microsoft Edge WebView2。集中查看 DeepSeek、小米 MiMo、OpenAI Codex、Gemini 和 Antigravity 的余额或额度。

## 外观

看板沿用 macOS 版的紧凑卡片、供应商图标和设置布局，跟随 Windows 应用的深浅色主题，使用圆角、轻描边和柔和渐变。Windows 11 22H2 及以上通过系统提供 [Desktop Acrylic 背景材质](https://learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwm_systembackdrop_type)，模糊窗口后方内容。

Windows 11 的外窗口使用系统圆角、边框和阴影，内容铺满客户区，避免自绘大圆角与系统圆角叠加产生灰边；卡片内部保留 macOS 版布局。

Windows 10、远程桌面、高对比度模式或系统关闭透明效果时使用不透明背景。省电和系统合成策略也可能使 Acrylic 显示为实色；应用不修改 Windows 的透明效果开关。

## 部署和启动

Windows 10 (1809+) 或 Windows 11 64位系统可使用 x64 绿色版。解压 ZIP 后运行 `AIQuotaMonitor.exe`；不需要安装 .NET。MiMo / Gemini 的网页登录与读取需要 [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)，系统未安装时请先安装 Evergreen Runtime。

从源码部署：

1. 安装 [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)。只有从源码构建需要 SDK。
2. 双击仓库根目录的 `双击启动_AI额度看板.cmd`。首次自动发布到 `dist\win-x64\` 并启动，以后直接启动已有产物；脚本支持包含中文或空格的路径。
3. 点击右下角通知区域的 AI 额度看板图标打开面板。图标可能位于“显示隐藏的图标”中。右键图标可刷新、打开或退出。

应用仅保留一个实例。更新可执行文件前先从托盘菜单退出。源码更新后，可运行以下命令重新构建并启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\start-windows.ps1 -Rebuild
```

## 窗口和设置

- 启动显示主窗口与本地缓存，不查询账户；主窗口在切换应用时保留。托盘左键打开的浮窗在点击外部时收起。点击“全部刷新”或供应商菜单中的刷新才查询账户。
- 右上角齿轮打开设置，设置中的 × 返回看板。Escape 在设置中先返回看板，再次按下收起窗口；Alt+F4 也会收起到托盘。
- 拖动标题可移动窗口，标题右键菜单可收起、最小化或退出。结束后台进程也可使用托盘右键菜单或设置中的“退出应用”。

设置中点击五个供应商图标选择显示哪些卡片，至少保留一家，选择自动保存。托盘使用固定应用图标，悬停显示“AI 额度看板”。

## 账户准备

| 供应商 | 配置方法 |
| --- | --- |
| DeepSeek | 点击卡片中的供应商图标或名称，在菜单选择“配置 API Key”；密钥使用 Windows 当前用户 DPAPI 加密。 |
| OpenAI · Codex | 安装 Codex CLI，并使用 ChatGPT 账户登录。看板通过本机 CLI 的 `app-server` 查询限额，无需发送对话。 |
| 小米 MiMo | 在供应商菜单选择“打开用量小窗”，使用 WebView2 登录；读取现金余额，不把 Token Plan 视为现金。 |
| Gemini | 在供应商菜单选择“打开用量小窗”，登录 Google 账户；需要页面提供可识别的限额信息。 |
| Antigravity | 启动兼容客户端或本机服务；看板自动发现本机 Hub 端口并查询。 |

点击卡片中的供应商图标或名称打开操作菜单，可单项刷新、打开官方用量页或查看详情。MiMo、Gemini 和 Antigravity 还支持“手动校准”。某个账户未配置、网页要求重新登录或本机服务未启动时，其他供应商仍可使用。网页结构、服务版本和嵌入式登录限制可能影响读取，此时可查看官方页面并手动校准。浏览器已有的登录状态不会自动导入应用。

Codex 支持 PATH 中的 `codex.exe`、npm 的 `codex.cmd`，也会自动查找本机 Codex 桌面应用附带的 CLI。自定义安装位置可设置当前用户环境变量 `CODEX_CLI_PATH` 为 CLI 的完整路径后重新启动看板。

## 本地数据

数据目录为 `%LOCALAPPDATA%\AIQuotaMonitor`：

- `deepseek.dat`：当前 Windows 用户 DPAPI 加密的 DeepSeek Key。
- `state.json`：额度缓存和显示偏好。
- `WebView2Profile\`：应用自己的网页登录会话。

这些数据不在源码目录或绿色版 ZIP 中。移动应用目录不会移动账户数据。DPAPI 密钥文件不能作为跨用户账户迁移凭据。

## 构建和打包

先运行离线回归检查：

```powershell
dotnet run --project windows/tests/ServiceTests/ServiceTests.csproj -c Release
dotnet run --project windows/tests/DesktopTests/DesktopTests.csproj -c Release
```

服务测试使用合成响应与模拟 CLI，不读取真实账户。桌面测试在隔离的临时状态目录检查 WPF 渲染和设置持久化，通过控制台报告结果；需在 Windows 上执行。测试依赖首次还原完成后可以离线运行。

在仓库根目录运行；也可双击 `windows\build-windows.bat`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\build-windows.ps1
```

脚本从项目版本号生成以下产物：

```text
dist/win-x64/AIQuotaMonitor.exe
dist/win-x64/ThirdPartyNotices.txt
dist/AIQuotaMonitor-<版本>-windows-x64.zip
dist/AIQuotaMonitor-<版本>-windows-x64.zip.sha256
```

默认使用 `Release`、`win-x64`、自包含单文件发布，并嵌入本机依赖以供运行时解包。发布目录还保留第三方许可声明。`.NET` 运行时包含在 EXE 中，WebView2 Runtime 由系统提供。

常用参数：

```powershell
# 仅发布，不压缩 ZIP
.\windows\build-windows.ps1 -NoArchive

# 已完成同一运行时的还原后，跳过 NuGet 还原
.\windows\build-windows.ps1 -NoRestore

# Windows ARM64 机器可生成对应产物；需在 ARM64 机器另行验证运行
.\windows\build-windows.ps1 -Runtime win-arm64
```

首次构建需要访问 NuGet 下载包和运行时。`-NoRestore` 只适用于依赖和对应 Runtime 已经缓存的环境，不会自动下载缺失依赖。构建失败会返回非零退出码；双击脚本会保留错误窗口。

GitHub Actions 使用同一构建脚本生成 ZIP 与 SHA-256，普通推送上传构建附件，`v*` 标签构建附加到 GitHub Release。CI 生成包不包含本机账户数据。默认产物未配置代码签名。

校验下载的包：

```powershell
Get-FileHash .\dist\AIQuotaMonitor-1.4.4-windows-x64.zip -Algorithm SHA256
```

与相邻 `.sha256` 文件中的值比较。
