# 原生私信

私信列表、用户主页的「私信」和带对话地址的推送进入原生对话页。只有用户选择右上角「在网页中打开」时才显示网页。

- 使用现有登录会话读取 `/api/notification/message/with/{uid}`，通过隐藏 WebView 提交 `/api/notification/message/send`。发送字段为 `{receiverUid, content, markdown:false}`。
- 按消息编号排序、去重，只显示当前账号与目标用户之间的记录；只标记收到的未读消息。
- 支持文字收发及历史消息中的行内 Markdown、链接；图片上传和完整 Markdown 编辑暂未加入。
- 对话可见且应用在前台时每 10 秒更新。阅读旧消息时保留滚动位置。
- 双方头像保留在消息两侧，可点击进入对应主页。短消息气泡随内容收窄，长消息最多占屏幕宽度的 72%。
- 对方资料默认折叠，点击「对方资料」展开等级、注册时间及最近主题；点击资料或主题可进入详情。
- 输入框随内容增高，发送成功后滚动到最新消息。
- 发信失败保留当前页面的输入。结果不明时停止再次发送，由用户刷新核对并确认后解锁，不自动重发。
- 退出或切换账号后，下一次读取或发送会清除该页面的私人内容。

## 验证

```sh
make spm-test
make xcode-test-class TEST="MessageConversationTests NotificationViewControllerTests" SIMULATOR_ID=<设备编号>
```

`MessageConversationTests` 使用虚构数据和模拟请求，覆盖收发、重复提交、发信失败、账号变化及深浅色布局。布局截图保存为测试附件。

真实账号验收：从私信列表和用户主页进入对话，双向发送一条文字；确认推送能进入对应对话，返回列表后未读数量更新；断网发送后确认文字仍在。接口格式参考 [Nodyssey](https://github.com/5151561/nodyssey/blob/main/shared/src/commonMain/kotlin/io/github/nodyssey/data/MessageRepository.kt) 和 [iNod](https://github.com/chentyke/iNod/blob/main/docs/API.md)，仍需在已登录的 NodeSeek 会话中确认实际收发。
