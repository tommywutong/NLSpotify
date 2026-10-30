# NLSpotify 文档入口

## 快速接手路径

1. 先读根目录的 [README.md](../README.md) 了解项目范围和运行入口。
2. 再读[本文](README.md)，按问题定位到对应事实与源码入口。
3. 随后读[项目深度梳理](项目深度梳理.md)。它的源码对齐日期是 2026-10-11；若与源码冲突，以源码为准。
4. 需要协作规则时读根目录的 [CLAUDE.md](../CLAUDE.md)；需要面试表达时最后读[面试技术亮点与优化点](面试技术亮点与优化点.md)。面试文档里的优化建议不是已实现行为。

## 权威级别

按以下优先级处理信息冲突：

1. **源码**；
2. **当前事实文档与本文入口**；
3. 根 [README.md](../README.md) 与 [CLAUDE.md](../CLAUDE.md) 的协作摘要；
4. [面试技术亮点与优化点](面试技术亮点与优化点.md)；
5. superpowers 的历史 spec、计划和过程记录。

历史计划记录的是当时的设计或实施过程，**不等于当前实现**；修改前以当前源码为准。

## 当前事实入口

以[项目深度梳理](项目深度梳理.md)为当前源码事实的链路化阅读入口。按问题进入以下七条链路：

- **启动与认证：** [App 生命周期](../NLSpotify/App/)；[网络与认证](../NLSpotify/Networking/网易云API/)。
- **内容发现：** [首页](../NLSpotify/Modules/主页面/)、[搜索](../NLSpotify/Modules/搜索页面/) 和 [广播](../NLSpotify/Modules/Advertise/)。
- **播放：** [NLPlayerManager](../NLSpotify/Modules/播放器/NLPlayerManager.m)。
- **缓存：** [NLResourceLoader](../NLSpotify/Modules/播放器/缓存/NLResourceLoader.m) 与 [NLCacheManager](../NLSpotify/Modules/播放器/缓存/NLCacheManager.mm)。
- **下载：** [NLDownloadManager](../NLSpotify/Modules/播放器/NLDownloadManager.m) 与 [NLOfflineAudioStore](../NLSpotify/Modules/播放器/NLOfflineAudioStore.m)。
- **WCDB：** [数据库管理器、仓库和 ORM](../NLSpotify/Modules/WCDB/)。
- **歌词与评论：** [歌词播放页](../NLSpotify/Modules/播放器/播放器页面/NLMusicPlayerViewController.m) 与 [评论模块](../NLSpotify/Modules/评论区/)。

## 按任务查找

| 问题类型 | 先读 | 关键源码入口 |
| --- | --- | --- |
| 启动、登录态、401/301 恢复或根路由 | [项目深度梳理](项目深度梳理.md)的启动认证链路 | [NetWorkManager / NLAuthManager 所在网络层](../NLSpotify/Networking/网易云API/)；[App](../NLSpotify/App/) |
| 首页、搜索、艺人、歌单或广播内容 | [项目深度梳理](项目深度梳理.md)的内容发现链路 | [主页面](../NLSpotify/Modules/主页面/)、[搜索页面](../NLSpotify/Modules/搜索页面/)、[广播](../NLSpotify/Modules/Advertise/) |
| 切歌、播放状态、播放列表或系统媒体控制 | [项目深度梳理](项目深度梳理.md)的播放链路 | [NLPlayerManager](../NLSpotify/Modules/播放器/NLPlayerManager.m) |
| Range、普通缓存、文件晋级或启动对账 | [项目深度梳理](项目深度梳理.md)的缓存链路 | [NLResourceLoader](../NLSpotify/Modules/播放器/缓存/NLResourceLoader.m)；[NLCacheManager](../NLSpotify/Modules/播放器/缓存/NLCacheManager.mm) |
| 后台任务、暂停恢复、离线正文或下载状态 | [项目深度梳理](项目深度梳理.md)的下载链路 | [NLDownloadManager](../NLSpotify/Modules/播放器/NLDownloadManager.m)；[NLOfflineAudioStore](../NLSpotify/Modules/播放器/NLOfflineAudioStore.m) |
| 本地实体、关系、事务或迁移 | [项目深度梳理](项目深度梳理.md)的 WCDB 链路 | [WCDB](../NLSpotify/Modules/WCDB/) |
| 行级歌词、评论分页或文本折叠 | [项目深度梳理](项目深度梳理.md)的歌词评论链路 | [NLMusicPlayerViewController](../NLSpotify/Modules/播放器/播放器页面/NLMusicPlayerViewController.m)；[评论模块](../NLSpotify/Modules/评论区/) |

## 证据标签

- **源码事实：** 当前工作区源码直接可见的行为和调用关系。
- **本地历史测试证据：** 已记录的本地 XCTest、result bundle 或 build 结果；不是本轮重新执行的结论。
- **真实端点只读探测：** 历史计划中的只读请求记录；2026-10-11 没有重放，也不等于完整 UI 或真机验收。
- **未验证边界：** 缺少稳定的模拟器、真机、真实 CDN 或系统后台交付证据的范围。

## 修改前检查

- 回到对应源码，确认行为仍与当前事实文档一致。
- 确认职责所有权层与全部调用方，再决定修改位置。
- 不把面试建议、优化设想或历史计划直接当成已实现行为。

## 历史材料

[设计 spec](superpowers/specs/)、[实施计划](superpowers/plans/)和[superpowers SDD 过程记录](../.superpowers/sdd/)只用于理解设计与实施过程；它们不替代当前源码和当前事实文档。

## 文档整理边界

当前接手文档已按 2026-10-11 工作区源码校准。`docs/superpowers/` 和 `.superpowers/sdd/` 是历史过程记录，不代表当前实现。本轮没有运行 App、XCTest 或真实 API。
