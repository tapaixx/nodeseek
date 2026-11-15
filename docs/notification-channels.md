# 企业微信机器人与 Bark

两个渠道由 [ns-apns fork](https://github.com/nnnmdzz/ns-apns) 常驻转发 NodeSeek 官方 Telegram「新提醒」。App 关闭后仍可接收，可同时启用；无需 NS Connect 的 Device Token 或 APNs 签名能力。通知来源仍需先在 NodeSeek 绑定 Telegram。

## 配置

1. 部署或升级 [ns-apns](https://github.com/nnnmdzz/ns-apns/blob/main/docs/notification-channels.md)，在服务首页完成 Telegram 登录。
2. App → 设置 → 推送通知 → 推送服务地址，填写该服务的 HTTPS 地址，例如 `https://notify.example.com`。使用独立域名，地址中不填写路径、密码或密钥。
3. 点击「企业微信机器人」或「Bark」，在服务的设置页维护密钥、开关与测试通知。若设置了访问密码，先登录服务。
4. 保存后点击对应渠道的「发送测试通知」，在企业微信或 Bark 确认收件。

企业微信使用群机器人提供的完整 Webhook。消息包含摘要及 HTTPS 详情链接；接口按每机器人每分钟 20 条限频。

Bark 使用 App 中复制的完整推送地址，例如 `https://api.day.app/你的设备Key`。自架可使用 HTTPS 域名和路径前缀；Basic Auth 在折叠的高级设置中填写。可维护分组，并选择普通、静默或时效性通知。

Bark 收件端需安装 Bark 并允许通知。点击通知通过 `nsconnect://notification` 回到 NS Connect：帖子进入详情，私信进入原生对话；没有具体链接时进入对应通知列表。

## 维护

密钥保存在自己的服务中，App 只记住服务地址。密钥保存后不回显，留空保持原值；停用保留配置，清除则移除对应凭据。最近成功时间与错误按渠道分别显示。

已有 ns-apns 用户升级二进制即可，保留 `settings.json` 和 `session.json`；新渠道默认关闭。详见服务的[升级与验证说明](https://github.com/nnnmdzz/ns-apns/blob/main/docs/notification-channels.md)。

成功投递记录持久化，重启后继续去重；明确限频或繁忙时有限重试。传输结果不明时不盲目重试，需先确认平台是否已收到。服务端不会重放历史通知，也不承诺所有第三方平台精确一次投递。

## 验证

```sh
make spm-test
make xcode-test-class TEST="ExternalPushSettingsTests ExternalPushLinkTests PushNotificationSettingsViewControllerTests PushNotificationRouteTests MessageConversationTests SettingsViewControllerTests" SIMULATOR_ID=<设备编号>
```

覆盖渠道入口、地址持久化、Bark 路由与非法 URL 拒绝、原生私信回归及深浅色布局。第三方请求使用模拟服务验证；真实收件和 Bark 点击回 App 仍需自己的账户与设备验收。官方接口依据见[接入研究](notification-channels-research.md)。
