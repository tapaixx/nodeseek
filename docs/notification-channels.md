# 企业微信机器人与 Bark 直连

这两个渠道彼此独立，由 App 直接调用对应服务。无需另行部署通知服务，无需绑定 Telegram，也不依赖 NS Connect 的 Device Token。

## App 内消息

所有 App 页面右上角都有消息入口与未读角标，保留当前页面已有的发布、保存等操作。新消息显示短暂横幅，点击进入原生私信或帖子；从编辑页打开消息后返回，草稿仍保留。阅读同一私信对话时不重复显示横幅。

消息入口与企业微信、Bark 各自独立，不配置外部渠道也可以使用。前台约每 20 秒检查，首次检查只记录已有通知，避免历史消息集中提醒。「设置 → 推送通知 → 新消息提醒」可关闭横幅与本地通知，消息入口及未读角标保留。后台刷新如发现新消息，仅在已经获得系统通知权限时显示本地通知，不会自行弹出权限请求。

App 内提醒与外部渠道共享短时读取缓存，分别维护按账号隔离的去重记录，不会自动标记通知已读。退出账号会移除本功能创建的本地通知。

## 遇到 Cloudflare 验证

打开「设置 → 手动站点验证」，也可点击通知、私信及共用加载失败页的「手动验证」。在内置网页完成验证后点击「验证后重试」，App 会先同步当前会话，再恢复消息读取；原有输入与登录 Cookie 保留。刷新按钮位于顶部提示区，右上角仍可打开消息。

识别到站点验证或打开验证页时，自动消息检查及外部渠道读取会暂停。验证完成，或新的主动读取已经成功后恢复。验证页不会自动重发私信、回帖等写入操作。Cloudflare 的通行有效期由站点配置决定，详见 [Challenge Passage](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/challenge-passage/)；响应识别依据 [官方验证响应说明](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/)。

本地验证使用模拟挑战响应与虚构 Cookie，真实挑战需要在设备上手动完成。

## 配置

1. App → 设置 → 推送通知，选择「企业微信机器人」或「Bark」。
2. 企业微信填写群机器人提供的完整 HTTPS Webhook；Bark 粘贴 Bark App 中复制的完整 HTTPS 推送地址。
3. 点击「发送测试通知」，确认对应应用收到。测试不要求登录 NodeSeek。
4. 登录 NodeSeek，开启「自动转发新通知」并保存。配置绑定当前账号；切换账号后需重新保存，才能绑定新账号。

Bark 支持官方服务与自架 HTTPS 服务，包括路径前缀；可选填写 Basic Auth，设置通知分组及普通、静默、时效性通知。点按 Bark 通知可回到 NS Connect 的原生帖子或私信。企业微信保留 HTTPS 详情链接。

## 运行范围

App 使用现有 NodeSeek 登录状态，读取提及、回复和私信列表，不修改站内已读状态。首次启用先记录已有通知，之后转发新通知；私信只发送新消息提示，不转发正文。

- 前台定期检查新通知，检查结束后等待约一分钟再检查。
- 后台使用 iOS 的后台刷新机制，何时运行由系统决定；省电、关闭后台刷新或长期不用 App 都可能延后。
- **强制关闭 App 后不会持续监听或即时转发。** 企业微信与 Bark 是收件渠道，无法主动读取 NodeSeek 账号。没有服务端事件来源时，App 无法绕过 iOS 限制保持常驻。[Apple 官方背景任务说明](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)

这与过去版本要求自部署 ns-apns 的方案不同。原有 APNs 设置仅作为可选旧方式保留，与上述两个直连渠道无关。

## 密钥与维护

地址和鉴权密钥仅保存在本机 Keychain，不回显、不放入日志。输入留空保持原值；停用保留配置，清除则删除本机凭据。重装、换机后需重新设置。

使用独立无 Cookie 的 HTTPS 会话，不将 NodeSeek 登录 Cookie 发送给推送渠道，也不跟随重定向。企业微信按至少 3.1 秒间隔发送；平台 HTTP 成功后仍检查其业务成功码。网络结果不明时不自动重送，先在收件应用核对。

已尝试的事件按账号、渠道保存去重记录。每轮投递预算之外的通知留待下次检查，某渠道失败不会重送另一渠道已处理的事件。

启用后，通知摘要会发送至所选平台。本版本未实现 Bark 端到端加密；自架 Bark 时请检查请求正文日志，避免在该服务中保存密钥与通知内容。

## 验证

```sh
make spm-test
make xcode-test-class TEST="DirectPushMonitorTests ExternalPushSettingsTests DirectPushPayloadTests PushNotificationSettingsViewControllerTests" SIMULATOR_ID=<设备编号>
```

测试使用虚构密钥与模拟请求，没有发送真实通知。真实收件、系统后台调度及 Bark 点击回 App 需使用自己的设备和密钥验收。接口依据见[官方接口研究](notification-channels-research.md)。
