# 音频两级磁盘缓存实现计划

> **For agentic workers:** 使用 executing-plans 在当前会话内逐任务执行；每个任务先写失败测试，再实现。

**Goal:** 将现有音频缓存明确实现为 L1 内存、L2 未完成 `.tmp`、L3 完整 `.mp3`、Origin 网络回源，并为 L2/L3 提供独立清理策略。

**Architecture:** `NLResourceLoader` 按 L1 → L2 `.tmp` → L3 `.mp3` → Origin 读取；网络数据写入 L1 与 L2，完整 Range 覆盖后以原子 rename 将 `.tmp` 晋级为 `.mp3`，不保留重复临时文件。`NLCacheManager` 负责每层容量与清理，WCDB 继续保存 Range 和完成状态。

**Tech Stack:** Objective-C/Objective-C++, Foundation `NSCache`, POSIX `pread/pwrite`, WCDB, XCTest, Xcode workspace。

**Spec:** 已获用户确认的对话设计：L1 内存、L2 `.tmp` 未完成磁盘、L3 `.mp3` 完整磁盘、Origin 网络。

## Global Constraints

- 不修改用户未点名的生产配置、Cloudflare/D1/Vectorize。
- 不改动与缓存链路无关的现有工作区改动。
- `.tmp` 完整后原子晋级为 `.mp3`，不保留同一首歌的重复正文。
- L1、L2、L3 分别拥有独立清理策略；当前播放资源受保护。
- L1 被淘汰不能影响正确性；L2/L3 删除后允许回源恢复。
- 不提交、不推送、不改写历史。

## Review Focus

- `.tmp` 晋级过程中并发写入/读取不能产生半成品 `.mp3`。
- L2 清理不能删除当前播放或正在写入的资源。
- L3 清理必须同步删除 WCDB 记录和建档标记，避免幽灵账本。
- L1 命中不足时必须继续查 L2/L3/Origin，不得把部分命中误判为完整命中。
- 同一首歌完整晋级后不能同时保留 `.tmp` 与 `.mp3` 两份正文。

---

### Task 1: 添加两级磁盘缓存行为测试

**Files:**
- Modify: `NLSpotifyTests/NLSpotifyTests.m` 或新增缓存管理测试文件
- Test: `NLSpotify/Modules/播放器/缓存/NLCacheManager.h/.mm`

**Interfaces:**
- Consumes: 当前 `NLCacheManager` 的临时文件、最终文件、Range、完成和清理接口。
- Produces: 明确的 L2/L3 清理接口与可验证的 `.tmp → .mp3` 状态转换。

- [ ] 写失败测试：完整 Range 后 `.tmp` 晋级为 `.mp3` 且 `.tmp` 不存在；L2/L3 清理边界分别生效。
- [ ] 运行指定 XCTest，确认因缺少分层清理/状态保证而失败。
- [ ] 只添加让测试表达缓存层契约所需的接口声明。
- [ ] 重新运行测试确认失败原因变为实际行为缺失而非编译错误。

### Task 2: 实现 L2/L3 文件状态与独立清理

**Files:**
- Modify: `NLSpotify/Modules/播放器/缓存/NLCacheManager.h`
- Modify: `NLSpotify/Modules/播放器/缓存/NLCacheManager.mm`
- Modify: `NLSpotify/Modules/播放器/缓存/NLResourceLoader.m`

**Interfaces:**
- Consumes: Task 1 的失败测试与现有 `cacheData:forURL:atOffset:totalLength:`、`finishCacheForURL:`、`cleanCacheWithMaxSize:`。
- Produces: `cleanPartialCacheWithMaxSize:`、`cleanCompletedCacheWithMaxSize:`；`cleanCacheWithMaxSize:` 作为两层清理编排；日志区分 L2/L3；`.tmp` 晋级后删除临时状态。

- [ ] 实现 L2 `.tmp` 和 L3 `.mp3` 独立容量统计与 LRU 清理。
- [ ] L2 清理优先删除未完成、非当前播放的临时文件；L3 清理只处理完整文件。
- [ ] 清理时同步移除 WCDB 记录、L1 分片和 `gEnsuredURLs` 标记。
- [ ] 完成晋级前在文件专属串行队列中验证临时文件存在，使用安全替换避免目标 `.mp3` 残留造成 move 失败。
- [ ] 更新 `NLResourceLoader` 日志与注释，将网络明确标为 Origin，将磁盘命中区分 L2/L3。
- [ ] 运行缓存测试与项目构建。

### Task 3: 回归验证与真机证据

**Files:**
- No new production files.
- Verify: `NLSpotifyTests/NLAudioMemoryCacheTests.m` and cache manager tests.

**Interfaces:**
- Consumes: Task 2 的分层缓存实现。
- Produces: 构建、单元测试、真机冷启动后的 L3 `.mp3` 命中证据。

- [ ] 运行 L1 现有测试和新增缓存管理测试。
- [ ] 构建 Xcode workspace。
- [ ] 在已连接 iPhone 上启动，播放已完整缓存歌曲，采集 `L3 complete disk hit`；再播放新歌采集 Origin→L1/L2 和晋级日志。
- [ ] 检查工作区变更仅包含本任务涉及文件；不提交或推送。

---
