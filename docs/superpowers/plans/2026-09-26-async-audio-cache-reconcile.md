# 音频缓存异步启动对账 Implementation Plan

> **For agentic workers:** 使用 `superpowers:executing-plans` 按任务实施；每个行为先补回归测试并观察失败，再改生产代码。本任务不提交、不推送。

**Goal:** 将音频缓存目录/WCDB 启动对账移出启动关键路径；对账完成前缓存读写、清理、播放、下载和缓存列表均异步等待就绪，并保留取消与 generation 语义。

**Architecture:** `NLCacheManager` 用异步单向 ready barrier 执行建表和对账；就绪回调总是投递到调用方指定队列。读 API 保持同步，但所有读调用方先过 barrier；写入、Range 合并、LRU 和清空在 ready 后通过统一 admission 队列准入，清空等待既有操作异步排空，清空期间的新操作延后。

**Tech Stack:** Objective-C/Objective-C++, Foundation, AVFoundation, WCDB, GCD, XCTest, Xcode workspace。

**Spec:** `docs/superpowers/specs/2026-09-26-async-audio-cache-reconcile-design.md`

## Global Constraints

- 保持 iOS 13+ 和现有 Objective-C/UIKit/WCDB 架构。
- 不改缓存格式、音频身份规则、LRU 配额、HTTP Range 校验策略或数据库路径。
- 不引入重试、遥测、缓存内容哈希或后台下载功能；文件 rename 与 WCDB 更新仍非跨系统事务。
- 不提交、不推送；不触碰无关工作区改动。
- 不使用 semaphore、`dispatch_group_wait` 或主线程轮询等待缓存 ready。
- 对账尝试结束时释放全部等待者；数据库/文件错误策略不扩展为重试。

## Review Focus

- 对账异常/缓存表创建失败时必须释放等待者，且不得把不可读账本误判成空账本并删除全部音频文件。
- ready 转换与并发登记回调交错时，同一目标串行队列的回调不得丢失或重复；ready 后调用也必须异步。
- `clearAllCache` 与等待中/已排队写入交错时，旧 generation 不复活，新 generation 写入不能被前一次清空误删。
- ResourceLoader 在 ready 回调排队期间取消或 invalidate 时，不得读取本地缓存、发起 Origin Range 或响应已取消请求。
- 快速切歌、停止播放、取消全部下载与 ready 同时发生时，旧 token/generation 不得创建播放器项、启动下载或释放新 reservation。

---

### Task 1: Cache manager readiness and mutation admission

**Files:**
- Modify: `NLSpotify/Modules/播放器/缓存/NLCacheManager.h`
- Modify: `NLSpotify/Modules/播放器/缓存/NLCacheManager.mm`
- Test: `NLSpotifyTests/NLCacheManagerTests.m`

**Interfaces:**
- Produces: `- (void)whenReadyOnQueue:(dispatch_queue_t)queue perform:(dispatch_block_t)block;`; callback 总是异步投递到指定 queue。
- Produces: 内部统一 cache-operation admission queue；所有写、Range 合并、完成晋级、访问时间更新、LRU 清理与清空在 ready 后准入，清空期间后续变更暂存。
- Consumes: 现有 8 条 identifier 串行队列、`activeWriteCounts`、`cacheGeneration`、`reconcileCacheDirectory` 与现有缓存 API。

- [ ] **Step 1: 写 manager readiness 回归测试**：在测试私有 category 声明可注入 cache directory 与 reconcile block 的 initializer；阻塞 reconcile block，通过两次 ready 注册、ready 前 `cacheData`、独立主队列任务，以及 ready 后的第二次注册验证 fan-in、无早写入和 ready 后也异步。补充 clear-before-ready 使旧 generation 写入不产生文件的测试。
- [ ] **Step 2: 运行上述 XCTest**：预期在 initializer/readiness API 不存在处编译失败；新增接口仅用于构造测试管理器，不改变共享单例 API。
- [ ] **Step 3: 实现异步初始化与 ready gate**：`init` 只初始化状态/队列/路径并投递 Utility 工作；后台创建目录、创建缓存表并执行对账；缓存表/目录准备失败时跳过破坏性对账；无论成功或失败都原子转 ready，并在锁内将 pending callbacks 异步投递到其队列。
- [ ] **Step 4: 实现 mutation admission/clear barrier**：为缓存变更增加统一串行 admission 队列与异步完成计数；清理工作计入在途操作，clear 先递增 generation、暂停后续变更、待既有操作完成后清理文件/WCDB/L1，再释放后续变更；将 cacheData、merge、finish、touch、partial/complete cleanup 接入 admission。所有完成/失败/过期路径都恰好结束一次。
- [ ] **Step 5: 运行 manager readiness、写入/清理与既有缓存 XCTest**：通过注入 reconcile 暂停观察 RED 用例变绿，并确认既有 L2/L3、离线命中、Range、late-write 用例通过。

### Task 2: ResourceLoader waits asynchronously and cancels pending requests

**Files:**
- Modify: `NLSpotify/Modules/播放器/缓存/NLResourceLoader.m`
- Modify: `NLSpotify/Modules/播放器/NLPlayerManager.m`
- Test: `NLSpotifyTests/NLCacheManagerTests.m`

**Interfaces:**
- Consumes: Task 1 `whenReadyOnQueue:perform:`。
- Produces: ResourceLoader 在 ready 前登记 pending loading request；ready 后才填 content information、读 L1/L2/L3 或创建 Range task；取消/invalidate 能移除 pending registration。

- [ ] **Step 1: 写 pending-request 取消回归测试**：用注入的阻塞 reconcile manager 启动 loader，提交一个需要本地/网络处理的 loading request，在释放 reconcile 前调用 `didCancelLoadingRequest:`；断言 request 未收到数据、未完成，且没有对应网络 task；释放 reconcile 后再次确认没有数据响应或 task。
- [ ] **Step 2: 运行该 XCTest**：预期当前 loader 在 `shouldWaitForLoadingOfRequestedResource:` 立即执行缓存查询/读取，测试失败。
- [ ] **Step 3: 将 loader 请求先登记后准入**：新增 pending request context map；ready completion 在 loader 的串行工作队列检查 cancelled/invalidated 并移除 pending 后才进入既有内容信息、本地读与网络缺口路径；`didCancelLoadingRequest:` 和 `invalidateAndCancelAll` 同时清除 pending 与活动 task；ready 等待期间不读取同步缓存 API。
- [ ] **Step 4: 运行 pending cancel 测试与全部 `NLCacheManagerTests`**：取消请求不得被本地响应或创建 URLSession task；既有 L1/L2/L3 拼接与回源路径继续通过。

### Task 3: Player and download readiness/token gates

**Files:**
- Modify: `NLSpotify/Modules/播放器/NLPlayerManager.m`
- Modify: `NLSpotify/Modules/播放器/NLDownloadManager.m`
- Test: `NLSpotifyTests/NLCacheManagerTests.m`

**Interfaces:**
- Consumes: Task 1 readiness callback；Task 2 ResourceLoader pending lifecycle。
- Produces: 播放器 ready callback 在主队列核验 `playSwitchToken` 后才执行离线查询、更新缓存进度或创建 AVPlayerItem；下载在 ready callback 核验原有 `downloadGeneration`/reservation 后才查询缓存、取 URL 或启动 task。

- [ ] **Step 1: 写等待期间 stop/切歌与下载取消回归测试**：使用阻塞 reconcile manager；在 ready 前调用播放入口后 `stop`，以及 `addDownloadForSong:` 后 `cancelAllDownloads`；释放 barrier 后断言无过期 player item、无活跃下载 reservation、无下载 task。
- [ ] **Step 2: 运行测试确认失败**：当前播放/下载入口在对账期间同步查询缓存，并会继续创建 AVPlayerItem 或 URLSession task。
- [ ] **Step 3: 迁移播放器与下载入口**：播放器先记录歌与 token，所有缓存查询在主队列 ready block 内执行并先核验 token；停止/切歌使 pending block 失效。下载先 reservation，ready block 再核验 generation 与 reservation；取消对等待中的 reservation 的释放由既有 `cancelAllDownloads` 完成，旧回调不得释放之后取得的新 reservation。缓存查询命中/未命中后沿用原有 URL 获取与下载流程。
- [ ] **Step 4: 运行目标用例、全部缓存 XCTest 与下载/播放器相关构建**：旧 token/generation 不创建副作用；ready 后已缓存歌曲仍可离线播放，未命中继续现有网络流程。

### Task 4: UI/cache cleanup consumers, docs, full verification

**Files:**
- Modify: `NLSpotify/Modules/音乐库/音乐库首页/NLMusicLibraryListViewController.m`
- Modify: `NLSpotify/Modules/播放器/播放器页面/NLMusicPlayerViewController.m`
- Modify: `NLSpotify/App/AppDelegate.m` only if startup cleanup still performs work outside admission.
- Modify: `docs/项目深度梳理.md`
- Modify: `docs/面试技术亮点与优化点.md`
- Test: `NLSpotifyTests/NLCacheManagerTests.m`

**Interfaces:**
- Consumes: Task 1 ready API and Task 3 token/selection behavior.
- Produces: cached-song list and player cache UI queries execute after ready; stale UI result is discarded when mode/controller/current song changes. Startup/background LRU requests are admitted without blocking launch or scene lifecycle.

- [ ] **Step 1: 更新调用方**：缓存列表 `loadData` 为 cached mode 增加递增请求 token，ready completion 校验 token/mode 后才读取、排序并刷新；全屏播放器的 cache-progress/fully-cached toast 查询在主队列 ready 后执行并核对当前歌曲；检查 AppDelegate/SceneDelegate 清理调用仅提交异步 admitted operation。
- [ ] **Step 2: 更新两份缓存说明**：记录启动异步目录/WCDB 对账、ready gate、调用方取消/token 语义；移除“启动同步完成扫描”的陈述。保持非本功能架构条目不变。
- [ ] **Step 3: 运行全部 `NLSpotifyTests` 与项目构建**：使用 active Xcode workspace/scheme 的可用 iOS Simulator；检查完整输出与退出状态。
- [ ] **Step 4: 模拟器 smoke**：启动应用并验证 `didFinishLaunching` 在对账未完成时仍能完成 UI 启动；执行缓存命中与待取消 Range 场景。若模拟器/真实网络不可用，分别报告实际覆盖与未能覆盖项，不推断真机/CDN 结果。
