# 音频缓存剩余设计边界收口实施计划

> **For agentic workers:** 使用原生执行方式按任务实施；每项先补回归测试，再修改生产代码；不提交、不推送。

**Goal:** 收口音频缓存版本身份、写入/清理并发、Range 去重和启动恢复四个边界，避免错误复用、幽灵清理和重复下载。

**Architecture:** 缓存身份由稳定 `songId` 与显式音频变体组成；没有变体时兼容旧 `songId` 身份。缓存写入统一经过 per-identifier serial queue，并用 generation/active-writer 保护清理。ResourceLoader 在单个 AVPlayer 请求范围内合并 L1、L2、L3 的已缓存区间，只对第一个缺口回源；后台对账等待现有缓存队列排空后执行，后续写入等待 reconcile barrier。

**Tech Stack:** Objective-C/Objective-C++, Foundation, AVFoundation, WCDB, XCTest, POSIX pread/pwrite。

**Spec:** 用户要求同步修复先前审查发现的四项剩余设计边界。

## Global Constraints

- 不修改 Cloudflare/D1/Vectorize 或生产配置。
- 不写入 API key、Cookie、token。
- 不改动与音频缓存/播放器/下载无关的用户工作区修改。
- 不提交、不推送、不改写历史。
- 保持 iOS 13+ 和现有 Objective-C/UIKit/WCDB 架构。

## Review Focus

- 同一 `songId` 的不同音频版本不得误命中旧正文；无版本字段的旧缓存保持兼容。
- 清理与分片写入、`.tmp` 晋级交错时不得删除当前写入对象或留下 WCDB/文件幽灵状态。
- L1/L2/L3 存在多个片段时，单次 AVPlayer 请求不得重复下载已覆盖区间，也不得跨空洞拼接。
- App 启动对账期间发生首个播放写入时，不得删除刚写入的文件或误删新建 WCDB 记录。
- 取消、清空缓存、切歌后迟到回调不得重新建立已失效的缓存所有权。

### Task 1: Stable cache identity

**Files:**
- Modify: `NLSpotify/Modules/播放器/缓存/NLCacheManager.h/.mm`
- Modify: `NLSpotify/Modules/播放器/NLPlayerManager.m`
- Modify: `NLSpotify/Modules/播放器/NLDownloadManager.m`
- Modify: `NLSpotify/Modules/音乐库/音乐库首页/NLMusicLibraryListViewController.m`
- Test: `NLSpotifyTests/NLCacheManagerTests.m`

**Contract:** 增加 `cacheVariant` 可选参数；旧 `cacheKey` 调用继续可用。`songId` 仍是无变体时的稳定标识，变体非空时 identity = `songId + "\n" + variant`。所有命中、写入、清理保护和排序调用必须使用同一 identity。

### Task 2: Writer ownership and cleanup

**Files:**
- Modify: `NLCacheManager.mm`, `NLResourceLoader.m`, `NLDownloadManager.m`
- Test: `NLCacheManagerTests.m`

**Contract:** `NLCacheManager` 为每个 identity 维护 active writer count/generation；清理和 clearAllCache 只在同一 identity queue 上删除，generation 失效迟到写入；清理候选在执行删除前再次检查 active writer/current playing/download ownership。

### Task 3: Range gap coalescing

**Files:**
- Modify: `NLResourceLoader.m`, optionally `NLAudioMemoryCache.h/.m`
- Test: `NLHTTPRangeValidatorTests.m` or a focused pure range helper test.

**Contract:** 将请求 `[offset, offset+length)` 与 L1/L2/L3 ranges 求并集；只对请求范围内第一个未覆盖区间发 Origin Range，响应完成后由 AVPlayer 再次请求后续缺口。已有连续前缀仍直接响应；不跨 gap 响应。

### Task 4: Reconcile barrier and regression tests

**Files:**
- Modify: `NLCacheManager.mm`
- Test: `NLCacheManagerTests.m`
- Docs: `docs/项目深度梳理.md`, `docs/面试技术亮点与优化点.md`

**Contract:** 初始化启动对账后台执行，但设置 reconcile barrier；首次写入等待 barrier 后再操作。对账只清理确认不属于 WCDB/active writer 的文件；完成后测试清理与写入竞态。

### Verification

- `xcodebuild test -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'platform=iOS Simulator,id=<booted>' -only-testing:NLSpotifyTests`
- `xcodebuild build-for-testing -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'generic/platform=iOS Simulator' -only-testing:NLSpotifyTests`
- `git diff --check`
- 不宣称真机播放或网络零回源，除非获得真实设备/抓包证据。
