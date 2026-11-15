# 企业微信与 Bark 直连接入依据

核验日期：2026-11-15。用户明确要求无需部署独立通知服务，因此当前实现是 App 原生配置、直接投递；此前以 ns-apns 为必需项的方案已移除。

## 事件来源与 iOS 限制

企业微信机器人和 Bark 接受推送请求，不会替使用者读取 NodeSeek 账号。本项目使用现有站内通知 API 读取提及、回复及私信，依当前登录账号分别去重，不依赖 Telegram。

Apple 的后台刷新只提供由系统调度的短时运行机会，不能作为持续监听器；强制关闭 App 后不应承诺即时转发。因此界面必须明确标示前台定期检查、后台不保证实时以及强制关闭后的限制。[后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)、[后台通知限制](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

## 企业微信机器人

向 `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<密钥>` JSON POST；本项目采用兼容的 `markdown`，`markdown.content` 上限4096个 UTF-8 字节，每机器人每分钟最多20条。使用短标题、摘要与HTTPS详情链接，并按最终字节预算截断。`markdown_v2` 在旧客户端可退化为纯文本，因此没有作为默认。[官方配置说明](https://developer.work.weixin.qq.com/document/path/91770)

必须同时检查 HTTP 和 `errcode == 0`。官方错误码中，-1为繁忙，45009/45033为频率或并发限制，40058为参数错误，93000/93004为Webhook无效或停用。官方未提供此接口的幂等键；传输中断时不能确定对方是否收到，因此本版本不盲目重送。[官方错误码](https://developer.work.weixin.qq.com/document/path/90313)

实现限定官方HTTPS域名、固定路径与单个key，不跟随重定向。密钥只保存本机Keychain，不回显或记录在日志。

## Bark

官方推荐 JSON `POST /push`，设备密钥放在 `device_key`，不放请求路径。可用自架服务替代主机并保留路径前缀；本项目将 Bark App 复制的完整推送地址拆成服务地址和设备Key。[官方教程](https://github.com/Finb/Bark/blob/master/docs/en-us/tutorial.md)、[API V2](https://github.com/Finb/bark-server/blob/master/docs/API_V2.md)

采用 `title/body/group/level/url/id`：默认普通通知active，可选passive/timeSensitive，不默认启用critical或循环响铃。`url` 支持自定义Scheme，因此使用经过校验的 `nsconnect://notification` 进入原生页面。[官方参数](https://github.com/Finb/Bark/blob/master/docs/en-us/params.md)

稳定字符串id可更新同一通知，需要Bark≥1.5.2、服务端≥2.2.5；官方映射为APNs Collapse ID，但不能当作端到端精确一次保证。响应还需检查JSON `code == 200`；成功表示服务接受推送，不能表述成用户已经阅读。[APNs实现](https://github.com/Finb/bark-server/blob/master/apns/apns.go)、[投递响应](https://github.com/Finb/bark-server/blob/master/route_push.go)

自架可采用Basic Auth；请求使用正常证书验证与独立无Cookie会话。本版本支持Basic Auth，不把用户名密码嵌入URL。[鉴权实现](https://github.com/Finb/bark-server/blob/master/route_auth.go)

自架bark-server默认日志可能包含请求正文，因此POST只能减少路径泄漏，仍需在自架服务移除敏感正文日志。本版本没有实现Bark端到端加密。[日志实现](https://github.com/Finb/bark-server/blob/master/router.go)、[加密说明](https://github.com/Finb/Bark/blob/master/docs/en-us/encryption.md)

## 验证边界

自动测试使用虚构密钥和模拟投递，覆盖请求格式、密钥隔离、UTF-8预算、平台成功码、账号切换、基线、去重、错误与原生设置深浅色画面。真实收件、后台调度与跨App跳转仍需自己的设备验收。
