# 后台下载、离线所有权与评论布局实施计划

**Goal:** 完成用户 1–8 项解释、P0 证据、P1 下载/缓存改进与评论折叠。
**Architecture:** 在线单文件音频保留 AVPlayer + 自定义 scheme ResourceLoader；显式下载使用 background NSURLSessionDownloadTask，离线文件由 Application Support 中独立所有权保护。L1 与 L2 使用同一稳定身份。评论按真实约束宽度和字体排版，完整字符边界截断并验证后缀最终布局。
**Tech Stack:** Objective-C/UIKit、WCDB、AVFoundation、NSURLSession、TextKit、XCTest。
**Spec:** 本会话用户列出的 1–8 项及“继续”；以下决策和验收为本次实施约束。
> **状态：已实施并验证（2026-09-30）。** 下方 checkbox 是原始实施清单；本次可复现的验证证据在文末。真机后台交付和真实 CDN 明确未验证。


## 约束与分工
- 在现有用户工作区原地修改，不 reset/commit/push，不改远端 API、生产配置、Pod 依赖。
- 先运行 P0 协议/真实音频验证，再切换 P1 下载路径。评论布局是独立修改。
- 系统后台下载不能承诺用户 force-quit 后继续；resumeData 可失效，必须记录失败并支持重新下载。
- completed 仅在离线正文已安全落盘且持久化状态提交成功后成立；缓存清理不得删除用户离线下载。
- 不增加 HLS 转码或把 MP3 伪装成 HLS。不记录 Cookie、生产签名 URL 或敏感数据。
- 测试不依赖生产服务；真实 CDN、物理设备后台恢复只在实际有环境时验证，未验证明确记录。
- P0 工作者只负责 ResourceLoader、Range validator 和新建集成测试；评论工作者只负责评论文件与新建评论测试。下载切换在 P0 结果后进行。主控负责 L1、旧测试调用迁移、整合验证及文档。

## 步骤
- [x] 1–3：核对 Apple API、现有普通 dataTask/bytes=0-、Range 账本/下载记录的关系并解释。
- [x] 7：本地 HTTP/Range、缓存空洞、取消账本与本地完整文件播放的现有集成回归；修复 L2 `pread` 后未将字节响应给 `AVAssetResourceLoadingRequest` 的问题。
- [x] 4–6：评论布局采用 contentLabel 实际宽度（不使用 mainScreen）；Dynamic Type；composed-character 边界；prefix+suffix 最终 TextKit 三行约束；宽度/字体/内容变化失效；复用、RTL、ZWJ 边界回归。
- [x] 8a：background downloadTask、稳定 session identifier、taskDescription/任务状态持久化、重建 allTasks、AppDelegate 完成事件；取消 resumeData、恢复闸门和失效恢复数据的 fresh retry。
- [x] 8b：离线文件放 Application Support 并排除备份；完整文件导入、离线优先播放、旧完成缓存验证后复制迁移、删除离线资源和普通缓存/离线资源的清理边界。
- [x] 8c：L1 API 接受稳定 identity；ResourceLoader 与回归 fixture 统一该身份，覆盖签名 query 变化与 L1/L2 交错读取。
- [x] 9：完整 `NLSpotifyTests`、workspace build、模拟器启动 smoke，并更新 README、CLAUDE、架构/面试文档。

## 重点验收
- 系统临时下载文件在 delegate 返回前接管；取消/删除/旧任务完成不得复活下载。
- 任务重建与新任务准入不竞争；resumeData 不等同于自定义 Range ledger。
- 离线文件缺失/损坏不得标 completed；缓存清理与离线删除语义分开。
- 后缀实际布局三行内，前缀始终在原文 composed-character 边界；过窄容器也不越界。
- 不把历史 33/33 当作本次结果；不以登录页面启动替代真实音频 smoke。

## 实施与验证证据（2026-09-30）

- 新增/扩展回归：`NLOfflineAudioStoreTests`、`NLDownloadManagerBackgroundTests`、`NLCommentLayoutTests`、`NLAudioMemoryCacheTests` 及 `NLCacheManagerTests` 的 L1/L2 交错读取。
- 完整 `NLSpotifyTests`：58/58 passed，0 failed，0 runtime warning；iPhone 17 simulator（iOS 27.0）。
- `xcodebuild build -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify ...`：退出码 0。
- 重新安装并启动 `com.wutong.TL-PestIdentify` 后截图显示未登录登录页。未执行游客登录、真实音频、真实 CDN、真机后台 session 交付或已登录下载 UI。
- 不承诺用户 force-quit 后继续下载；`resumeData` 可能失效，失效时清除它并标记失败，用户可重新下载。
