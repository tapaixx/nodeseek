# NS Connect Privacy Policy

NS Connect is an open-source, unofficial third-party iOS client for NodeSeek.

## Data Collection

NS Connect uses Google Firebase Crashlytics to automatically collect crash reports and diagnostic information to identify crashes and improve app stability. Reports may include stack traces, app version and state, device and operating system information, and installation identifiers used to process crash reports. Reports are normally sent when the app is next launched after a crash. Firebase components also collect technical diagnostics to monitor SDK quality.

This information is processed by Google Firebase. NS Connect does not attach your NodeSeek account, email address, session cookies, or ordinary local log files to Crashlytics reports. It does not use this information for advertising or cross-app tracking, and does not integrate Google Analytics. For Google's processing and retention practices, see [Firebase Privacy and Security](https://firebase.google.com/support/privacy).

When you sign in or interact with forum content, NS Connect connects to NodeSeek using your own NodeSeek account session. Those interactions are handled by NodeSeek and are subject to NodeSeek's own terms and privacy practices.

## Local Data

NS Connect may store local app data on your device, such as session cookies, cache files, logs when file logging is enabled, and app preferences. This data is used to operate the app and is not sold by NS Connect.

## Open Source

The source code is available at:

https://github.com/tyrad/nodeseek

## Contact

For support or privacy questions, use GitHub Issues:

https://github.com/tyrad/nodeseek/issues

---

# NS Connect 隐私政策

NS Connect 是一个开源、非官方的 NodeSeek iOS 第三方客户端。

## 数据收集

NS Connect 使用 Google Firebase Crashlytics 自动收集崩溃报告和诊断信息，以定位崩溃并改善应用稳定性。报告可能包含调用堆栈、应用版本和运行状态、设备及操作系统信息，以及用于处理崩溃报告的安装标识符。报告通常在崩溃后的下一次启动时发送。Firebase 组件还会收集技术诊断信息以监测 SDK 质量。

这些信息由 Google Firebase 处理。NS Connect 不会将你的 NodeSeek 账号、邮箱、会话 Cookie 或普通本地日志文件附加到 Crashlytics 报告中，不将这些信息用于广告或跨应用跟踪，也未接入 Google Analytics。Google 的数据处理和保留规则详见 [Firebase 隐私与安全说明](https://firebase.google.com/support/privacy)。

当你登录或与论坛内容互动时，NS Connect 会使用你自己的 NodeSeek 账号会话连接 NodeSeek。这些互动由 NodeSeek 处理，并受 NodeSeek 自身条款和隐私实践约束。

## 本地数据

NS Connect 可能会在你的设备本地保存应用数据，例如会话 Cookie、缓存文件、开启文件日志后的日志，以及应用偏好设置。这些数据用于应用正常运行，NS Connect 不会出售这些数据。

非公开极简探针的会话按面板分别保存在本机 Keychain，不保存密码或 GitHub Cookie。登录与探针请求直接连接你填写的面板，退出面板账户会清除本机会话与缓存。私有面板的小组件只使用 App 更新的共享快照，不持有登录会话。

## 外部通知渠道

企业微信机器人与 Bark 为可选的 App 直连渠道，无需部署独立通知服务。密钥与鉴权信息仅保存在本机 Keychain。App 在可执行期间读取当前 NodeSeek 账号的新通知并向所选平台投递摘要；私信不转发正文。不会将 NodeSeek Cookie 发送至这些平台，也不实现 Bark 端到端加密。自架 Bark 的请求日志可能包含正文与密钥，需由服务维护者检查日志设置。

## 开源

源代码地址：

https://github.com/tyrad/nodeseek

## 联系方式

如需支持或咨询隐私问题，请使用 GitHub Issues：

https://github.com/tyrad/nodeseek/issues
