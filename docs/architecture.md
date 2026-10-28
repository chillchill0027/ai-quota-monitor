# 架构与读取边界

## 组成

- `AppDelegate` 管理进程入口、程序坞主窗口和状态栏图标。
- `StatusBarDashboardPanel` 使用非激活 `NSPanel` 显示看板；在创建时配置全屏空间行为，显示时不激活整个应用。定位以被点击的状态栏屏幕为准，内容超出短屏时可滚动。
- `DashboardView` 和 `SettingsInlineView` 展示数据与本机偏好。供应商卡片显示选择至少保留一项，并与状态栏文字样式独立。
- `QuotaManager` 协调五家并行刷新、缓存、凭据变更和显示状态。
- `AccessPolicyStore` 持久化普通自动访问冷却、认证暂停及服务端等待截止时间。
- 两个本地 App 启动入口共用操作系统进程锁，避免重复实例查询；发行 DMG 仅放一个入口。

## 刷新入口

| 操作 | 行为 |
| --- | --- |
| 展开状态栏看板 | 距上次展开刷新满 300 秒时刷新五家，否则展示现有数据 |
| 启动、程序坞重开、收起面板 | 本地窗口操作，不查询账户 |
| 手动「全部刷新」 | 并行刷新五家，绕过普通时间冷却 |
| 供应商菜单「刷新此项」 | 仅刷新指定供应商，绕过普通时间冷却 |
| 保存非空 DeepSeek Key | 空闲时安排一次手动查询；忙时只保存并提示稍后手动查询 |
| 清空 Key、切换显示偏好、手动校准、解除本地暂停 | 只更新本机状态，不联网 |
| 小窗「读取当前页」 | 提取已加载的页面文字，不刷新网页 |
| 打开或刷新用量小窗 | 正常加载对应官方页面；读取器不调用模型生成接口 |

刷新采用单飞机制：已有一轮运行时，新的请求不会重复启动或暗中排队。没有应用层后台定时轮询或自动重试。

普通网络或进程失败会延长自动访问冷却，从 15 分钟起递增，最长一天；手动可立即重试。服务端 `Retry-After` 独立存为硬性截止时间，手动访问和解除认证暂停均不能缩短它。认证或验证失败会暂停对应访问，需要用户处理账户问题后明确恢复。单纯 CLI 未安装、启动失败或超时不视为认证失败。

## DeepSeek

使用官方 `GET https://api.deepseek.com/user/balance`，通过临时 URL 会话携带用户自己的 API Key。会话不使用 Cookie、缓存或会话凭据存储，不跟随重定向，不发模型请求。

余额响应严格校验币种与 Decimal 金额，缺失或格式异常不会被当作成功的零余额。显示实际币种、账户可调用状态和最后成功时间，失败时保留旧值。

Key 由 `KeychainHelper` 存入 macOS 钥匙串，保存失败不会先删除原 Key。查询期间更换凭据后，旧请求结果不会覆盖新账户，也不能暂停新 Key 的访问。UI 会明确提示查询结束后重新手动刷新。

## MiMo 与 Gemini 网页

`SafeWebExtractor` 为两家各维护独立的 `WebPageSession`。它们使用 WebKit 的正常本机登录存储，不枚举、导出、拼接或转发 Cookie，不读取外部浏览器密码，不伪造 User-Agent。

「全部刷新」为每家重新加载一次官方用量页，等待导航完成及页面渲染后进行有上限的 DOM 文本读取，不依赖小窗是否可见。网页仍会像普通浏览一样加载其脚本和资源。会话关闭或最小化时停止并卸载页面；刷新期间可临时加载隐藏页面，完成后立即卸载不可见文档。

主框架导航只允许明确的官方 HTTPS 主机。原生手动操作发放的导航许可最多 8 跳、30 秒，包含页面加载后的必要 SPA 跳转；文档完成不会续期。刷新结束会清除许可，网页自主导航继续走自动限频路径。旧文档、取消导航及卸载空白页回调不会影响新一轮刷新。认证、验证、401/403/429 等限制会停止访问；应用不自动解决验证码。

### MiMo 语义

仅接受明确的 `Cash Balance`、`现金余额` 或 `账户现金余额` 标签，支持零、负数、整数、千分位及 CNY/USD。充值按钮、预警阈值、赠金和可用总额不作为现金余额，Token Plan 为另一种统计口径。

本实现未接入未经确认支持的控制台内部余额端点。2026-10-26 核对公开文档时，未找到可凭 MiMo API Key 查询现金余额或套餐剩余的公开受支持接口；该判断是实现依据，并非对平台未来接口的承诺。不能明确识别时保留上次记录并标明失败，允许明确标注的手动录入。

### Gemini 语义

从明确的 5 小时、每周窗口标题及「已用/剩余」含义识别配额，支持中英文与跨行布局。不会直接取整页前两个百分比，歧义或冲突数据拒绝猜测。

一次观测整体替换两个窗口；缺失窗口显示未读取，不混入上次旧值。重置提示保留网页原文和观测时间，不猜时区或绝对时间，不在到期后自动填成 100%。

## OpenAI Codex

使用本机已登录的官方 Codex CLI app-server，初始化后调用 `account/rateLimits/read`。本应用不读取 OpenAI Cookie 或令牌文件，不抓取其网页，不创建模型对话。

优先使用 `rateLimitsByLimitId.codex`，兼容旧版 `rateLimits`，不混入其他限额桶。按 `windowDurationMins` 匹配 300 分钟和 10080 分钟，不依赖 primary/secondary 顺序。剩余百分比为 `100 - usedPercent`；缺失不是零，到达官方 `resetsAt` 后提示过期，不自行恢复额度或按周一重置。

CLI 查询使用非阻塞管道和单调时钟。达到 20 秒截止或取消时，终止并回收独立进程组，包括忽略普通终止信号或子进程继承输出管道的情况。正常完成也不保留后台查询进程。官方 CLI 自行管理其认证及内部网络请求。

该数据表示 Codex 订阅限额，不代表 ChatGPT 全部普通聊天模型的统一额度。

## Antigravity

连接本机正在运行的 Antigravity Hub 或语言服务，调用 `RetrieveUserQuotaSummary` 读取其提供的配额。实现检测本地端口及当前服务认证信息，向回环地址发出请求，不向模型提交提示词。

可解析 Gemini 5 小时、Gemini 每周、Argon 每周和第三方模型每周数据；当前看板展示前三项。本地服务可能按其自身逻辑向上游更新数据，因此本机调用不等于承诺该客户端完全不联网。此读取路径依赖兼容的 Antigravity 版本。

## 本地状态与分发

额度缓存、访问策略和显示偏好由本机设置持久化；网页登录存储由 WebKit 管理，Key 由钥匙串管理。显示状态区分官方接口、网页读取、手动录入、缓存和失败，重启不会把失败数据伪装成新同步结果。

源码仓库与 DMG 不应包含账户设置、钥匙串内容、浏览器会话、实际余额截图或调试录屏。第三方资源声明随应用分发。

## 实现依据

以下是项目核对过的官方资料入口；第三方产品限制和接口可能调整：

- [DeepSeek 余额查询接口](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/)
- [小米 MiMo 付费说明](https://mimo.mi.com/docs/zh-CN/quick-start/faq/payment)
- [小米 MiMo 文档索引](https://mimo.mi.com/llms.txt)
- [Gemini 应用限额与查看方式](https://support.google.com/gemini/answer/16275805?hl=zh-Hans)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
- [Codex 计划与限额](https://learn.chatgpt.com/docs/pricing)
- [Apple Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Apple 材料设计指南](https://developer.apple.com/design/human-interface-guidelines/materials)
