# Fork 自动发版

向 `main` 推送后，`Fork Release` 自动构建并发布到本仓库的 GitHub Releases。也可以在 Actions 手动运行。无需配置 Apple 证书或额外密钥。

## 构建机器

- 仓库位于 `tapaixx/nodeseek`，Release 与 TestFlight 使用组织内的 `OMacBook` 自托管 runner，标签为 `self-hosted`、`macOS`、`ARM64`。
- 组织 runner 组需允许此仓库访问；Mac 离线或正在运行其他任务时，构建会排队等待。
- 使用 Mac 当前配置的 Xcode，工作流记录 Xcode 与 Swift 版本；升级构建工具时在 Mac 上维护。

## 版本号

- 原版本读取工程所有 target 的 `MARKETING_VERSION`，当前是 `1.4.2`。
- 发版名称、标签和 App「关于」版本依次为 `1.3.1-1`、`1.3.1-2`；Git 标签带 `v` 前缀。
- 序号按同一原版本已有的 fork 标签递增，原版本升级到 `1.3.2` 后从 `1.3.2-1` 开始。
- iOS 的 `CFBundleShortVersionString` 保留数字格式，`CFBundleVersion` 使用序号；完整 fork 版本通过 `Build Release Version` 注入。
- 同一提交重跑沿用已有版本。完整发布后跳过重复构建；失败时留下的草稿允许补传产物，已发布的文件不会覆盖。
- 建置前先保留对应提交的标签，避免建置期间 `main` 更新造成 GitHub 发布权限错误；已被新提交取代且尚未开始的任务会跳过。
- 发版任务串行执行，只有所有文件上传完成才公开 Release。

## 下载与安装

每次发布包括 `NS-Connect-<版本>-unsigned.ipa`、`SHA256SUMS` 和 `build-provenance.json`。IPA 包含主 App 与 ProbeWidget 扩展。

Fork Release 的无签名包关闭 Crashlytics 采集，归档时也不会上传符号到上游 Firebase 项目。

IPA 未签名，需要用自己的 Apple 账号通过支持的侧载工具签名安装，不能直接点击安装。推送通知、App Groups 等能力取决于自行签名时使用的账号与描述文件。

原有 `TestFlight` 流程仍供配置 Apple 签名的维护者使用，见 [TestFlight 文档](testflight-release.md)；fork 的 `v1.3.1-1` 标签不会触发该流程。

## 本地检查

```sh
python3 scripts/check_message_cache_release.py
python3 -m unittest discover -s scripts/tests -v
python3 scripts/fork_release.py prepare
make xcode-test-class TEST=SettingsBuildInfoTests SIMULATOR_ID=<设备编号>
```
