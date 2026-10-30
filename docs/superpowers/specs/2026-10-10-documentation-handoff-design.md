# NLSpotify 文档接手入口与归并设计

> 日期：2026-10-10\
> 目的：让新接手的 AI 能以当前源码为准，沿业务链路定位实现，并区分实现事实、历史记录和面试表达。

## 目标读者与验收结果

目标读者是没有本次会话上下文、需要继续维护 NLSpotify 的 AI/工程师。整理后应满足：

1. 从一个固定入口知道先读什么、实现事实以哪份文档为准、源码关键位置在哪里。
2. 能按启动/认证、内容发现、播放、Range 缓存、显式下载、WCDB、歌词/评论/状态分发逐条追到源码入口及依赖关系。
3. 清楚已接通路径、源码中存在但尚未接线的能力，以及未由本地证据证明的真机/CDN/后台行为。
4. 旧的补充计划、粘贴片段、重复问答不再与事实文档并列，避免 AI 把计划或面试说法误读成实现。
5. 不修改业务源码、工程配置、Pods、原始资料或历史设计/实施记录；不提交、不推送。

## 文档权威顺序

1. **当前实现事实**：当前工作区源码；`docs/项目深度梳理.md` 是按链路组织的导航和静态审阅，不替代源码。
2. **协作入口**：`docs/README.md` 提供阅读顺序、文件定位与证据边界；`README.md` 保持项目简介和构建入口；根 `CLAUDE.md` 是项目协作上下文并链接到入口。
3. **面试材料**：`docs/面试技术亮点与优化点.md` 仅作基于源码的表达与追问材料，不作为实现规格或验证记录。
4. **历史变更材料**：`docs/superpowers/specs/`、`docs/superpowers/plans/` 和 `.superpowers/sdd/` 只解释特定日期的设计/实施过程；不代表当前仍使用该方案，须回到源码核实。
5. 根目录散落的补充/计划碎片在迁移有效事实和仍有价值的问答后删除，不继续充当文档入口。

## 当前源码事实必须反映的链路

- **启动与认证**：`AppDelegate` 初始化数据库、下载管理器和缓存清理；`SceneDelegate` 迁移 legacy Cookie 后按 `NLAuthManager.isLoggedIn` 路由。游客登录是唯一实际登录 UI。`NetWorkManager` 给 GET/POST 注入 Cookie 并处理业务码 301/HTTP 401、刷新队列和最多一次重放。刷新请求 `/login/refresh` 也经同一 `NetWorkManager`，刷新端点自身返回 301/401 时存在递归/收口风险；文档不得将其概括为所有刷新错误都必然强制登出。
- **首页/搜索/广播**：首页 5 个请求用固定槽位与 `dispatch_group` 汇合，单分区失败只省略该槽位；搜索 UI 当前四种类型为歌曲、歌单、艺人、歌词，300ms 延迟、offset 分页及 token+keyword 结果过滤；歌曲/歌词能创建播放意图，艺人打开搜索结果文件内的局部详情控制器，歌单点击无详情跳转。搜索历史和 `/search/suggest` 的输入建议尚未接入结果页。广播接通 `/dj/recommend`、失败时 `/dj/hot`、`/dj/program` 节目和合法 `mainSong` 播放；分类、分页、独立重试未接通。
- **播放与状态**：页面经 `NLPlayerManager playWithPlaylist:startIndex:` 共享播放器；播放优先级为离线正文、完整普通缓存、已有播放 URL、获取播放 URL 后流式播放。`playSwitchToken`、当前歌曲和 `AVPlayerItem` 身份用于作废迟到回调；取消网络任务与 token 保护职责不同。RAC 五个信号分发状态/歌曲/进度/缓存进度/播放列表状态。UI 的若干 RAC 订阅没有保存/释放 disposable；不应写成订阅生命周期已全部闭环。
- **缓存字节链路**：`streaming://` 经 `NLResourceLoader` 以连续 Range 提供 AVPlayer 数据；L1 内存 segment，L2 `.tmp`+WCDB range ledger，L3 完整 `.mp3`，缺口才 HTTP Range 回源；`NLHTTPRangeValidator` 校验响应；cache identifier 采用 SHA-256 并保留旧账本迁移；ready gate、启动对账、按 identifier 分片串行写入、LRU 与清空屏障处理并发。文件系统与 WCDB 不是跨系统原子事务，长度匹配不检测同长度损坏。
- **显式下载**：`NLDownloadManager` 使用稳定 background session 和 `NSURLSessionDownloadTask`，启动时只重建系统仍保留且能匹配 WCDB 记录的任务；generation 约束回调所有权。完整正文先导入 `Application Support/NLOfflineAudio`，离线状态写入 JSON，完成歌曲与队列状态再通过 WCDB 事务提交。普通 Range 缓存与用户离线正文是不同所有权；真机后台系统交付、force-quit 后恢复、真实 CDN 和断网人工播放未由本地测试证明。
- **数据与辅助功能**：`NLDataBaseManager` 统一 serial writer queue；多表修改通过事务，仍有同步读取 API；播放历史按真正进入 Playing 的 token 去重。歌词是有两/三位小数 LRC 时间标签的行级歌词，不支持逐字/翻译。评论是歌曲/专辑/歌单只读分页，TextKit 依实际 label 宽度折叠，当前没有写操作和评论持久化。

## 文件变更设计

### 新建

- `docs/README.md`：项目文档地图、推荐接手顺序、权威层级、证据等级、关键源码入口和修改前提醒。

### 更新

- `docs/项目深度梳理.md`：保留作为唯一详细链路事实文档；校准上面的源码边界，移除重复的伪代码/陈旧错误断言，确保每条链路有入口文件、调用流、失败/竞态控制、测试位置和未验证边界。
- `README.md`：精简为项目概览、运行条件、当前能力边界和链接，不重复长篇内部实现细节；把失效验证日期/声明明确标为历史记录或移除无来源表述。
- `CLAUDE.md`：保留维护 AI 必需的架构、惯例和真实边界；目录树只保留稳定层级，不维护易过期文件枚举；加入文档阅读入口并删除重复的历史测试清单。
- `docs/面试技术亮点与优化点.md`：保留面试用途，纠正与源码冲突的方案描述和未经证实的论断；通过链接引用详细链路文档，不复制第二份源码手册。

### 删除（有效内容迁移至上述主文档后）

根目录：
`cache_consistency.md`、`cookie_refresh.md`、`download_state_machine.md`、`existing_playback.md`、`existing_qa.md`、`home_concurrent.md`、`integration_plan.md`、`interview_supplement_plan.md`、`new_h2_concurrent.md`、`new_h2_cookie.md`、`new_h2_download.md`、`new_h2_wcdb.md`、`playback_supplement.md`、`qa_additions.md`、`rac_supplement.md`、`review_plan.md`、`tech_qa.md`、`token_addition.md`、`wcdb_consistency.md`、`首页ViewModel面试讲解.md`。

`existing_playback.md` 仅有一个空行；保留内容会先检查，其余面试片段里未经源码证明的结论不迁移。不得删除下面的历史记录：`docs/superpowers/specs/`、`docs/superpowers/plans/`、`.superpowers/sdd/`。

## 不在范围内

- 修复发现的代码缺口（包括刷新端点重入风险、RAC disposable 生命周期、页面路由缺口）。只把事实和风险准确记入文档，不顺手改业务代码。
- 改动远端 API、账号、腾讯云函数、构建目标、Podfile、Info.plist、CocoaPods 或用户工程状态。
- 重写历史设计/实施计划，或将历史计划内容宣称为当前行为。
- 运行构建/测试来重新认证历史证据；本轮按文档整理范围执行结构、链接和事实交叉核对，并明确未重新验证 App 行为。

## 验收

- `docs/README.md` 可独立指导 AI 找到事实入口、源码链路和证据层级。
- 四份保留/更新文档互相链接且职责不冲突；关键能力边界在入口中准确且不过度承诺。
- 20 份明确列出的根级碎片稿在迁移核对后删除；superpowers 历史记录与非文档源码/工程文件保持原状。
- 文档内部链接均指向存在文件；找不到的本地路径和过时类/方法名修正或删除。
- 凭据值不出现于新增/修改文档；明确列出本轮没有运行的 App build、测试、真实 API、模拟器/真机和后台系统交付验证。
