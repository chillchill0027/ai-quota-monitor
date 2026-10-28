# 开发与打包

## 构建环境

- Apple Silicon Mac。
- Xcode 26 或更新版本，或对应 Command Line Tools。源码使用 macOS 26 SDK 中的玻璃 API，并通过运行时可用性判断兼容 macOS 14 及更新版本。
- Swift、`sips`、`iconutil`、`codesign` 和 `hdiutil`。

当前构建目标为 `arm64-apple-macosx14.0`，尚未提供 Intel 通用二进制。`Package.swift` 描述 Swift 源码目标；可安装的 App 资源与元数据由构建脚本装配。

## 本地构建

```sh
./build.sh
```

脚本从 `Sources/` 编译，生成应用图标并装配 App。默认保留根目录的「AI额度看板.app」和「AIQuotaMonitor.app」两个兼容入口；它们包含相同程序，使用相同的实例锁。元数据模板位于 `packaging/Info.plist`。

需要隔离构建输出时，可指定目录：

```sh
BUILD_OUTPUT_DIR=/tmp/ai-quota-monitor-build ./build.sh
```

应用图标的主图位于 `Resources/AppIcon.png`。`scripts/build-app-icon.sh` 生成标准 macOS 多尺寸 `AppIcon.icns`；供应商品牌图标及其声明位于 `Resources/ProviderIcons/` 和 `Resources/ThirdPartyNotices.txt`。

## 离线回归

```sh
./test.sh
```

测试使用独立临时设置、合成响应、模拟读取器和本地伪 CLI，不读取真实 Key，不访问真实账户，不调用模型。测试不需要 XCTest。

覆盖范围包括：

- Codex 限额桶与窗口匹配、缺失数据、零值和过期处理。
- CLI 握手、超时、取消、进程组及输出管道清理。
- DeepSeek 响应和金额校验、Cookie/缓存策略、重定向与服务端等待。
- MiMo/Gemini 文本语义、重新加载、SPA 延迟渲染、登录限制和取消。
- 自动展开五分钟限制、手动刷新、认证暂停、单飞与凭据变更。
- 供应商最少一项、旧设置迁移、持久化、切换显示不发查询。
- 浮动面板在多屏负坐标、小屏和失效锚点情况下的边界定位。
- Antigravity 配额解析与本地服务生命周期。

窗口叠放、真实全屏空间、深浅色、菜单及校准弹窗的交互还需原生 UI 验证；纯逻辑测试不能替代这些检查。

## DMG

```sh
bash scripts/package-dmg.sh
```

产物位于 `dist/`。DMG 仅装入一个「AI额度看板.app」、指向系统 Applications 的软链接及安装说明，不打包源码、浏览器会话或开发者的本机设置。发行文件使用版本号和架构区分，并附带 SHA-256 校验文件。

打包验证应包括：

1. 从干净源码和独立输出目录构建。
2. 只读挂载 DMG，确认 App、Applications 链接和安装说明存在。
3. 校验包内 App 的签名、版本和图标资源。
4. 卸载映像并核对最终 SHA-256。

`dist/`、本地 App、编译缓存、调试截图、录屏、账户配置及密钥文件不应纳入 Git。安装产物可以作为 GitHub Release 附件单独分发。

## 签名与公证

默认构建使用 ad-hoc 本地签名，适合开发验证；它不等于已获 Apple 认证的公开发行签名，也不能保证下载后通过 Gatekeeper。

面向公众分发通常还需：

- Apple Developer Program 账户及 Developer ID Application 证书。
- 对发行可执行文件进行正式签名，启用 Hardened Runtime 并使用安全时间戳。
- 使用 Apple 公证服务检查发行包，并附加公证凭据。
- 在没有开发者本机设置的 Mac 环境验证下载、安装和首次启动。

DMG 分发无需上架 Mac App Store。参考 [Developer ID](https://developer.apple.com/developer-id/) 和 [Apple 公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。私钥、公证凭据和账户令牌应由开发者在本机或受保护的发布环境配置，不能写入仓库。
