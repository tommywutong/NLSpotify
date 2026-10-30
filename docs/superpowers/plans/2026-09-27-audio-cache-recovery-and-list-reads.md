# 音频缓存账本恢复与缓存列表后台查询实施计划
>
> **状态：已实施并验证（2026-09-28）。** 任务执行、回归测试、workspace build 和模拟器启动的历史证据记录在 `.superpowers/sdd/2026-09-27-audio-cache-recovery-and-list-reads/progress.md`；下方 checkbox 保留原始实施轨迹，不作为当前完成状态。


> **For agentic workers:** 使用 `superpowers:executing-plans` 逐任务实施；每个行为先写回归测试并观察失败，再改生产代码。未经 TommyWu 明确要求，不提交、不推送。

**Goal:** 在不改变 L1/L2/L3 文件格式与身份规则的前提下，恢复可确认完整的 rename 崩溃窗口，并避免缓存歌曲列表在主线程做批量 WCDB/文件查询。

**Architecture:** `NLCacheManager` 对账时仅在完整 Range 账本和 `.mp3` 文件长度都吻合的条件下恢复 `isFinished`；数据库修复失败时保留文件但不报告完整命中。音乐库缓存列表在 Utility 队列生成快照、把已查出的最近访问时间缓存到内存用于排序，再回主线程以现有 reload token/mode 检查结果。

**Tech Stack:** Objective-C/Objective-C++, Foundation, UIKit, WCDB, GCD, XCTest, Xcode workspace。

**Spec:** `docs/superpowers/specs/2026-09-27-audio-cache-recovery-and-list-reads-design.md`

## Global Constraints

- 保留现有缓存文件格式、身份规则、Range 账本与单首播放入口时序。
- 不新增内容摘要字段，不改 `NLAudioCacheInfo` schema，不扫描完整音频内容。
- 不重写 `rename` + WCDB 为跨系统事务；文件系统与 SQLite 之间不存在同一原子事务。
- 不调整缓存配额、LRU、Cache Key 或 Range 协议。
- 只处理缓存恢复和缓存歌曲列表查询，不改显式下载、播放器单首命中查询或其他音乐库列表。
- 保留用户已有工作区改动；不提交、不推送。

## Review Focus

1. **Range 空洞或文件长度不符**：不得仅因 `.mp3` 存在或长度匹配恢复完整状态；Task 1 分别覆盖不完整 Range 与 wrong-size 文件。
2. **修复 WCDB 失败**：文件可留待下次启动重试，但本次完整缓存查询必须返回未命中；Task 1 用 `BEFORE INSERT ... RAISE(ABORT)` 测试触发器覆盖失败路径。
3. **缓存目录读取错误**：不得把不可读目录/账本误判为空并批量删除；保持现有 early return，Task 1 回归原有 reconciliation guard。
4. **后台筛选期间切换模式/离开页面/再次 reload**：旧结果不得覆盖当前 UI；Task 2 覆盖。
5. **空列表与单首列表**：异步筛选/排序必须按现有空态和顺序语义应用，不访问空元素；Task 2 覆盖。

---

### Task 1: Recover completed audio after rename-before-ledger crash

**Files:**
- Modify: `NLSpotify/Modules/播放器/缓存/NLCacheManager.mm`
- Test: `NLSpotifyTests/NLCacheManagerTests.m`

**Interfaces:**
- Consumes: Existing `mergeRanges:totalLength:`, `ranges:coverTotalLength:`, `cacheFilePathForURL:cacheKey:`, `reconcileCacheDirectory`.
- Produces: `reconcileCacheDirectory` repairs a partial ledger only when `.tmp` is absent, `.mp3` exists, the ledger covers `[0,totalLength)`, and the file size equals `totalLength`.

- [ ] **Step 1: Add a deterministic reconciliation fixture.** Import `NLAudioCacheInfo+WCDB.h` and `NLDataBaseManager.h` in `NLCacheManagerTests.m`; declare the private `reconcileCacheDirectory` selector in the existing test category. Build a manager with a reconciliation block that waits on a semaphore, creates the audio-cache table through normal initialization, then calls `[cacheManager reconcileCacheDirectory]` after the test releases the semaphore. Before release, write the test `.mp3` and insert a unique `NLAudioCacheInfo` row with `isFinished = NO`, `totalLength = data.length`, and a serialized range covering the entire file. Derive the record's `urlMD5` from the basename returned by `cacheFilePathForURL:cacheKey:`; use a unique `songId` and delete that row and temporary directory in teardown.
  For the forced-write-failure fixture, also import `<WCDBObjc/WCTDatabase+Handle.h>` and create an alphanumeric UUID-derived `BEFORE INSERT` trigger on `AudioCacheInfoTable` that raises `ABORT` only for this `urlMD5` when `NEW.isFinished = 1`; drop the trigger and remove the fixture row/file during cleanup. Use a bounded semaphore wait and always signal it during test cleanup.

```objc
- (void)testReconcileRecoversRenamedAudioWithCompleteRangeLedger {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *entered = [self expectationWithDescription:@"reconciliation entered"];
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    NLCacheManager *manager = [[NLCacheManager alloc] initWithCacheDirectory:directory
        reconciliationBlock:^(NLCacheManager *cacheManager) {
            [entered fulfill];
            dispatch_semaphore_wait(resume, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
            [cacheManager reconcileCacheDirectory];
        }];
    [self waitForExpectations:@[entered] timeout:3];

    NSURL *url = [self uniqueURL];
    NSString *songID = NSUUID.UUID.UUIDString;
    NSString *cacheKey = [manager cacheIdentityForURL:url cacheKey:songID];
    NSData *audio = [@"recovered-audio" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = [manager cacheFilePathForURL:url cacheKey:cacheKey];
    XCTAssertTrue([audio writeToFile:path atomically:NO]);

    NLAudioCacheInfo *info = [[NLAudioCacheInfo alloc] init];
    info.urlMD5 = [[path lastPathComponent] stringByDeletingPathExtension];
    info.songId = songID;
    info.totalLength = (long long)audio.length;
    info.cachedRangesString = [NSString stringWithFormat:@"[{\"loc\":0,\"len\":%lu}]", (unsigned long)audio.length];
    info.isFinished = NO;
    info.lastAccessTime = 1;
    [[NLDataBaseManager sharedManager].database insertOrReplaceObject:info intoTable:@"AudioCacheInfoTable"];

    XCTestExpectation *ready = [self expectationWithDescription:@"reconciliation finished"];
    [manager whenReadyOnQueue:dispatch_get_main_queue() perform:^{ [ready fulfill]; }];
    dispatch_semaphore_signal(resume);
    [self waitForExpectations:@[ready] timeout:5];

    XCTAssertTrue([manager isFullyCachedForURL:nil cacheKey:songID]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], audio);
}
```

- [ ] **Step 2: Run the focused test and observe the expected failure.** Run the new test alone. Expected: the current reconciliation treats `.mp3` as an orphan for an unfinished ledger, deletes it, and `isFullyCachedForURL:nil cacheKey:songID` returns `NO`.
- [ ] **Step 3: Add invalid-ledger and wrong-size control tests.** For the ledger case, use an `.mp3` whose length equals `totalLength` but whose Range string covers only a strict prefix. For the length case, use a complete Range ledger but make the `.mp3` one byte shorter than `totalLength`. After reconciliation, both must remain misses; assert neither is reported complete, and assert the invalid orphan file follows the existing cleanup behavior.
- [ ] **Step 4: Verify failed WCDB repair preserves bytes but remains a miss.** Reuse the recovery fixture with the aborting trigger. After reconciliation, assert the `.mp3` still exists, the persisted row remains `isFinished == NO`, and `[manager isFullyCachedForURL:nil cacheKey:songID]` is `NO`; remove the trigger before fixture cleanup.
- [ ] **Step 5: Implement the narrow recovery branch.** For `isFinished == NO`, try the expected `.tmp` first as before. Only when it is absent, test the candidate `.mp3` using `totalLength > 0`, `ranges:coverTotalLength:` over parsed ledger ranges, and exact file-size equality. Set `isFinished = YES` and refresh `lastAccessTime` only after all checks. On successful WCDB replacement, add the identifier to the `known` set. If replacement fails, keep the candidate file in `known` so directory cleanup does not erase recoverable bytes, but leave the in-memory record unfinished and do not expose a complete-cache hit. Invalid candidates continue through the existing orphan-record/file cleanup path.
- [ ] **Step 6: Run all four recovery tests and the existing cache reconciliation/online/offline tests.** Expected: complete rename-window state is recovered byte-for-byte; incomplete-ledger, wrong-size, and database-write-failure cases remain misses; existing L1/L2/L3 and no-URL offline lookup tests pass.

### Task 2: Move cached-song list reads and sorting off the main queue

**Files:**
- Modify: `NLSpotify/Modules/音乐库/音乐库首页/NLMusicLibraryListViewController.m`（缓存查询依赖与后台快照）
- Test: `NLSpotifyTests/NLCacheManagerTests.m`
- Modify: `docs/项目深度梳理.md`

**Interfaces:**
- Consumes: Existing `cachedReloadToken`, `NLMusicLibraryListModeCachedSongs`, `NLCacheManager` synchronous queries and `whenReadyOnQueue:perform:`.
- Produces: Private `cacheManager` dependency initialized to `[NLCacheManager sharedManager]`; `cachedSongsSnapshot` performs repository/cache reads and sorts using in-memory recency values without UIKit access; a main-queue `applyCachedSongs:` validates token, mode and that `viewIfLoaded.window != nil` before touching UIKit.

- [ ] **Step 1: Add the behavior-preserving dependency seam and cache-manager fake.** Add a private `cacheManager` property to `NLMusicLibraryListViewController`, initialize it to `[NLCacheManager sharedManager]`, and route only the cached-list readiness/query call sites through it; do not change queue placement yet. Import `NLMusicLibraryListViewController.h` in `NLCacheManagerTests.m` and declare its private `loadData` selector in a test category. Add a `NLCacheManager` test subclass that records whether each `isFullyCachedForURL:cacheKey:` call is on main and returns a controlled result; initialize it with a unique cache directory and a no-op reconciliation block, wait for readiness, and for stale-result tests let it signal `entered` and wait on a bounded release semaphore. Override `lastAccessTimeForFullyCachedURL:cacheKey:` to record call count/thread and return fixed timestamps. Insert unique history songs through `NLSongRepository addPlayHistory:`, inject the fake into the controller, load the view, and attach it to a retained test `UIWindow`. Remove history rows with `removePlayHistoryWithSongId:`, close the window, and remove the temporary cache directory in cleanup.
- [ ] **Step 2: Characterize the main-thread regression.** Run a non-blocking fake-query test and assert the recorded cache-query thread is main; this test must fail only on its thread assertion after Step 1. Keep the fake non-blocking so the test runner can complete. The later blocked-query test must use a background watchdog to release its semaphore even when the old implementation blocks main.
- [ ] **Step 3: Move snapshot work to Utility and UI application to main.** Initialize and use the private `cacheManager` for cached-list readiness and query calls only. After ready, dispatch history/liked-song reads, complete-cache filtering, one cache identity/last-access lookup per included song, and sorting to `QOS_CLASS_UTILITY`; keep all those reads inside `cachedSongsSnapshot`. Store recency by stable song identifier before sorting so the comparator reads only memory. Dispatch the result to main, then re-check `cachedReloadToken`, `mode == NLMusicLibraryListModeCachedSongs`, and `viewIfLoaded.window != nil` before updating data-source properties, reloading the table, or changing empty-state UI. Do not move the separate player single-song hit query in this plan.

```objc
NSUInteger token = ++self.cachedReloadToken;
__weak typeof(self) weakSelf = self;
[self.cacheManager whenReadyOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) perform:^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;
    NSArray<NLSong *> *cachedSongs = [strongSelf cachedSongsSnapshot];
    __weak typeof(weakSelf) applyWeakSelf = weakSelf;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(applyWeakSelf) applySelf = applyWeakSelf;
        if (!applySelf || token != applySelf.cachedReloadToken ||
            applySelf.mode != NLMusicLibraryListModeCachedSongs || !applySelf.viewIfLoaded.window) return;
        [applySelf applyCachedSongs:cachedSongs];
    });
}];
```

- [ ] **Step 4: Prove queue responsiveness, stale-result rejection, and sort boundaries.** For queue responsiveness, block the fake's first cache query on Utility; a background watchdog queues a main-thread heartbeat, records whether it executes before releasing the query, then releases in `@finally`. After the refactor, the heartbeat must run while the query remains blocked. Add separate stale-result cases for a second cached reload, switching the mode, and `viewWillDisappear:`; release the first query last and assert its result cannot replace the current list. With deterministic fake results/timestamps, verify descending recency, exactly one `lastAccessTimeForFullyCachedURL:cacheKey:` call per included song, a one-song list is preserved, and an empty result shows the empty state without touching an absent row.
- [ ] **Step 5: Update the cache architecture summary.** In `docs/项目深度梳理.md`, state that rename-window recovery requires a full Range ledger and matching file size, and cached-song list repository/cache scanning and sorting run off-main with token-checked UI application. Preserve the warning that equal-length corruption is not detected and no cross-system transaction exists.
- [ ] **Step 6: Run the focused UI/cache-list tests and the full cache test class.** Expected: cache queries and last-access lookups report a Utility thread; the main queue heartbeat completes while the fake query remains blocked; all stale-result, ordering, empty-state and one-song assertions pass.

### Task 3: Full verification and simulator smoke

**Files:** no additional production files.

- [ ] **Step 1: Run the full test target.**

Run:

```bash
xcodebuild test -quiet -workspace "/Users/tommywu/Desktop/代码项目-其他/NLSpotify/NLSpotify.xcworkspace" -scheme NLSpotify -destination 'platform=iOS Simulator,id=96172410-F39D-44F8-9611-0DB6B408CCB7' -parallel-testing-enabled NO -only-testing:NLSpotifyTests
```

Expected: all collected `NLSpotifyTests` pass with zero failures.

- [ ] **Step 2: Build the app scheme.** Run `xcodebuild build -quiet` for the same workspace, scheme, and simulator destination. Expected: build exits 0.
- [ ] **Step 3: Launch the built app on the simulator.** Install the built `NLSpotify.app` with `xcrun simctl`, launch bundle ID `com.wutong.TL-PestIdentify`, capture a screenshot, and recapture after the launch transition. Expected: the unauthenticated app reaches its login root screen (or the home screen if authenticated state exists) and the app process remains running; do not perform login, playback, or CDN checks.
- [ ] **Step 4: Report verification boundaries.** Record test count/result, build result, and observed startup screenshot. State that equal-length corruption, physical-device playback and CDN behavior remain outside the guarantees of this design.
