# 企业微信机器人与 Bark 接入研究

核验日期：2026-11-15。依据官方文档和原始代码；下文区分平台事实与本项目的实现建议。未使用真实密钥或发送通知。

## 投递与维护方式

现有 [ns-apns](https://github.com/tyrad/ns-apns) 使用绑定 NodeSeek 的 Telegram 账号监听官方 `@nodemaid_bot` 新提醒。App 当前只提供 APNs 设置和部署引导，持续事件监听在服务端。

**实现建议：扩充 ns-apns 的投递通道，App 提供服务地址、渠道入口和部署说明。** 企业微信 Webhook、Bark 密钥及开关集中在用户自己的服务设置页维护。两个通道均应独立于 NS Connect 的 APNs Token 和证书，可单独启用，也可同时启用。

这个选择避免将手机前台转发误称为持续推送：Apple 明确说明背景通知可能被延迟、合并或丢弃，且只有短暂后台执行时间。App 前台轮询和后台刷新都不适合作为可靠的常驻事件监听器。[Apple 官方说明](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

## 企业微信机器人

官方目前将原“群机器人”称为“消息推送”。创建者在其创建或详情页获取独立 Webhook，通过 JSON POST 发送：

```text
https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<私有密钥>
```

`text` 使用 `text.content`，上限为 2048 个 UTF-8 字节；`markdown` 使用 `markdown.content`，上限为 4096 个 UTF-8 字节。每个机器人最多发送 20 条/分钟。较新的 `markdown_v2` 在旧客户端会退化为纯文本，因此首版采用兼容面更广的 `markdown`。[官方配置说明](https://developer.work.weixin.qq.com/document/path/91770)

**实现建议：** 使用短标题、发送者、截短的内容与“查看详情”HTTPS 链接；按最终 UTF-8 字节预算截断，保留链接。正文应转义可能产生标题、链接和成员提醒的内容，不自动 `@all`。按机器人密钥串行排队并限频，测试消息也计入额度。仅接受官方 HTTPS 域名、固定发送路径和有效 `key`，拒绝用户信息及多余查询参数；不跟随跨站重定向。

不能只凭 HTTP 200 判断成功，还需检查 `errcode`。官方全局错误码中，`0` 表示成功，`-1` 表示系统繁忙且建议重试不超过 3 次，`45009`/`45033` 为频率或并发限制；`40058` 为参数错误，`93000` 表示 Webhook 不合法或被移除，`93004` 表示停用。[官方错误码](https://developer.work.weixin.qq.com/document/path/90313)

**重试建议：** 明确繁忙或限频时延迟有限重试；无效配置立即显示可操作的错误。持久保存每个事件、每个通道的处理结果，成功记录不再发送。官方没有提供该接口的幂等键；请求逾时后不能确定对方是否已收到，自动重试可能重复。应区分“明确失败”与“结果不明”，不能承诺绝不漏发且绝不重复。

Webhook 本身就是发送凭据。官方特别要求避免公开它；本项目应对设置回显、日志、诊断信息和导出文件作相应隐藏处理。[官方密钥说明](https://developer.work.weixin.qq.com/document/path/91770)

## Bark

采用官方推荐的 JSON API：`POST https://api.day.app/push`，把 `device_key` 放入请求体，不放在路径或查询中。支持用自架服务替换主机，保留其部署前缀。[官方教程](https://github.com/Finb/Bark/blob/master/docs/en-us/tutorial.md)、[服务端 API V2](https://github.com/Finb/bark-server/blob/master/docs/API_V2.md)

推荐通知字段：

```json
{
  "device_key": "<私有密钥>",
  "title": "NS Connect · 新私信",
  "body": "发送者：消息摘要",
  "group": "NodeSeek",
  "level": "active",
  "url": "nsconnect://notification?type=message",
  "id": "nodeseek-telegram-12345"
}
```

`group` 对系统通知和 Bark 历史记录分组；`icon` 可选，首次下载超时会退回默认图标。`level` 默认采用 `active`，可让用户选择安静的 `passive` 或较强的 `timeSensitive`，不将 `critical` 或循环响铃作为站内提醒默认。`url` 明确支持 URL Scheme 和 Universal Link。[官方参数](https://github.com/Finb/Bark/blob/master/docs/en-us/params.md)

同一字符串 `id` 可更新、替换先前通知；该能力要求 Bark 1.5.2 及 bark-server 2.2.5 以上。官方服务端将此字段映射为 APNs Collapse ID。**建议：** 从来源和事件编号生成稳定 `id`，重试保持不变；它有助于减少重复，但不代表端到端精确一次投递。[官方参数](https://github.com/Finb/Bark/blob/master/docs/en-us/params.md)、[APNs 实现](https://github.com/Finb/bark-server/blob/master/apns/apns.go)

服务响应需同时检查 HTTP 和 JSON `code == 200`。错误或缺失设备密钥会被服务端拒绝；成功响应表示已提交到 APNs，不应表述为用户已经阅读。[投递实现](https://github.com/Finb/bark-server/blob/master/route_push.go)、[响应结构](https://github.com/Finb/bark-server/blob/master/router.go)

Bark 使用自己的 APNs Topic，收件设备需要安装 Bark 并允许通知。由此可知，Bark 收件不依赖 NS Connect 侧载包的 APNs 签名能力。[官方 APNs 实现](https://github.com/Finb/bark-server/blob/master/apns/apns.go)

## 点击通知回到 App

核验时，本 App 已注册 `nsconnect`，但 URL 入口只处理探针小组件；站内私信链接是 `https://www.nodeseek.com/notification#/message?mode=talk&to=<uid>`。Bark 可以携带自定义 Scheme，但本项目仍须补齐通知 Scheme 的冷启动、运行中跳转及非法地址测试。

**实现建议：** 新增独立的通知路由，外层参数仅允许已支持的通知类型和 NodeSeek HTTPS 地址，复用现有原生帖子、列表与私信导航。Bark 选择回 App；企业微信消息保留可在不同平台打开的 HTTPS 原始链接。不应假设企业微信客户端允许任意 Scheme。

## 部署、隐私与后续维护

- 优先沿用已有常驻服务、事件解析和设置页，分离事件来源与投递通道；某通道失败不能触发已成功通道重送。服务重启后保留去重状态；首次连接不批量重放旧提醒。
- 采用 HTTPS、正常证书校验、有限请求时间与有限重试；明确显示配置错误、限频、最近成功时间及测试结果。密钥仅由用户在私有设置页录入，不进入 Git、App 快照、日志或发布产物。测试通知由用户点击触发。
- Bark 官方公共服务最省维护；自架可使用[官方 Docker 镜像](https://github.com/Finb/bark-server#installation)，需持久化数据、维护 HTTPS 与版本。官方支持 URL 前缀及可选 Basic Auth；实现未支持的鉴权方式应在界面和文档中明确说明。[鉴权代码](https://github.com/Finb/bark-server/blob/master/route_auth.go)
- **自架日志注意：** 核验时 bark-server 默认请求日志包含 URL 和请求正文。因此改用 POST 只减少路径泄漏，仍需自行去除服务端请求正文日志，不能宣称明文密钥与内容完全不进入日志。[官方日志实现](https://github.com/Finb/bark-server/blob/master/router.go)
- 明文推送会向选定服务发送内容。Bark 另有客户端配置密钥的加密推送能力；如首版未实现，不应宣称端到端加密。[官方加密文档](https://github.com/Finb/Bark/blob/master/docs/en-us/encryption.md)

## 验收边界

自动验证应覆盖实际 JSON 结构、字节截断、密钥隐藏、HTTPS 与重定向、接口级失败、限频、稳定事件编号、多通道独立结果、重启去重及通知深链接。真实收件、企业微信客户端展示和 Bark 点击回 App，仍须使用用户自行配置的服务与设备验收。
