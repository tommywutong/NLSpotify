# NLSpotify

[![Platform](https://img.shields.io/badge/platform-iOS-blue.svg)](https://developer.apple.com/ios/)
[![Language](https://img.shields.io/badge/language-Objective--C-orange.svg)](https://developer.apple.com/documentation/objectivec)
[![Dependency](https://img.shields.io/badge/dependency-CocoaPods-red.svg)](https://cocoapods.org/)

NLSpotify 是一款仿 Spotify 风格的 iOS 音乐流媒体 App。项目使用 Objective-C/UIKit 开发，通过网易云音乐 API 代理获取内容；当前核心实现包括在线播放、Range 音频缓存、播放器状态分发、行级歌词、只读评论分页、本地音乐库、后台显式下载与离线文件播放。

播放器链路覆盖播放 URL 获取、`AVAssetResourceLoader` Range 请求、L1 内存/L2 临时文件/L3 完整文件缓存、WCDB 账本，以及小播放器和全屏播放器的状态同步。内容发现链路已接通歌曲、歌单、艺人、歌词搜索和广播推荐/热门兜底/节目播放；远端服务可用性、真机播放表现和 CDN 内容正确性未在本文档中承诺。

**内容发现边界校准**：搜索结果页的歌单行目前只渲染结果，点击未接歌单详情；艺人详情是 `NLSearchResultViewController.m` 内的局部控制器，只调用 `/artists` 展示热门歌曲；广播页当前未接分类列表、分页和独立重试 UI。

**2026-10-03 内容发现迭代的历史验证记录**：内容发现相关本地回归测试 103/103 通过，workspace build 通过；本轮未取得稳定的真实端到端新入口截图，真实 CDN/物理设备后台交付仍未验证。

**2026-10-30 GitHub 同步前验证**：在隔离的 iPhone 17 Pro / iOS 27.0 模拟器上，使用当前 workspace、`NLSpotify` scheme 和临时模拟器签名参数（`CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES`）运行完整 XCTest，result bundle 摘要为 139/139 通过、0 failure、0 skipped、0 runtime warning；参数化展开后的设备执行数为 142。实际安装启动后已截图确认游客登录页显示。首次禁用签名的运行因 Keychain 缺少 entitlement（`-34018`）失败，启用模拟器签名后通过，没有跳过用例或修改业务逻辑。本次不覆盖游客登录请求、真实 CDN 播放、物理设备后台交付或生产端点；本机 Bundle ID/签名覆盖不纳入功能提交。


## 截图

| 首页 | 搜索发现 | 音乐库 | 播放器 |
|:---:|:---:|:---:|:---:|
| <img src="Resources/zhuye.png" width="200" alt="首页"/> | <img src="Resources/sousuo-2.png" width="200" alt="搜索发现"/> | <img src="Resources/tushuguan.png" width="200" alt="音乐库"/> | <img src="Resources/spotify.png" width="200" alt="播放器"/> |

## 核心能力

- **在线播放**：基于 AVPlayer 播放歌曲，支持列表循环、单曲循环、随机播放和播放队列。
- **流式音频缓存**：通过 `AVAssetResourceLoader` 接管 Range 请求，支持已有区间复用、缺口下载和 LRU 清理；完整链路见[当前事实文档](docs/项目深度梳理.md)。
- **异步一致性控制**：播放 URL、缓存进度、周期进度及 item/player KVO 使用 Token 和相应身份过滤迟到回调；音频会话异步操作另有 generation，停止或重置后不接受旧结果。
- **认证恢复**：统一处理 HTTP 401 和网易云业务码 301，使用刷新队列合并并发刷新请求，成功后批量重试；`/login/refresh` 自身再次返回 301/401 时会在刷新窗口内入队挂起，不能说所有刷新失败都可靠登出，详见[当前事实文档](docs/项目深度梳理.md)。
- **歌词与评论**：解析带两位/三位小数时间标签的行级 LRC 并同步当前行；只读评论支持 TextKit 三行折叠、有界异步排版与双态文本高度缓存、分页增量插入、阅读锚点及 VoiceOver 展开/收起操作，整行仍由 Auto Layout 自适应。
- **本地音乐库与离线下载**：WCDB 持久化本地音乐数据和缓存账本；显式下载使用后台 `NSURLSessionDownloadTask`，完整离线正文独立保存。状态机和所有权见[当前事实文档](docs/项目深度梳理.md)。
- **系统播放能力**：状态跟随 AVPlayer 实际时间控制状态，播放按钮跟随用户意图；已处理音频中断条件恢复、外部输出断开暂停和媒体服务重置后的显式恢复。回到前台补发状态与进度快照，seek 完成后校验播放上下文并同步 Now Playing。音频会话操作不阻塞主线程，切歌/停止/重置统一清理观察与 Loader；真机行为仍需独立验证。

## 架构

```text
UIKit View / ViewController
        ↓
MVC + ViewModel
        ↓
Service API 层
        ↓
NetWorkManager + NLAuthManager
        ↓
Repository
        ↓
WCDB + NLCacheManager
```

### 主要模块

```text
NLSpotify/
├── App/                    # AppDelegate、SceneDelegate、登录和 TabBar
├── Modules/
│   ├── 主页面/             # 推荐首页、首页 ViewModel、抽屉
│   ├── 搜索页面/           # 搜索发现、分类歌单
│   ├── 歌单详情页/         # 歌曲列表、收藏、评论、加入本地歌单
│   ├── 播放器/             # 播放器、迷你播放器、缓存、下载
│   ├── 评论区/             # 评论列表、TextKit 文本折叠
│   ├── 音乐库/             # 播放历史、喜欢歌曲、歌单和下载
│   └── WCDB/               # 数据模型、数据库管理器和 Repository
└── Networking/             # 网易云 API Service 和认证网络层
```

## 技术栈

| 分类 | 技术 | 用途 |
| --- | --- | --- |
| UI | UIKit + Masonry | 纯代码界面和 Auto Layout |
| 网络 | AFNetworking | HTTP 请求、响应序列化和网络状态 |
| 播放 | AVPlayer / AVAssetResourceLoader | 音频播放和自定义 Range 数据源 |
| 响应式 | ReactiveObjC | 播放器状态的单向分发 |
| 图片 | SDWebImage | 图片异步加载及缓存 |
| 数据库 | WCDB.objc | SQLite ORM 和本地音乐数据 |
| 模型 | YYModel | JSON 到 Objective-C Model |
| 系统能力 | AVAudioSession / MediaPlayer | 后台播放和锁屏控制 |
| 工程 | CocoaPods | 依赖管理 |

播放器核心路径使用 Apple 原生 AVPlayer。`HysteriaPlayer` 和 `SocketRocket` 仍在 Podfile 中，但当前应用源码未引用它们；移除前应先确认产品范围和构建影响。

## 运行

### 环境

- 可构建当前 Xcode 工程的 Xcode 版本
- CocoaPods
- 应用与测试 target 当前声明 `IPHONEOS_DEPLOYMENT_TARGET = 26.1`
- Podfile 将 Pod target 统一为 iOS 15.0
- 可访问项目配置的网易云 API 代理

### 安装

```bash
git clone https://github.com/tommywutong/NLSpotify.git
cd NLSpotify
pod install
open NLSpotify.xcworkspace
```

请使用 `.xcworkspace` 打开项目。首次运行使用游客登录；当前登录页只有「游客登录」按钮，没有手机号、邮箱、Apple 或其他第三方登录入口。

## API 和数据来源

音乐数据来自 [NeteaseCloudMusicApi](https://binaryify.github.io/NeteaseCloudMusicApi/) 兼容接口，并通过项目配置的腾讯云函数代理访问。主要 Service 包括：

- `NLSongService`：播放 URL 和歌词。
- `NLRecommendAlbumListService`、`NLChineseSongListService`：推荐和分类歌单。
- `NLPlaylistService`、`NLSongListService`：歌单详情和歌曲列表。
- `NLAlbumService`、`NLSingerAlbumListService`：专辑和歌手专辑。
- `NLCommentService`：歌曲、专辑和歌单评论。
- `NLSearchSuggestService`：歌曲/歌单/艺人/歌词/电台类型搜索与 `/search/suggest` 输入建议；结果页已接类型搜索，未接建议下拉。
- `NLAuthService`、`NLGuestLoginService`：登录和 Cookie 刷新。

## 当前边界

项目仍在持续完善，以下能力请按实际状态理解：

- 游客 Cookie 的目标存储是 Keychain account `NLNeteaseCookie`。`isLoggedIn` 由 `currentCookie` 是否非空推导：Keychain 有值时用 Keychain；Keychain 为空或读取失败时回退旧 `NSUserDefaults` Cookie，迁移写入失败仍暂时返回旧值。因此不能说登录态只看 Keychain，旧 `isLoggedIn` 布尔值也不是第二份真值。当前登录页没有其他登录按钮。
- 搜索结果页已支持歌曲、歌单、艺人、歌词四类 `/search` 查询，包含 300ms 防抖、分页和 token + keyword 过期响应过滤；歌曲/歌词结果可播放，艺人结果进入内联详情并加载热门歌曲，歌单结果目前没有点击跳转。`/search/suggest` 辅助接口和搜索历史仍未接入当前结果页。
- 广播页已接通 `/dj/recommend`、失败时的 `/dj/hot` 兜底、电台节目列表和节目主歌曲播放；分类列表、广播分页和独立重试 UI 尚未接通。Tab 里的独立创建页、首页顶部筛选按钮、广告“立即体验”和音乐库艺人菜单仍无实际业务流。音乐库里的自建歌单创建、收藏歌单和加入本地歌单是另一条已接通路径，不要把空的创建 Tab 理解成不能创建歌单。
- 显式下载使用带稳定 identifier 的后台 `NSURLSessionDownloadTask`；启动先枚举并重建**系统仍保留且能匹配 WCDB 下载记录**的任务，再准入新请求，不会把数据库中没有对应系统任务的记录自动恢复为新任务。列表已支持逐首数值/不定进度和暂停、继续、重试、取消、删除；generation 让删除与迟到回调不能复活队列或离线文件。系统不保证用户 force-quit 后继续，`resumeData` 失效显示失败；完整离线正文位于 Application Support，普通缓存清理不会删除它；真机后台恢复与真实 CDN 仍未验证。
- 评论列表为只读分页，不持久化，也没有发布、点赞或失败重试 UI。Service 声明了楼层评论接口，模型会解析 `beReplied`，但当前列表没有调用或渲染回复树。歌词不持久化，手动与自动请求已共用页面可见性、song ID 和请求 token 校验，旧回调不再覆盖当前歌词面板。
- 播放历史由 `PlaybackHistoryMetadataTable` 记录 `lastPlayedAt`/`playCount`。正常路径在 AVPlayer 实际进入 Playing 后，对当前 token 记一次；不是实际收听时长或扬声器出声的证明。历史按最近启动时间排序，旧历史迁移后 `playCount=1`、`lastPlayedAt=0`。
- 音频缓存账本使用 `AudioCacheInfoTable_v3`（主键 `cacheIdentifier`）；新缓存身份为 `sha256-<hex>`，旧 `urlMD5` 行在启动迁移中原样保留为 legacy ID 并继续指向旧文件；旧 partial 不与新身份合并。普通缓存不在启动或进后台淘汰：L2 达到 128 MiB、L3 达到 500 MiB 后，只把超限层按 LRU 裁到 90%。
- 普通完整缓存统一校验完成标记、全覆盖 Range 账本和正文长度；保留同目录 rename 晋级。提交失败返回失败，支持幂等完成及启动补交。有效完整缓存直接通过本地文件 URL 创建 `AVPlayerItem`，不走 ResourceLoader；进度条表现未改。
- 应用数据库位于 `Library/Application Support/NLSpotify/NLSpotify_v2.sqlite`；旧 Documents 数据库在首次访问时通过 WCDB 连同伴随文件迁移。已有新库不覆盖，迁移失败不创建空库替代。普通音频缓存仍在 Caches，离线正文位置不变。
- 播放器 UI 订阅绑定 `takeUntil:self.rac_willDeallocSignal`。`@weakify/@strongify` 只处理 block 引用，不负责取消订阅；详细边界见[当前事实文档](docs/项目深度梳理.md)。

## 项目文档

- [文档入口](docs/README.md)：统一说明文档权威级别、证据标签和按任务查找路径。
- [项目深度梳理](docs/项目深度梳理.md)：源码事实、数据流、已验证范围、实现边界和后续接手入口。
- [面试技术亮点与优化点](docs/面试技术亮点与优化点.md)：基于当前实现的面试表达、已知边界和优化路线。
- `docs/superpowers/plans/2026-09-30-offline-downloads-and-comment-layout.md`：后台下载、离线所有权、L1 稳定身份与评论布局的实施记录；2026-09-30 完整 `NLSpotifyTests` 58/58 通过。
- `docs/superpowers/plans/2026-10-02-core-reliability.md`：本轮 Keychain 迁移、WCDB 串行队列/事务、下载状态机、URL/歌词竞态修复与缓存 `sha256` 迁移的实施记录；2026-10-02 完整 `NLSpotifyTests` 100/100 通过、0 runtime warning，App 与测试 target 冷构建项目 warning 为 0。

## License

当前仓库未附带独立的许可证文件；如需公开发布或复用代码，建议先补充明确的 License 声明。
