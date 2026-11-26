# 原生私信

私信列表、用户主页的「私信」和带对话地址的推送进入原生对话页。只有用户选择右上角「在网页中打开」时才显示网页。

- 使用现有登录会话读取 `/api/notification/message/with/{uid}`，通过隐藏 WebView 提交 `/api/notification/message/send`。发送字段为 `{receiverUid, content, markdown:false}`。
- 按消息编号排序、去重，只显示当前账号与目标用户之间的记录；只标记收到的未读消息。
- 已读状态同步独立于聊天加载和发送；同步失败保留提示并在刷新时重试，不禁用发送。发送使用独立的隐藏 WebView 通道，不等待已读同步请求。
- 支持文字收发及历史消息中的行内 Markdown、链接；图片上传和完整 Markdown 编辑暂未加入。
- 对话可见且应用在前台时每 10 秒补读；回到前台或消息中心发现对方的新私信时立即尝试刷新。已加载的对话在刷新过程中仍可发送，发送成功后的读取优先于之前的旧请求。阅读旧消息时保留滚动位置。
- 双方头像保留在消息两侧，可点击进入对应主页。短消息气泡随内容收窄，长消息最多占屏幕宽度的 72%。
- 对方资料默认折叠，点击「对方资料」展开等级、注册时间及最近主题；点击资料或主题可进入详情。
- 输入框随内容增高，发送成功后滚动到最新消息。
- 发信失败保留当前页面的输入。结果不明时停止再次发送，由用户刷新核对并确认后解锁，不自动重发。
- 退出或切换账号后，下一次读取或发送会清除该页面的私人内容。
- 「AI 助手」在论坛私信的更多菜单或交易群聊区内，可总结、分析或生成回复建议。设备端模式需要 iOS 26 和已就绪的 Apple 智能；自定义 API 模式支持 OpenAI 兼容的 HTTPS Chat Completions 接口（例如 `https://example.com/v1`、指定模型 ID、可选 API Key），不要求 Apple 智能。配置保存在设备钥匙串。每次向自定义服务发送文字前都会显示地址并征得确认；不会跟随重定向。两种模式均只使用近期已加载的文字，排除交易群聊的定向私密消息。建议可复制或追加到草稿，发送仍由用户确认。

## 验证

帖子详情右上角的「✨ AI 助手」复用同一套模型配置。助手读取当前可见的主楼和已加载评论节选，不会为分析自动翻页；回复建议追加到原生评论草稿，由用户自行编辑并发布。

助手打开后直接显示总结、分析和建议回复三个操作，点击后开始对应任务；已有自定义 API 配置时默认使用该配置。未就绪的设备端模型不再隐藏操作入口，会提示配置自定义 API。

```sh
make spm-test
make xcode-test-class TEST="MessageConversationTests NotificationViewControllerTests" SIMULATOR_ID=<设备编号>
```

`MessageConversationTests` 使用虚构数据和模拟请求，覆盖收发、重复提交、发信失败、账号变化及深浅色布局。布局截图保存为测试附件。

真实账号验收：从私信列表和用户主页进入对话，双向发送一条文字；确认推送能进入对应对话，返回列表后未读数量更新；断网发送后确认文字仍在。接口格式参考 [Nodyssey](https://github.com/5151561/nodyssey/blob/main/shared/src/commonMain/kotlin/io/github/nodyssey/data/MessageRepository.kt) 和 [iNod](https://github.com/chentyke/iNod/blob/main/docs/API.md)，仍需在已登录的 NodeSeek 会话中确认实际收发。
