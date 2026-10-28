# AI 额度看板

一款 macOS 菜单栏工具，集中查看 DeepSeek、小米 MiMo、OpenAI Codex、Gemini 和 Antigravity 的余额或剩余额度。支持程序坞主窗口、其他应用全屏时的浮动看板，以及按供应商选择显示内容。

## 下载

- [直接下载 macOS 安装包（Apple Silicon · dmg）](https://github.com/chillchill0027/ai-quota-monitor/releases/latest/download/AIQuotaMonitor-1.4.4-arm64.dmg)
- [查看 GitHub Releases 发布页](https://github.com/chillchill0027/ai-quota-monitor/releases/latest)（提供 SHA256 校验文件与源码压缩包）

## 系统要求

- Apple Silicon Mac（当前发行包为 arm64）。
- macOS 14 或更新版本。
- macOS 26 及更新系统使用原生 Liquid Glass，旧系统使用兼容的毛玻璃外观。

当前 DMG 使用 ad-hoc 本地签名，尚未进行 Developer ID 签名和 Apple 公证，macOS 可能要求额外的安全确认。正式面向公众分发的签名要求见 [开发与打包](docs/development.md)。

## 安装与首次使用

1. 打开 DMG，将「AI额度看板」拖到「Applications / 应用程序」。
2. 从应用程序启动，点击卡片左上角的供应商图标或名称，配置对应账户。
3. 点击「全部刷新」读取五家的最新数据。缺少账户配置的供应商会提示原因，不影响其他供应商。

| 供应商 | 读取内容与方式 | 使用前准备 |
| --- | --- | --- |
| DeepSeek | 通过官方余额 API 读取账户余额 | 在卡片菜单中填写自己的 API Key；Key 存入本机钥匙串 |
| 小米 MiMo | 重新加载官方控制台，读取明确标注的现金余额 | 在应用的用量小窗登录；现金余额不包含 Token Plan 套餐额度 |
| OpenAI · Codex | 通过官方 Codex CLI 读取 5 小时、7 天窗口及重置时间 | 安装 Codex CLI，并使用 ChatGPT 账户登录 |
| Gemini | 重新加载官方用量页，读取 5 小时及每周剩余额度 | 在应用的用量小窗登录相应 Google 账户 |
| Antigravity | 向本机运行的 Antigravity 服务读取模型配额 | 启动兼容的 Antigravity 客户端或本地服务 |

OpenAI 卡片显示的是 **Codex 额度**，不代表 ChatGPT 所有聊天模型的统一限额。网页登录由 WebKit 管理；系统浏览器已有的登录状态不一定能直接复用。平台限制嵌入式登录时，可查看官方页面并手动校准。

## 显示与刷新

- 设置页点击五个供应商图标切换卡片显示，至少保留一家；选择自动保存在本机。
- 四种状态栏样式提供实时预览，与卡片显示选择独立。隐藏卡片不改变「全部刷新」的五家查询范围。
- 单项刷新、API Key、官方用量页、小窗、校准和刷新详情位于供应商菜单中。重置时间可悬停查看。
- **手动刷新没有普通时间冷却。** 同一轮尚未完成时不重复启动，也不排队。
- **点开状态栏看板最多每 5 分钟刷新一次。** 启动、点击程序坞和收起面板只显示缓存，不查询账户；没有后台定时轮询。
- 认证暂停和服务端明确返回的等待时间仍对手动操作生效。读取失败保留旧数据，并显示缓存时间与失败状态。

状态栏看板可在其他应用的全屏空间中打开。再次点击图标、按 Escape、点击外部应用或切换空间会收起；菜单和校准小窗不会因焦点变化误关。设置页底部可退出应用。

## 本地数据

本应用没有项目自建的中转服务器。DeepSeek Key 存在 macOS 钥匙串中，网页会话保留在 WebKit 的本机存储中，显示偏好和额度缓存保存在本机。应用不导出网页登录 Cookie，不读取其他浏览器的密码，也不通过发送模型对话来推算额度。

分发包不包含开发者的 Key、网页登录状态、额度缓存或本机设置。第三方页面和客户端仍会按其自身行为访问相应服务。读取边界和实现细节见 [架构说明](docs/architecture.md)。

## 从源码构建

需要 Xcode 26 或更新版本，或带相应 macOS SDK 的 Command Line Tools。

```sh
./test.sh
./build.sh
bash scripts/package-dmg.sh
```

默认构建保留两个兼容的本地启动入口；DMG 中只包含「AI额度看板」。安装包和校验文件输出到 `dist/`，不纳入源码版本控制。可复现构建、签名及测试说明见 [开发与打包](docs/development.md)。

## 项目目录

```text
Sources/      SwiftUI、AppKit 和各供应商读取实现
Tests/        使用合成数据与模拟进程的离线回归测试
Resources/    应用图标、供应商品牌图标及第三方声明
packaging/    应用包元数据模板
scripts/      图标生成与 DMG 打包脚本
docs/         架构与开发说明
dist/         本地产物，不纳入版本控制
```

第三方图标来源及许可见 [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt)。版本变化见 [CHANGELOG.md](CHANGELOG.md)。
