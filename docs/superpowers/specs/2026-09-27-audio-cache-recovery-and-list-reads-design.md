# 音频缓存账本恢复与缓存列表后台查询设计

> 状态：**已实施并验证（2026-09-28）**。实现见 `NLCacheManager.mm` 与 `NLMusicLibraryListViewController.m`；33/33 `NLSpotifyTests`、workspace build 和模拟器未登录启动的历史执行证据在 `.superpowers/sdd/2026-09-27-audio-cache-recovery-and-list-reads/progress.md`。本设计保留为决策与验证边界记录。

## 目标

- 修复“完整字节已 rename 为 `.mp3`、但 `NLAudioCacheInfo.isFinished` 尚未提交”时，下一次启动会无谓删除完整缓存的问题。
- 将缓存歌曲列表中的 WCDB/文件检查与排序从主线程移走；仅在主线程验证请求 token 并应用列表结果。
- 保留现有缓存文件格式、身份规则、Range 账本与单首播放入口时序；不引入缓存格式迁移或启动全量内容哈希。

## 当前实现事实

- `promoteURL:cacheKey:info:` 先 fsync `.tmp`，再 rename 为 `.mp3`，最后将 `isFinished` 写入 WCDB。若进程在 rename 后、账本更新前退出，账本仍显示 partial，`.tmp` 已不存在，而 `.mp3` 已存在。
- `reconcileCacheDirectory` 当前仅按 `isFinished` 选择 `.mp3` 或 `.tmp`；partial 记录找不到 `.tmp` 时会删除记录，之后把 `.mp3` 作为孤儿删除。这是完整缓存的可恢复丢失，不会产生错误命中。
- `isFullyCachedForURL:cacheKey:` 以 `isFinished`、`totalLength` 和文件大小相等作为有效性检查；缓存账本没有内容摘要。相同长度的静默内容损坏无法识别。
- 缓存歌曲列表在 ready callback 的主队列读取播放历史/喜欢列表，逐歌同步查询缓存，并在排序比较器重复读取 `lastAccessTime`。
- 项目没有发现可复用的 WCDB schema migration 路径。增加 SHA-256 字段会涉及旧缓存迁移与额外文件读取，不属于本设计。

## 设计决策

### 1. 恢复 rename 后尚未标记完成的缓存

在 `reconcileCacheDirectory` 遇到 `isFinished == NO` 且预期 `.tmp` 不存在时，检查对应 `.mp3`：只有当 `totalLength > 0`、已保存 Range 账本完整覆盖 `[0,totalLength)`、并且 `.mp3` 文件大小等于 `totalLength` 时，才把记录修复为 `isFinished == YES` 并保留该文件。

若任一条件不成立，沿用当前孤儿清理路径；不得仅凭 `.mp3` 存在或大小匹配就晋级。若 WCDB 修复写入失败，保留文件供下次启动再次尝试，但本次不得把记录作为完整缓存交给播放查询。

本恢复针对已持久化完整 Range 账本的进程崩溃窗口；不声称覆盖掉电造成的文件系统目录项持久化问题，也不声称检测同长度内容损坏。

### 2. 缓存列表在后台生成快照

- ready callback 投递到 Utility 队列后再读取历史/喜欢歌曲、筛选完整缓存与构建最近访问时间快照。
- 每个完整缓存候选只查询一次 `lastAccessTime`；排序比较器只访问内存值，不执行 WCDB/文件查询。
- 结果投递回主队列；应用前核对 reload token、列表模式和控制器仍在 view hierarchy 中，过期结果丢弃。
- 播放器单首命中查询保持现有主线程路径，避免在本设计里引入异步播放状态机和缓存文件被清理的 pin/ownership 语义。

## 非目标

- 不新增 SHA-256/CRC 字段，不改 `NLAudioCacheInfo` schema，不扫描完整音频内容。
- 不把所有播放器缓存查询、显式下载或其他音乐库列表统一改为后台 I/O。
- 不重写 `rename` + WCDB 为跨系统事务；文件系统与 SQLite 之间不存在同一原子事务。
- 不调整缓存配额、LRU、Cache Key 或 Range 协议。

## 验收标准

1. 模拟 rename 后账本仍为 partial 的完整缓存，在启动对账后仍可通过无 URL 的 songId 完整缓存查询，并且文件字节未改变。
2. 缺少完整 Range 覆盖、文件长度不符或账本修复失败时，不把文件报告为完整缓存；有效文件不得因失败而被错误删除。
3. 缓存列表的 repository、WCDB、文件检查与排序工作不在主线程执行；UIKit 状态仅在主线程应用。
4. 新列表请求、模式变化、页面消失时旧后台结果不得刷新页面。
5. 现有缓存 identity、L1/L2/L3 Range、ready gate、清空 generation、取消与离线命中测试继续通过。
6. 完整 `NLSpotifyTests`、workspace build 与模拟器启动 smoke 通过；不据此宣称真机/CDN 内容完整性。

## 验证重点

- 以隔离临时缓存目录和测试 WCDB 记录，构造 `.mp3` 已存在、完整 Range 账本已提交、`isFinished` 仍为 false 的崩溃状态，再运行对账。
- 对不完整账本、错误文件长度、WCDB 修复失败分别验证不得产生完整缓存命中。
- 对缓存列表后台查询设置确定性阻塞点，证明主队列仍能处理独立 UI 工作；释放查询后只允许当前 token 更新列表。
- 对 view 消失、模式切换和连续 reload 验证旧结果丢弃。
