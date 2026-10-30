# 核心可靠性设计：游客认证、离线下载与本地数据

> 状态：**Task 1–5 已实施；Task 6 本地测试/构建通过，运行验收未全部完成（2026-10-02）**。这是三阶段总体工作的第 1 份规格。内容发现（四类搜索、电台/节目）与产品入口（首页、音乐库、抽屉）另行形成规格，未从总体范围中删除。

## 目标

让现有“游客进入 → 选歌 → 播放/缓存 → 下载 → 离线播放”和本地音乐库链路，在失败、重启、并发回调和持久化错误下保持可解释且一致；不把状态字段或本地测试结果包装成真实 CDN/设备能力。

## 实施前事实与问题

- `NLAuthManager` 把 Cookie 与独立 `isLoggedIn` 布尔值放在 `NSUserDefaults`；根路由仅读取布尔值。登录页只有游客登录接通，其他入口返回“不支持”。
- `NLDownloadManager` 已使用 background `NSURLSessionDownloadTask`、稳定 session identifier、`taskDescription` 和独立离线正文；下载列表传 `-1.f` 进度且 cell 隐藏进度条，用户无法看到逐首进度或控制单项任务。
- `NLPlayListRepository` 的删除和加歌由多次 WCDB 写组成，未处于单一事务；部分写入返回值未检查。列表 UI 删除时忽略持久化失败仍先更新界面。
- `NLSongRepository` 以歌曲 ID 覆盖播放历史，没有最近播放时间；`NLPlayerManager` 在选中歌曲时同步写历史。
- 歌词自动切歌请求有歌曲 ID 检查，首次手动打开面板的回调没有检查。播放 URL 缺失或 URL 文本含 `403` 时会拼出另一条固定外链作为兜底。
- 编译输出含项目自身的废弃 API、nullability、未使用变量和未实现声明等 warning。`CC_MD5` 当前只用于缓存文件身份，不作为内容完整性或安全摘要。

## 设计

### 1. 游客认证与凭据迁移

- 保持游客模式，不新增真实账号、OAuth 或第三方登录。
- Cookie 由 Keychain 保存；`NLAuthManager` 是唯一读写入口。启动时一次性迁移旧 `NSUserDefaults` Cookie，只有 Keychain 写入成功后才删除旧值；迁移失败时保留旧值并返回可观察错误，不丢失已有会话。
- 登录态由本地 Keychain 凭据状态推导，不保留可能与 Cookie 分离的第二份真值；游客登录仅在响应含非空 Cookie 且 Keychain 写入成功后才进入主界面，否则保持未登录并显示失败。Cookie 是否仍被服务端接受继续由现有 401/301 刷新链路判定；刷新/重放失败按现有强制登出流程回到游客登录页。
- 移除或明确禁用实际不支持的邮箱、手机号、社交账号和注册入口；任何日志都不得包含 Cookie 原文。

### 2. 单项下载状态与交互

下载行展示持久化字节计数推导出的进度；服务端未提供可用总长度时显示不定进度，不显示伪造百分比。单项状态至少区分 `downloading`、`paused`、`failed`、`completed` 与可重试的 `cancelled`。

状态转移：

- `downloading → paused`：取消当前 download task 并保存有效 `resumeData`；只有恢复数据实际保存成功才显示“已暂停”。
- `paused → downloading`：优先以 `resumeData` 恢复；系统拒绝或恢复数据无效时清理该数据、标记 `failed` 并提示用户重试，不自动从头下载。用户明确重试时才以原始播放 URL 启动新任务。
- `failed/cancelled → downloading`：用户明确重试后启动新任务。
- `downloading → cancelled`：取消并清除该任务的恢复数据，但保留队列项供用户重试。
- `completed` 仅在离线正文成功导入且可读、下载队列状态与已下载歌曲记录在同一 WCDB 事务中提交成功后成立；单首删除仍只删除离线资源和该队列项。

逐项按钮通过下载管理器公开 API 操作；后台 session 重建期间的 pending/recovered 任务不得被重复启动。进度通知和文件账本更新不能使 delegate 队列等待主线程。

### 3. WCDB 事务、队列与播放历史

- 所有 Repository 写操作通过同一个数据库写队列串行提交；可能阻塞的列表读取在后台生成快照，UI 只在主线程应用结果。
- 歌单新增歌曲事务包含：确认歌单存在、写入歌曲实体、插入关系、更新封面；任何一步失败均回滚并向调用方返回失败。重复加入同一歌曲保持幂等。删除歌单在同一事务中删除歌单与关系；删除歌曲关系时，若其本地歌曲实体没有其他歌单引用，再清理孤立实体。
- UI 只有在 Repository 返回成功后才提交本地数组变化；失败显示可理解的错误且保留当前行。
- 不在通用 `NLSong` 中给所有表增加无关字段。新增以 `songId` 为主键的播放历史元数据，保存 `lastPlayedAt` 与 `playCount`；在当前播放真正进入 `Playing` 时，对同一 `playSwitchToken` 最多记录一次，避免仅点击但 URL/Item 失败的选歌被计为播放。
- 历史按 `lastPlayedAt` 降序、`songId` 升序稳定排序；现有 `PlaybackHistoryTable` 记录通过幂等 schema migration 保留。旧记录没有可恢复的播放时间，因此迁移为 `playCount = 1`、`lastPlayedAt = 0`，排在真实新播放记录之后；不伪造历史时间。统计口径是“播放启动次数”，不计算或宣称实际收听时长。
- 数据库迁移失败必须保留原数据并阻止把未迁移表当成新 schema 使用；迁移可安全重试。

### 4. 播放与歌词回调一致性

- 自动和手动歌词请求都捕获目标 `songId` 与请求 token；页面关闭、切歌或新请求产生后，旧回调不得覆盖当前歌词或提示当前歌曲失败。
- 对空 ID、无 URL、无效 URL、非 HTTP(S) URL 和上游拒绝播放的结果，`NLSongService` 返回明确失败；不通过 `absoluteString` 中是否包含 `403` 来判断 HTTP 状态，不静默拼造外链。
- 现有行级 LRC 能力保持不变；本规格只修回调竞态，不扩展逐字/翻译歌词格式。

### 5. 缓存身份与 warning 处理

- 新缓存身份使用带算法标识的 SHA-256；旧账本主键与文件名作为 opaque legacy identifier 原样迁移，不重算、不批量改名。具备 `songId` 的旧完整缓存仍可经账本查询并按已保存文件名播放；旧 partial/无稳定 `songId` 缓存不与新身份合并，保留到普通 LRU 回收，避免跨音质误拼 Range。
- 将 `urlMD5` 列迁移为语义明确的 `cacheIdentifier`，以新表/幂等拷贝保留旧记录与 Range 状态；新记录只写 SHA-256 身份。移除生产路径中的 `CC_MD5` 调用；不得以编译器 pragma 隐藏 warning 或清空旧离线正文。
- 不新增第三方依赖，不改远端 API、Cloudflare/D1/Vectorize 或生产配置。

## 非目标

- 不新增真实账号登录、OAuth、消息/社交功能、评论写操作、HLS、DRM 或用户强退后必然续传承诺。
- 不在本规格实现搜索、广播、电台节目、首页分类或音乐库艺人页面；这些属于后续已约定的独立规格。
- 不把文件系统与 SQLite 描述成同一个原子事务；依靠有序提交、恢复对账和可重试状态维持一致性。
- 不新增埋点/崩溃上报，不为没有测量证据的性能目标写数字。

## 验收标准

1. ✅ 旧 `NSUserDefaults` Cookie 迁移到 Keychain 后可重启读取；迁移写入失败保留旧凭据；登出后凭据与游客登录态清空；无日志泄漏 Cookie。证据：`NLAuthManagerTests`（跨实例 Keychain 持久化、迁移失败负例）。
2. ✅ 下载列表能显示真实/不定进度，并逐首暂停、继续、取消、重试、删除；暂停/恢复、无效 `resumeData`、任务重建、删除后迟到完成回调都不会伪造 `completed` 或复活条目。证据：`NLDownloadManagerBackgroundTests`、`NLOfflineAudioStoreTests`、`NLSongListCellTests`。
3. ✅ 歌单多表写入任一失败都无部分提交；重复加歌不重复关系；UI 失败时保留原状态；数据库 I/O 不在主线程执行。证据：`NLRepositoryMigrationTests`（SQLite trigger 注入失败回滚）。
4. ✅ 播放历史只对真正进入 `Playing` 的当前 token 计一次，按最近启动时间排序；旧数据库迁移后原歌曲记录保留。证据：`NLRepositoryMigrationTests` 的 token-once 与排序用例。
5. ✅ 手动打开歌词后切歌、关闭页面或发起新请求时，旧歌词回调不改变当前 UI。证据：`NLMusicPlayerViewControllerTests`。
6. ✅ 空/无效/被拒绝的播放链接进入明确错误状态，不请求拼接出来的替代 URL；现有有效 URL 播放路径不回归。证据：`NLSongServiceTests`、`NLResourceLoaderIntegrationTests`。
7. ✅ 现有 Range、L1/L2/L3、缓存对账、离线下载、评论布局测试全部继续通过；新增行为测试先失败后通过。证据：2026-10-02 完整 `NLSpotifyTests` 100/100 通过、0 runtime warning。
8. ✅ NLSpotify App 与测试 target 的项目自身编译 warning 清零（冷构建 xcactivitylog 扫描 0 条 `warning:` 诊断）；Pods 冷构建同样 0 条。缓存身份迁移覆盖旧完整缓存按 songId 离线命中及旧 partial 不跨身份复用（真实旧 schema 迁移 RED→GREEN）。
9. ✅ 已更新 README、项目深度梳理和面试亮点文档：删除“下一首预创建”的不实说法及阻塞式 `dispatch_group_wait` 建议，区分本地测试、模拟器、真实 API 与真机证据。
10. 模拟器运行验收部分完成：既有游客会话进入首页、歌单详情渲染、播放器时间推进、一次下载完成正文/账本提交已观察；暂停/继续/重试的 UI 状态转移、断网离线回放和历史列表顺序尚未验证。真实 CDN 回源不能仅由播放器进度证明；物理设备后台交付另行验证。

## 主要风险与验证边界

- Keychain 首次迁移与原登录态兼容必须先测试；不能因凭据转存失败而登出用户。
- background `resumeData` 由系统提供且可能失效；应用只承诺可呈现失败并重新下载。
- 缓存身份算法迁移会放弃旧 partial 缓存的 Range 复用，但不删除普通缓存文件、不影响独立离线下载正文；此代价必须由迁移测试固定并在项目文档说明。
- 下载正文、离线 JSON 账本和 WCDB 不是同一事务；完成顺序必须保持“正文导入并可读 → 下载队列状态与已下载歌曲记录在同一 WCDB 事务中提交”。中途失败时不能把记录标为完成，且恢复/重试不能重复或丢失已导入文件。
- 当前设备列表中没有显示物理 iPhone；实际设备验证仅在设备可用时执行。固定服务端目前只存在为客户端中的 URL，所需外部端点需单独验证；不得把端点不存在的问题用假响应掩盖。
