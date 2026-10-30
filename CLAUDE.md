# CLAUDE.md - NLSpotify

## 项目概述

NLSpotify 是一个仿 Spotify 风格的 iOS 音乐流媒体应用，使用网易云音乐 API 代理获取内容。当前已接通在线播放、Range 音频缓存、行级歌词同步、自建/收藏歌单、搜索歌曲/歌单/艺人/歌词、广播推荐与节目播放、后台显式下载、离线文件播放与只读评论分页；非游客登录和评论写操作尚未接通。

- **语言:** 应用源码以 Objective-C 为主；WCDB 与缓存实现使用 `.mm` Objective-C++ 文件做桥接。
- **部署目标:** 应用与测试 target 当前均为 iOS 26.1；Podfile 将 Pods target 固定为 iOS 15.0。
- **架构模式:** MVC + 局部 ViewModel + Service + Repository
- **UI 方案:** 页面流程使用纯代码 UIKit + Masonry；工程保留 `Main.storyboard` 与 `LaunchScreen.storyboard` 资源，根控制器由 `SceneDelegate` 设置。
- **当前根路由:** `SceneDelegate` 按 `NLAuthManager isLoggedIn` 进入 TabBar 或登录页。`isLoggedIn` 由 `currentCookie` 非空推导；Keychain 为空或读取失败时回退旧 `NSUserDefaults` Cookie，不能说只看 Keychain。当前登录页只有游客登录。

## 文档入口与协作边界

- 接手或修改前先读 [docs/README.md](docs/README.md)；完整当前源码链路、实现边界和证据说明集中在 [docs/项目深度梳理.md](docs/项目深度梳理.md)。根 README 只保留项目与运行摘要，面试文档只用于表达。
- 信息冲突按“当前源码 → 当前事实文档 → 根 README/本文件摘要 → 面试材料 → 历史计划”裁定；历史 result bundle、build 或测试记录不等于本轮重新验证。
- 保留用户已有改动；本项目任务不得擅自修改业务源码、Podfile、Info.plist、CocoaPods、Cloudflare/D1/Vectorize 或其他生产配置。
- 不把 Cookie、API key、token、真实 URL 参数或 Authorization 值写入仓库或日志；不擅自 commit、push 或改写 Git 历史。

## 项目结构

保持以下稳定层级；具体类名、调用链和状态机以 [docs/README.md](docs/README.md) 与 [docs/项目深度梳理.md](docs/项目深度梳理.md) 为准。

```text
NLSpotify/
├── App/                    # AppDelegate、SceneDelegate、登录和 TabBar
├── Modules/
│   ├── 主页面/             # 推荐首页与 ViewModel
│   ├── 搜索页面/           # 搜索、发现和分类歌单
│   ├── 歌单详情页/         # 歌单歌曲、收藏和评论入口
│   ├── 播放器/             # 播放器、歌词、缓存、显式下载与离线正文
│   ├── 评论区/             # 只读评论与文本折叠
│   ├── 音乐库/             # 本地列表、自建歌单入口、喜欢和播放历史
│   ├── Advertise/          # 广播模块
│   ├── Create/             # 未挂到 Tab 的空页面，不是歌单创建入口
│   └── WCDB/               # 数据库管理器、Repository、ORM 与迁移
├── Networking/网易云API/   # NetWorkManager、认证和各 Service
├── Assets.xcassets/        # 图片和颜色资源
└── Resources/              # 静态资源
```

## 核心依赖（CocoaPods）

| 库 | 用途 |
|---|---|
| AFNetworking | HTTP 网络请求 |
| YYModel | JSON ↔ Model 序列化 |
| Masonry | AutoLayout 约束 DSL |
| SDWebImage | 异步图片加载与缓存 |
| WCDB.objc | 本地 SQLite 数据库（腾讯 WCDB） |
| HysteriaPlayer | 仅在 Podfile 中声明；当前应用源码未引用 |
| JXCategoryView | Pod 依赖；当前使用情况需按改动范围复核 |
| ReactiveObjC | 播放器状态信号 |
| SocketRocket | 仅在 Podfile 中声明；当前应用源码未引用 |
| IQKeyboardManager | 键盘自动管理 |
| LookinServer | UI 调试工具（仅 Debug） |

## 关键设计模式

- **单例模式:** NLPlayerManager、NLDataBaseManager、NetWorkManager、NLCacheManager、NLAuthManager
- **Service 层:** 每个 API 端点对应一个 Service 类（NLSongService、NLPlaylistService 等）
- **Repository 模式:** WCDB 仓库类封装数据库 CRUD（NLSongRepository、NLPlayListRepository 等）
- **响应式编程:** ReactiveObjC 用于播放器状态信号。UI 订阅绑定 `takeUntil:self.rac_willDeallocSignal`；`@weakify/@strongify` 不等于自行 dispose。Manager 对 ResourceLoader 的缓存进度订阅仍显式保存并在切歌时 dispose，详见[当前事实文档](docs/项目深度梳理.md)。
- **认证恢复:** 普通业务请求统一识别 HTTP 401 和业务码 301，串行刷新队列合并并发失败请求，成功后每个请求至多重放一次；`/login/refresh` 自身再次返回 301/401 时会在 `isRefreshing == YES` 时入队挂起，不应表述为调用栈递归或必然可靠登出，详见[当前事实文档](docs/项目深度梳理.md)。
- **缓存分层:** `NLResourceLoader` 与 `NLCacheManager` 负责 Range 缓存和文件晋级；完整身份、账本、迁移和清理规则以[当前事实文档](docs/项目深度梳理.md)为准。
- **显式下载:** 当前使用后台 `NSURLSessionDownloadTask` 与独立离线正文；恢复、取消、所有权和系统交付边界以[当前事实文档](docs/项目深度梳理.md)为准。
- **系统与离线能力:** 播放器优先使用可用离线正文，并接入系统媒体控制；真实 CDN、物理设备后台交付、force-quit 后恢复和断网人工播放尚未验证。

## 构建与运行

```bash
# 安装依赖
pod install

# 使用 workspace 打开项目
open NLSpotify.xcworkspace
```

始终使用 `.xcworkspace` 而非 `.xcodeproj` 打开项目。

## 开发约定

- 中文命名用于模块目录（主页面、搜索页面、播放器等），类名使用 `NL` 前缀英文命名
- Model 类使用 YYModel 协议进行 JSON 映射
- WCDB ORM 模型在 `.mm` 文件中定义 `WCDB_IMPLEMENTATION` 绑定
- 网络请求通过 NetWorkManager 单例发起，Service 类封装具体接口；当前已实现的 Service 端点均为 GET。
- 新页面遵循纯代码 UIKit + Masonry；不要把工程保留的 `Main.storyboard` 误写成主要页面实现。
- 播放器状态通过 ReactiveObjC 信号分发；异步播放 URL、进度和缓存状态需保留 `playSwitchToken` 检查。
- Tab 结构：首页 → 音乐库 → 广播 → 搜索（`UISearchTab`）；“创建”Tab 已注释，不在实际 `tabs`。
- 新增 WCDB 实体时遵循三文件约定：`.h` + `.mm` + `+WCDB.h`
- 新增 API 接口在 `Networking/网易云API/` 下对应目录创建独立 Service 类；当前搜索类型查询由 `NLSearchSuggestService` 接入结果页，`/search/suggest` 输入建议和搜索历史尚未接入结果页。

## 当前实现边界

- 搜索结果页已支持歌曲、歌单、艺人、歌词四类查询，包含 300ms 防抖、分页和 token + keyword 过期响应过滤；歌曲/歌词结果可播放，艺人结果进入 `NLSearchResultViewController.m` 内的局部详情控制器并加载 `/artists` 热门歌曲，歌单结果目前没有点击跳转。`/search/suggest` 和搜索历史尚未接入当前结果页。
- 广播页已接通推荐电台、失败时热门兜底、电台节目列表和节目主歌曲播放；分类列表、广播分页和独立重试 UI 尚未接通。Tab 里的独立创建页、首页顶部筛选按钮、广告 CTA 和音乐库艺人菜单仍无实际业务流。音乐库自建歌单不走这个空创建页。
- 评论只读且不持久化；按实际行宽扣除 Cell 水平占用，在独立任务中进行 TextKit 折叠与最终文本高度测量，保留 composed-character 边界。页面协调器最多并发 2 个任务，合并同键请求并缓存不可变布局；代次和内容/身份检查丢弃失效结果。Cell 不同步排版，应用缓存文本高度，整行由 Auto Layout 计算；分页增量插入，宽度/字号变化统一重排并维护阅读锚点，支持 VoiceOver 展开/收起。歌词只支持带两位/三位小数时间标签的行级 LRC，不支持逐字/翻译歌词；手动与自动歌词请求都校验页面可见性、song ID 和请求 token。
- Repository 写入统一通过 `NLDataBaseManager` 的 serial writer queue；`performRead:` 也走同一条队列，不是独立只读队列。缓存账本由 `NLCacheManager` 在标识分片队列直接写库，不经过该 writer queue。歌单关系、下载完成等 Repository 跨表写入使用 WCDB transaction。同步读取 API 仍存在，批量列表读取由调用方放到后台快照边界处理。
- 播放历史由 `PlaybackHistoryMetadataTable` 记录 `lastPlayedAt`/`playCount`。正常路径由 `timeControlStatus` 归约出 Playing 后，对当前 token 记一次，不等于收听时长或物理出声证明；历史按最近启动时间排序。播放按钮看 `wantsToPlay`；音频中断按系统建议与意图恢复，耳机拔出暂停，媒体服务重置等待用户再播放。会话操作后台串行执行，切歌/停止/重置统一清理观察与 Loader。

## 已记录验证（截至 2026-10-03）

- 内容发现相关历史记录曾指向 `/tmp/NLSpotifyContentDiscoveryFinal.xcresult`：103/103 通过，0 failure，0 skipped，0 runtime warnings；对应 workspace build 通过。2026-10-11 复核时该临时路径已不存在，不能当成当前可打开证据，也不等于真实端到端 UI 截图。
- 核心可靠性相关历史记录：完整 `NLSpotifyTests` 100/100 通过、0 runtime warning；覆盖 Keychain 迁移、WCDB 迁移/事务、缓存、下载、歌词和评论边界。该记录不是本轮重新运行结果，对应临时 result bundle 也不应默认仍在 `/tmp`。
- 已记录的模拟器 smoke 不覆盖游客登录、真实 CDN 音频、物理设备后台 `NSURLSession` 交付、force-quit 后恢复或断网离线人工验收。

## API 配置
