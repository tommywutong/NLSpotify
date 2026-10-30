# 核心可靠性实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成游客 Cookie 安全迁移、单项后台下载交互、本地数据库一致性与历史排序、播放器错误/歌词竞态修复，并保留旧用户数据。

**Architecture:** 保留 Objective-C/UIKit、AFNetworking、ReactiveObjC、WCDB 与既有 L1/L2/L3 音频路径。WCDB 写入由一个串行写队列提交；外部网络与 UI 只通过异步结果交互。旧缓存 ID 作为 legacy opaque identity 迁移，新缓存写入以算法标识的 SHA-256 ID。

**Tech Stack:** Objective-C / Objective-C++、UIKit、WCDB.objc、CommonCrypto、NSURLSession、XCTest。

**Spec:** `docs/superpowers/specs/2026-10-02-core-reliability-design.md`

## Global Constraints

- 保持游客登录，不新增 OAuth、真实用户账号或第三方登录。
- Cookie 只存 Keychain；不得把 Cookie、签名 URL 或凭据写入源码、测试常量或日志。
- 不新增第三方依赖；不修改远端 API、Cloudflare/D1/Vectorize 或生产配置。
- 旧播放历史、已下载离线正文和可按 songId 命中的旧完整缓存必须保留；schema migration 幂等且可安全重试。
- 不承诺用户 force-quit 后下载继续；`resumeData` 失效时显示失败，用户明确重试才重开下载。
- 文件系统、离线 JSON 账本和 WCDB 不是一个原子事务；`completed` 只能在正文可读且必要的 WCDB 状态提交成功后成立。
- 应用和测试 deployment target 维持 iOS 26.1；Pods target 维持 Podfile 当前值。
- 在当前 NLSpotify workspace 原地工作；保留工作区既有改动；不执行 reset、commit、push 或远端发布。

## Review Focus

1. Keychain 写失败时，旧 defaults 凭据和游客入口是否仍可用；对应 Task 1 的迁移失败测试。
2. 暂停、删除与 `didFinishDownloadingToURL:`/`didCompleteWithError:` 交错时，任务不能被迟到回调复活；对应 Task 3 的 race tests。
3. WCDB 迁移中断或歌单写入中途失败时，原数据仍可读且无部分关系；对应 Task 2 的 legacy migration 与 SQLite trigger tests。
4. SHA-256 切换后旧完整缓存按 songId 可命中，旧 partial 不跨音质/URL variant 拼接；对应 Task 5 的 legacy cache tests。
5. 歌词手动首请求与 URL 失败回调跨切歌/关闭页面时不能覆盖当前状态；对应 Task 4 的 stale callback tests。

---

### Task 1: 游客凭据 Keychain 迁移

**Files:**
- Create: `NLSpotify/Networking/网易云API/Login && 双Token/NLKeychainCredentialStore.h`
- Create: `NLSpotify/Networking/网易云API/Login && 双Token/NLKeychainCredentialStore.m`
- Modify: `NLSpotify/Networking/网易云API/Login && 双Token/NLAuthManager.h`
- Modify: `NLSpotify/Networking/网易云API/Login && 双Token/NLAuthManager.m`
- Modify: `NLSpotify/Networking/网易云API/Login && 双Token/NLAuthService.m`
- Modify: `NLSpotify/Networking/网易云API/Login && 双Token/NLGuestLoginService.m`
- Modify: `NLSpotify/App/NLLoginViewController.m`
- Modify: `NLSpotify/App/SceneDelegate.m`

**Interfaces:**
- `NLKeychainCredentialStore` 提供按 service/account 读、写、删字符串凭据的薄封装；Keychain Security 调用仅在该类。
- `NLAuthManager` 提供 `currentCookie`、`setCookie:error:`、`migrateLegacyCookieIfNeeded:error:`、`logout` 和派生的 `isLoggedIn`；不保留独立 bool 真值。
- `NLGuestLoginService` 提供纯响应解析 `+cookieFromResponse:error:`；缺少非空 Cookie 时返回失败，不进入主界面。
- 测试使用独立 Keychain service 和随机生成的临时值；可注入失败 store，不写固定凭据字面量。

- [ ] **Step 1: 写迁移与登出失败测试**

```objc
- (void)testLegacyCredentialIsRemovedOnlyAfterKeychainWriteSucceeds;
- (void)testFailedMigrationKeepsLegacyCredentialUsable;
- (void)testMigrationFailsWhenKeychainReadFailsWithoutErrorOutput;
- (void)testGuestLoginResponseWithoutCookieIsRejected;
- (void)testLogoutRemovesKeychainAndLegacyCredential;
- (void)testKeychainCredentialPersistsAcrossStoreInstances;
```

`testFailedMigrationKeepsLegacyCredentialUsable` 断言 `currentCookie` 仍可读且 `isLoggedIn == YES`；不得只断言 mock 被调用。

- [ ] **Step 2: 运行测试观察预期失败**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests/NLAuthManagerTests`
Expected: 六项新测试因当前缺少 Keychain store/migration 行为失败；编译无错误，不能把编译失败当作预期 RED。
- [ ] **Step 3: 实现 Keychain store 与幂等迁移**

```objc
- (BOOL)migrateLegacyCookieIfNeeded:(NSError **)error;
- (BOOL)setCookie:(NSString *)cookie error:(NSError **)error;
```
先读 Keychain；只有 Keychain 写入成功后删除 `NSUserDefaults` 旧键。写失败时暂时从旧键读取，直到后续迁移成功。Keychain 错误仅返回给调用方，不包含凭据内容。

- [ ] **Step 4: 接入游客入口和启动路由**

游客登录响应缺少非空 Cookie、Keychain 写入失败时，不调用成功路由；移除或禁用邮箱、手机号、社交账号和注册按钮。根路由在访问登录态前先执行幂等迁移；失败时继续用保留的 legacy 凭据，不把用户错误登出。

- [ ] **Step 5: 聚焦测试转绿并跑完整测试目标**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests`
Expected: auth migration tests 与现有 `NLSpotifyTests` 全部通过；日志不含凭据原文。

### Task 2: WCDB 写队列、schema migration 与 Repository 原子性

**Files:**
- Create: `NLSpotify/Modules/WCDB/ORM模型/歌曲/NLPlaybackHistoryMetadata.h`
- Create: `NLSpotify/Modules/WCDB/ORM模型/歌曲/NLPlaybackHistoryMetadata.mm`
- Create: `NLSpotify/Modules/WCDB/ORM模型/歌曲/NLPlaybackHistoryMetadata+WCDB.h`
- Modify: `NLSpotify/Modules/WCDB/NLDataBaseManager.h`
- Modify: `NLSpotify/Modules/WCDB/NLDataBaseManager.mm`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLSongRepository.h`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLSongRepository.mm`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLPlayListRepository.h`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLPlayListRepository.mm`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLDownloadRepository.h`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLDownloadRepository.mm`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLAlbumRepository.h`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLAlbumRepository.mm`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLSearchRepository.h`
- Modify: `NLSpotify/Modules/WCDB/上层仓库/NLSearchRepository.mm`
- Modify: `NLSpotify/Modules/主页面/NLHomeViewController.m`
- Modify: `NLSpotify/Modules/播放器/NLPlayerManager.m`
- Modify: `NLSpotify/Modules/播放器/NLDownloadManager.m`
- Modify: `NLSpotify/Modules/播放器/播放器页面/NLMusicPlayerViewController.m`
- Modify: `NLSpotify/Modules/音乐库/音乐库首页/NLMusicLibraryListViewController.m`
- Modify: `NLSpotify/Modules/音乐库/创建的歌单/NLLikedSongsPickerViewController.m`
- Modify: `NLSpotify/Modules/音乐库/播放历史/NLRecentPlayViewController.m`
- Modify: `NLSpotify/Modules/音乐库/创建的歌单/NLUserPlayListDetailViewController.m`
- Modify: `NLSpotify/Modules/歌单详情页/Controller/NLSongListViewController.m`
- Modify: `NLSpotify/Modules/歌单详情页/Controller/NLAddToPlaylistSheetViewController.m`
- Test: `NLSpotifyTests/NLRepositoryMigrationTests.m`
- Modify: `NLSpotifyTests/NLCacheManagerTests.m` (migrate its Repository setup/cleanup calls)
- Modify: `NLSpotifyTests/NLDownloadManagerBackgroundTests.m` (migrate queue assertions and setup)

**Interfaces:**
- `NLDataBaseManager` 增加私有/内部测试可用的路径初始化与 schema migration 入口，并提供同一 writer queue 的单语句写与事务接口：

```objc
@class WCTDatabase, WCTHandle;
- (void)performWrite:(BOOL (^)(WCTDatabase *database))write
     completionQueue:(dispatch_queue_t)completionQueue
          completion:(void (^)(BOOL success))completion;
- (void)performWriteTransaction:(BOOL (^)(WCTHandle *transactionHandle))transaction
                completionQueue:(dispatch_queue_t)completionQueue
                     completion:(void (^)(BOOL success))completion;
- (void)performRead:(id _Nullable (^)(WCTDatabase *database))read
    completionQueue:(dispatch_queue_t)completionQueue
         completion:(void (^)(id _Nullable result))completion;
```
- `performRead` 在后台数据库队列生成读取快照，并将结果派发到调用方指定队列；UI caller 不在主线程同步读取 Repository。

- `NLPlaybackHistoryMetadata` 以 `songId` 为主键，字段为 `lastPlayedAt`、`playCount`。
- `NLSongRepository` 增加异步 `recordPlaybackStart:completion:` 与异步历史快照；`NLPlayListRepository` 增加异步、事务化的加歌/删歌/删歌单操作。旧同步导出 API 若被移除，先运行 LSP references 并迁移每个 caller，不留 shim。
- 下载队列完成 API 在同一 WCDB 事务内提交 queue `completed` 和 `DownloadedSongsTable` 歌曲记录；离线文件导入仍由 `NLDownloadManager` 在事务前完成。

- [ ] **Step 1: 查询 Repository API 引用并盘点 callers**

分别使用 LSP references 查询 `NLSongRepository`、`NLPlayListRepository`、`NLDownloadRepository`、`NLAlbumRepository`、`NLSearchRepository` 的导出写 API。若 Objective-C language server 不可用，记录工具失败，并以完整类名/方法名搜索补齐调用清单；不能假称 LSP 查询成功。调用文件清单见本 Task Files。

- [ ] **Step 2: 写旧库迁移、播放历史与事务失败测试**

```objc
- (void)testLegacyPlaybackRowsMigrateWithUnknownTimestamp;
- (void)testInterruptedHistoryMigrationCanRetryWithoutLosingLegacyRows;
- (void)testPlaybackStartIncrementsCountAndSortsByTimestamp;
- (void)testPlaybackStartIsRecordedOncePerPlayingToken;
- (void)testRepositoryWriteRunsOffMainAndCompletesOnRequestedQueue;
- (void)testPlaylistAddRollsBackSongAndRelationWhenRelationInsertFails;
- (void)testPlaylistAddIsIdempotent;
- (void)testPlaylistDeleteRemovesRelationsAndOnlyOrphanedSongs;
- (void)testDownloadCompletionCommitsQueueAndDownloadedSongTogether;
- (void)testDownloadCompletionFailureRollsBackQueueStatus;
```

旧数据迁移后的 `playCount` 为 1、`lastPlayedAt` 为 0；测试使用临时 SQLite 文件和 SQLite trigger 注入迁移/关系/完成写失败，并断言数据库真实行数/内容与 player token 行为。


- [ ] **Step 3: 运行迁移/事务测试观察预期失败**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests/NLRepositoryMigrationTests`
Expected: 因缺少 metadata schema/迁移与事务化 Repository API 失败。

- [ ] **Step 4: 实现版本化迁移和串行事务提交**

旧 `PlaybackHistoryTable` 记录保留；迁移可重复执行。WCDB 使用已安装 `WCTDatabase` 的 `runTransaction:`，事务 block 返回 `NO` 时回滚。所有 Repository mutation 通过同一 writer queue；completion 在调用方指定队列执行。

- [ ] **Step 5: 实现历史元数据、原子歌单操作与下载完成事务**

播放记录只在 `NLPlayerManager` 确认当前 token 首次进入 `Playing` 时异步写入；`lastPlayedAt` 同 token 只更新一次。加歌事务包括歌单存在性、歌曲、关系和封面；重复关系幂等；失败不改变调用方 UI。删歌单在同一事务删本体与关系，并按剩余引用清理孤立本地歌曲。

- [ ] **Step 6: 迁移 LSP 命中的 caller 到异步边界**

列表的 Repository/文件工作在后台执行，UIKit 只在主队列应用结果；所有 Repository 写 caller 根据成功回调后再更新 UI。不得在主线程同步等待 writer queue。

- [ ] **Step 7: 聚焦和完整测试目标转绿**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests`
Expected: migration 中断/重试、事务回滚、历史排序和原有 cache/download tests 全部通过。

### Task 3: 单项下载状态机与音乐库交互

**Files:**
- Modify: `NLSpotify/Modules/播放器/TabBar上方小播放器/NLDownloadManager.h`
- Modify: `NLSpotify/Modules/播放器/NLDownloadManager.m`
- Modify: `NLSpotify/Modules/播放器/NLOfflineAudioStore.h`
- Modify: `NLSpotify/Modules/播放器/NLOfflineAudioStore.m`
- Modify: `NLSpotify/Modules/WCDB/ORM模型/下载/NLDownloadItem.h`（仅新增非 WCDB transient progress 字段）
- Modify: `NLSpotify/Modules/音乐库/音乐库首页/NLMusicLibraryListViewController.m`
- Modify: `NLSpotify/Modules/歌单详情页/View/NLSongListCell.h`
- Modify: `NLSpotify/Modules/歌单详情页/View/NLSongListCell.m`
- Modify: `NLSpotifyTests/NLDownloadManagerBackgroundTests.m`
- Modify: `NLSpotifyTests/NLOfflineAudioStoreTests.m`
- Create: `NLSpotifyTests/NLSongListCellTests.m`

**Interfaces:**
- `NLOfflineAudioStore` 的 `recordTaskIdentifier:forSongID:resumeData:receivedBytes:expectedBytes:error:` 返回持久化成功状态；`NLDownloadManager` 增加逐首 `pauseDownloadForSongID:completion:`、`resumeDownloadForSongID:completion:`、`cancelDownloadForSongID:completion:`、`retryDownloadForSongID:completion:` 与异步 `loadDownloadItemsWithCompletion:`。
- `loadDownloadItemsWithCompletion:` 在后台合并队列项与 JSON 字节状态，返回的 `NLDownloadItem` 附带 transient `receivedBytes`/`expectedBytes`，不重复持久化 JSON 字节数。
- 通知 `NLDownloadManagerDidUpdateNotification` 的 `userInfo` 使用 `songId`、`status`、`receivedBytes`、`expectedBytes`；未知总长度时 UI 使用不定进度。完成事务消费 Task 2 的 Repository API。

- [x] **Step 1: 写暂停、恢复失败、重试和进度测试**

```objc
- (void)testPausePersistsResumeDataBeforeReportingPaused;
- (void)testInvalidResumeDataReportsFailureWithoutStartingAnotherTask;
- (void)testExplicitRetryAfterResumeFailureStartsFreshTask;
- (void)testUnknownExpectedBytesDoesNotReportFraction;
- (void)testDeleteDuringDownloadCannotResurrectQueueOrOfflineFile;
- (void)testDownloadCellShowsProgressOnlyWhenExpectedBytesAreKnown;
```

测试断言可观察状态、队列记录、任务数和离线文件；不只断言通知发送。

- [x] **Step 2: 运行下载状态测试观察预期失败**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests/NLDownloadManagerBackgroundTests`
Expected: 新增的逐首控制/恢复失败断言失败；现有任务重建测试仍可执行。

- [x] **Step 3: 实现单项任务命令与状态提交顺序**

暂停时先得到并持久化 `resumeData`，成功后才显示 paused；失败恢复只清理无效数据并标 failed，不自动消耗流量重下。用户明确重试后无恢复数据才创建新 download task。删除/暂停期间旧 generation 的回调不得提交完成。

- [x] **Step 4: 为列表提供真实快照与逐首操作**

初始行数据与进度在后台组装；通知只更新匹配 `songId` 的可见 cell。展示下载中进度/不定进度、暂停、失败、取消、完成；提供与当前状态匹配的暂停/继续/重试/取消/删除操作。`completed` 同时要求离线正文可读及 Task 2 完成事务成功。

- [x] **Step 5: 运行下载、离线存储和完整测试目标**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests`
Expected: 所有状态转移、旧任务竞态、离线所有权和已有 Range tests 全部通过。

### Task 4: 播放 URL 错误与歌词请求竞态

**Files:**
- Modify: `NLSpotify/Networking/网易云API/音乐播放Url/NLSongService.h`
- Modify: `NLSpotify/Networking/网易云API/音乐播放Url/NLSongService.m`
- Modify: `NLSpotify/Modules/播放器/播放器页面/NLMusicPlayerViewController.m`
- Create: `NLSpotifyTests/NLSongServiceTests.m`
- Create: `NLSpotifyTests/NLMusicPlayerViewControllerTests.m`

**Interfaces:**
- `fetchPlayableURLWithSongId:success:failure:` 只对非空、可解析 HTTP(S) URL 调用 success；通过纯解析方法 `+playableURLFromResponseObject:error:` 测试响应映射。空链接、非 HTTP(S)、无效文本和上游拒绝响应以可断言 NSError 调用 failure，不拼接外链。
- 歌词请求捕获目标 `songId` 和递增 request token；关闭歌词面板、切歌或发起更新请求都会使旧 token 失效。

- [x] **Step 1: 写 URL 解析失败与旧歌词回调测试**

```objc
- (void)testMissingPlayableURLReturnsFailureWithoutConstructingFallback;
- (void)testNonHTTPSPlayableURLIsRejected;
- (void)testHTTPSPlayableURLWhosePathContains403IsAccepted;
- (void)testStaleManualLyricResponseCannotReplaceCurrentSong;
```

歌词测试驱动实际 view/controller 状态更新，不只测试独立 token 整数比较。

- [x] **Step 2: 运行测试观察预期失败**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests/NLSongServiceTests -only-testing:NLSpotifyTests/NLMusicPlayerViewControllerTests`
Expected: 当前 fallback 和首次手动歌词回调行为触发失败断言。

- [x] **Step 3: 移除 URL 文本 `403` 启发式和固定外链拼接**

验证响应 dictionary、URL 类型、scheme 与 host；失败返回具有错误域/码的 NSError。保持有效播放 URL 与 Range ResourceLoader 路径不变。

- [x] **Step 4: 给所有歌词入口加同一代次校验**

手动打开、自动切歌、失败提示均在主队列应用前验证当前 song ID、request token 与页面状态；过期回调无副作用。

- [x] **Step 5: 聚焦测试与完整测试目标转绿**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests`
Expected: 新行为测试及现有 ResourceLoader/音频 fixture tests 全部通过。

### Task 5: 缓存身份迁移与项目 warning 清理

**Files:**
- Modify: `NLSpotify/Modules/播放器/缓存/NLCacheManager.h`
- Modify: `NLSpotify/Modules/播放器/缓存/NLCacheManager.mm`
- Modify: `NLSpotify/Modules/WCDB/ORM模型/歌曲/NLAudioCacheInfo.h`
- Modify: `NLSpotify/Modules/WCDB/ORM模型/歌曲/NLAudioCacheInfo.mm`
- Modify: `NLSpotify/Modules/WCDB/ORM模型/歌曲/NLAudioCacheInfo+WCDB.h`
- Modify: `NLSpotify/Modules/WCDB/NLDataBaseManager.mm`
- Modify: `NLSpotifyTests/NLCacheManagerTests.m`
- Modify: `NLSpotifyTests/NLSpotifyTests.m`（删除 Xcode template 的空 `testExample` 和 `testPerformanceExample`）
- Warning cleanup file: `NLSpotify/Networking/网易云API/Login && 双Token/NLGuestLoginService.m`
- Warning cleanup file: `NLSpotify/Networking/网易云API/Login && 双Token/NLAuthService.m`
- Warning cleanup file: `NLSpotify/Modules/搜索页面/Controller/NLSearchViewController.m`
- Warning cleanup file: `NLSpotify/Networking/网易云API/JJAlbum/NLSingerAlbumListService.m`
- Warning cleanup file: `NLSpotify/Modules/搜索页面/该品类精选歌单/NLPlayListsViewController.m`
- Warning cleanup file: `NLSpotify/App/NLLoginViewController.m`
- Warning cleanup file: `NLSpotify/Modules/音乐库/创建的歌单/NLLikedSongsPickerViewController.m`
- Warning cleanup file: `NLSpotify/Modules/歌单详情页/View/NLSongListHeaderView.m`
- Warning cleanup file: `NLSpotify/Modules/音乐库/创建的歌单/NLCreatePlayListSheetViewController.m`
- Warning cleanup file: `NLSpotify/Modules/歌单详情页/Controller/NLAddToPlaylistSheetViewController.m`
- Warning cleanup file: `NLSpotify/Modules/歌单详情页/Controller/NLSongListViewController.m`
- Warning cleanup file: `NLSpotify/Modules/播放器/播放器页面/NLMusicPlayerViewController.m`
- Warning cleanup file: `NLSpotify/Modules/播放器/播放器页面/NLMusicPlayerView.m`
- Warning cleanup file: `NLSpotify/Modules/播放器/TabBar上方小播放器/NLMusicPlayerAccessoryViewController.h` and `.m`
- Warning cleanup file: `NLSpotify/Modules/主页面/NLHomeViewController.m`

**Interfaces:**
- 缓存账本主键改为 `cacheIdentifier`；新值为 `sha256-<lowercase hex>`。迁移创建 `AudioCacheInfoTable_v3`，在单个 WCDB 事务中将旧 `urlMD5` 值原样复制为 legacy ID，并复制 `songId`、长度、Range JSON、访问时间和完成状态；校验行数后切换查询表并删除旧 metadata 表，音频文件名不重算。
- 已完成旧缓存按 `songId` 查账本并使用账本保存的旧文件名；旧 partial 与新 SHA 身份不合并。独立离线下载正文不参与此迁移。

- [x] **Step 1: 写 SHA 身份和 legacy 完整缓存测试**

```objc
- (void)testNewCacheIdentifierUsesSHA256PrefixAndStableIdentity;
- (void)testLegacyCompleteCacheRemainsPlayableBySongIDAfterMigration;
- (void)testLegacyPartialRangeIsNotMergedIntoDifferentVariant;
```

断言旧完整文件字节未变、旧行主键被保留、新请求使用新 ID 且不会把不同音质 Range 拼接。

- [x] **Step 2: 运行迁移测试观察预期失败**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests/NLCacheManagerTests`
Expected: 当前算法仍写 MD5，且模型字段名/新旧表迁移未满足断言。

- [x] **Step 3: 实现幂等缓存账本迁移和 SHA-256 新身份**

迁移在事务中复制 metadata 与 `cachedRangesString`，不批量改名文件；完成记录按 `songId` 继续读取旧文件路径。新 Range 请求使用 `CC_SHA256` 与 algorithm prefix；旧 partial 不命中新身份，按既有 partial LRU 回收。移除 production path 中 `CC_MD5`。

- [x] **Step 4: 修复同一构建发现的项目 warnings**

传 `@{}` 替代违反 nonnull 的 `nil` 参数，删除未用局部变量；删除/实现 accessory controller 未实现声明；将 deprecated UIKit API 改为当前 view/window scene 上下文 API 与 block animation；修正 `updateCoverURL:` nullable 合约。不得用 pragma blanket suppression。

- [x] **Step 5: 聚焦/完整测试、构建并读取 diagnostics**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests && xcodebuild build -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39'`
Expected: tests pass；NLSpotify App 与 test target 的项目 warning 为 0，Pods 外部 warning 单独列出。

### Task 6: 文档同步与最终运行验收

- Modify: `README.md`
- Modify: `docs/项目深度梳理.md`
- Modify: `docs/面试技术亮点与优化点.md`
- Modify: `docs/superpowers/specs/2026-10-02-core-reliability-design.md`（更新状态与验证证据）
- Modify: `docs/superpowers/plans/2026-10-02-core-reliability.md`（记录实际执行结果）

- [x] **Step 1: 更新实现事实与验证边界**

删除“下一首 AVPlayerItem 预创建”的错误描述和阻塞式 `dispatch_group_wait` 建议；更新游客 Cookie Keychain、下载逐项交互、历史排序/迁移、SHA legacy cache、URL 错误及歌词 race 的实现状态。未在真实 CDN/物理设备跑过的路径仍标未验证。

- [x] **Step 2: 运行完整测试和 workspace build**

Run: `xcodebuild test -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests && xcodebuild build -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39'`
Expected: 所有测试通过，应用构建完成，无项目 warning。

- [ ] **Step 3: 在模拟器运行真实 UI 路径**

使用 Xcode device-interaction workspace session 安装运行；实际操作游客登录、切歌播放、单首下载暂停/继续/重试、完成后断网离线播放、最近播放排序；捕获层级和截图。真实后台交付只在可用物理设备上验证，不以模拟器代替。

- [ ] **Step 4: 验证真实端点并记录边界**

通过模拟器执行一次正常游客登录（该既有产品流程会在远端创建游客会话）；避免重复注册、批量探测或任何写配置操作。仅验证本阶段包含的游客认证、播放 URL/CDN 请求；搜索与电台属于后续独立规格，不在本计划中声称已验证。任何 unavailable endpoint、远端错误或物理设备缺失都逐项记录为外部阻塞，不能用 fixture 结果声称真实服务成功。

### Task 6 执行记录（2026-10-02）

- Step 2：`xcodebuild test -quiet -parallel-testing-enabled NO ... -only-testing:NLSpotifyTests -resultBundlePath /tmp/NLSpotifyTask6Tests.xcresult` → Passed，100/100，0 failures，0 runtime warnings（xcresulttool 复核）；随后 `xcodebuild build -quiet` exit 0（`TASK6_STEP2_OK`）。
- Step 3：部分完成。设备交互子代理两次因上游 `403 SUBSCRIPTION_NOT_FOUND` 无法启动；按用户指示在主会话内用 device-interaction session 完成有限探测：既有游客会话进入首页 TabBar；首页真实推荐内容与歌单详情可见；点《那时雨》进入全屏播放器并观察到 0:13/0:30、Slider 43%、pause 按钮；切到《冷雨夜》后播放器显示 0:00/0:00、play 按钮；More → Sheet 提供「取消/下载」，点「下载」后完成正文与数据库记录。未完成：暂停/继续/重试状态转移、断网离线播放、最近播放列表 UI 排序；设备交互工具多次返回 `applicationState=NotRun`，但同时给出运行进程层级，已报告工具状态不一致。
- Step 4：部分完成。模拟器日志与数据容器显示 `/song/url` HTTPS 请求、NLOfflineAudio 正文写入；`downloads.json` 的 `receivedBytes=expectedBytes=481115`，`DownloadQueueTable` 为 `completed`，`DownloadedSongsTable` 有《冷雨夜》。这证明本次模拟器下载链路到正文/账本提交；不证明断网离线回放、暂停/重试，真机后台交付仍无物理设备。

## 执行说明

任务按依赖顺序串行执行：Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6。Task 2 的事务完成接口由 Task 3 消费；Task 2 的 migration 基础由 Task 5 扩展。所有新测试先运行并观察预期失败，再写 production code；每个 Task 结束运行完整 `NLSpotifyTests`。不创建 commit，不 push。
