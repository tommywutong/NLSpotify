# 音频缓存异步启动对账与就绪门控设计

> 状态：已由 TommyWu 批准（2026-09-26）；按本文范围实施。

## 目标

- `NLCacheManager` 启动时不在 `didFinishLaunching` 调用栈扫描缓存目录/WCDB。
- 对账未完成时，读、写、清理、播放器、下载和缓存列表操作都异步等待就绪，不同步阻塞主线程或工作队列。
- 对账完成前不写缓存文件；对账完成后继续复用现有 per-identifier 串行队列、写入所有权计数与缓存身份。
- 保持离线缓存命中、切歌 token、下载 generation、Range 补洞及取消行为；旧回调不得在等待期间失效后执行。

## 当前事实

- `AppDelegate.application:didFinishLaunchingWithOptions:` 首次调用 `NLCacheManager.sharedManager`。
- 当前 `init` 同步建缓存表并调用 `reconcileCacheDirectory`；后者读取全部缓存账本，逐条检查文件，再枚举目录并删除孤儿文件。
- 多个缓存读取 API 同步返回；`NLPlayerManager`、`NLResourceLoader`、`NLDownloadManager`、音乐库和播放器 UI 直接调用。
- 曾试过后台对账后在缓存队列中 `dispatch_group_wait(..., DISPATCH_TIME_FOREVER)`；Thread Performance Checker 报告优先级反转。最终必须使用异步准入，不恢复同步等待。

## 设计

### 1. 单向就绪状态

`NLCacheManager` 初始化只创建轻量状态、缓存目录和对账 barrier，然后在 Utility 队列完成缓存表准备与 `reconcileCacheDirectory`。状态由 `reconciling` 单向切换为 `ready`；完成回调必须异步投递到调用方指定队列。所有路径都不得用 semaphore、`dispatch_group_wait` 或主线程轮询等待。

新增一个就绪准入 API：调用方指定 callback queue 与 block。对账完成前 block 暂存；完成后投递到指定队列。已 ready 时也异步投递，避免调用方依赖“有时同步、有时异步”的时序；不同 callback queue 之间不承诺执行顺序，同一 identity 的实际缓存操作仍由现有串行队列排序。准入 block 只允许短操作；播放器/资源加载的后续异步工作仍走其既有队列。

### 2. 缓存读取和调用方准入

保留当前同步查询实现，避免把每个 WCDB 查询改造成独立 completion API；但所有依赖缓存结果的调用方必须先通过就绪准入 API，再执行同步查询。不得在 `reconciling` 状态直接查询、返回“未命中”或启动回源。

- `NLPlayerManager`：先登记当前选曲意图；就绪回调核对 `playSwitchToken` 后再检查离线缓存或取播放 URL。等待期间的新切歌使旧意图失效。
- `NLResourceLoader`：将 AVPlayer 请求登记为 pending，再等待就绪；就绪后在资源加载器串行 delegate queue 上读取 L1/L2/L3 并启动缺口请求。等待期间收到取消时移除 pending 请求，不启动网络任务、不响应已取消请求。
- `NLDownloadManager`：在现有 song-ID reservation 与 download-generation 语义内等待；就绪后再检查完整缓存或开始获取 URL/下载。取消或 generation 变化时丢弃待执行操作并释放 reservation。
- 音乐库缓存列表：缓存筛选与排序在就绪后执行；回调前若列表模式或控制器状态已变化，不应用旧结果。
- 播放器缓存进度等读取：在就绪回调所在 UI 队列执行；切歌 token 不匹配时丢弃旧更新。

缓存身份计算和纯路径拼接不依赖 WCDB，可保持同步；任何从账本解析缓存文件路径的操作仍需等待就绪。

### 3. 写入、清理与清空

所有异步写入、Range 合并、完成晋级、访问时间更新、LRU 清理和清空请求均通过同一就绪准入机制排队；不占用线程等待 barrier。

- 每个缓存 identity 仍使用原串行队列；active-writer count 在登记准入操作时增加，并在成功、失败、generation 过期等所有结束路径递减。
- 对账只在所有缓存写入尚未执行时运行；就绪后排队的写入不会被启动扫描当作孤儿删除。
- LRU 删除继续在 identity 队列执行，并在删除临界区检查活动写入所有权。

`clearAllCache` 将清空请求纳入有序准入：递增 generation 使清空前尚未执行的写入失效，等待已开始的 identity 队列操作完成，再删除文件、WCDB 记录和 L1。清空完成前到达的新写入暂存到清空之后执行；清空 completion 表示清空前内容已移除，不会误删清空后登记的新写入。

### 4. 通知与错误语义

提供就绪 completion，不另加与其重复的通知。对账尝试结束后，无论发现孤儿文件、孤儿记录或个别删除失败，都必须释放就绪队列，避免永久悬挂；现有 WCDB/文件错误处理策略不在本次扩大范围。资源加载请求本身的 HTTP 错误语义不变。

## 验收标准

1. App 启动路径不执行目录枚举、全表账本读取或等待 barrier。
2. 任何读/写/清理操作在 ready 前均不执行其缓存查询或文件副作用；completion 在 ready 后投递到指定队列，且 API 调用本身立即返回。
3. 同一时刻多个 pending 操作只在一次对账后释放；对账完成后新操作仍保持异步交付。
4. ready 前切歌后，旧 `playSwitchToken` 的回调不创建 AVPlayerItem、不更新 UI。
5. ready 前取消的 `AVAssetResourceLoadingRequest` 不触发本地读取或 Origin Range 请求。
6. ready 前取消或 generation 变化的下载不启动网络任务、不留下 reservation。
7. 首次缓存写入不被对账当作孤儿删除；LRU 清理不能删活动写入。
8. 离线无 URL 缓存命中、L1/L2/L3 缺口拼接、late write、防止完成缓存被覆盖等现有行为回归通过。
9. 不存在永久等待、主线程等待或 busy-wait；Thread Performance Checker 不报告本功能新增的等待优先级反转。

## 范围与非目标

- 修改 `NLCacheManager`、`NLResourceLoader`、`NLPlayerManager`、`NLDownloadManager`、音乐库缓存列表、播放器缓存进度调用与对应 XCTest。
- 更新 `docs/项目深度梳理.md` 与 `docs/面试技术亮点与优化点.md`。
- 不改缓存格式、音频身份规则、LRU 配额、HTTP Range 校验策略或数据库路径。
- 不引入重试、遥测、缓存内容哈希或后台下载功能；文件 rename 与 WCDB 更新仍非跨系统事务。
- 不提交、不推送；不触碰无关工作区改动。

## 验证计划

- 新增确定性 XCTest：阻塞对账期间，主/UI 队列仍能完成独立工作；缓存操作只在释放对账后执行。
- 新增切歌 token、资源加载取消、下载 generation 与 clear-generation 边界测试。
- 构建 `NLSpotify` 与测试目标，运行全部 `NLSpotifyTests`。
- 用模拟器启动应用确认 `didFinishLaunching` 不再等待目录扫描；以缓存命中和待取消 Range 请求覆盖实际资源加载路径。真机音频与 CDN 行为另行标注，不由单测推断。
