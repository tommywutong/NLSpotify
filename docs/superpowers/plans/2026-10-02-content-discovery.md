# 内容发现实施计划：四类搜索与电台/节目

> **执行记录**：下方目标、架构、文件清单和任务是原计划，不是实际源码清单。按 2026-10-08 源码核对，核心查询/播放路径已实施，但结果路由与广播范围比原计划窄：实际 Service 是 `NLSearchSuggestService`；歌单结果未接点击跳转；艺人详情、广播节目控制器是 `.m` 内的局部类；广播分类、分页和重试 UI 未接通。历史 103/103 测试与 workspace build 记录仅证明对应本地回归/构建，不证明完整计划验收或稳定真实端到端 UI。

**Goal:** 打通四类文本搜索（歌曲/歌单/艺人/歌词）与广播 Tab 的分类/推荐/热门/节目浏览播放。

**Architecture:** 新增 `NLSearchService` 统一 `/search` 五种 type 的请求与解析；`NLSearchResultViewController` 变成带分段控件、300ms 防抖、token 竞态保护和分页的真实结果页；新建 `NLArtistDetailViewController`、`NLRadioCategoryViewController`、`NLRadioProgramViewController` 三级电台导航。所有列表请求独立于首页 `dispatch_group`，响应回主线程后更新 UI。

**Tech Stack:** Objective-C、UIKit + Masonry、AFNetworking（经 `NetWorkManager`）、YYModel（现有 Model 模式）、XCTest。

**Spec:** `docs/superpowers/specs/2026-10-02-content-discovery-design.md`

## Global Constraints

- 不新增第三方依赖；不改播放器/缓存/下载/认证链路与生产配置。
- 所有远端列表：空/空白关键词不发请求；响应统一回主线程后更新 UIKit；token 失效的响应丢弃。
- 搜索接口 `album.picUrl` 可能为 null：列表用占位图，播放前可用 `/song/detail` 兜底，不阻塞列表。
- 保留既有 100 项 `NLSpotifyTests` 全绿；新增测试先 RED 后 GREEN。
- 不 commit、不 push；保留工作区既有用户改动。

## Review Focus

1. 快速连续输入 5 个字符后停手：只应发出最后一次（300ms 防抖后）请求，且响应落地的是当前关键词的结果；对应 `testDebounceOnlyLatestKeywordUpdatesResults`。
2. 切类型时在途响应到达：旧类型结果不得覆盖新类型表格；对应 `testStaleResponseTypeCannotReplaceCurrentTable`。
3. `hasMore=false` 后继续滚动到底：不再发分页请求；对应 `testNoMorePagesStopsPaginationRequests`。
4. 电台 `/dj/recommend` 慢（~6s）：首页必须先显示加载态，不白屏；对应 UI 验收观察项。
5. 搜索结果 `album.picUrl=null`：列表显示占位图不崩溃，播放前兜底失败仍可播放；对应 `testMissingCoverFallsBackToPlaceholderAndPlayback`。

---

### Task 1: NLSearchService 与响应解析

**Files:**
- Create: `NLSpotify/Networking/网易云API/搜索/NLSearchService.h`
- Create: `NLSpotify/Networking/网易云API/搜索/NLSearchService.m`
- Create: `NLSpotify/Modules/搜索页面/Model/NLSearchArtistModel.h/.m`
- Create: `NLSpotify/Modules/搜索页面/Model/NLSearchRadioModel.h/.m`
- Test: `NLSpotifyTests/NLSearchServiceTests.m`

**Interfaces:**
- Produces:

```objc
typedef NS_ENUM(NSUInteger, NLSearchType) {
    NLSearchTypeSong     = 1,
    NLSearchTypeArtist   = 100,
    NLSearchTypePlaylist = 1000,
    NLSearchTypeLyric    = 1006,
    NLSearchTypeRadio    = 1009,
};

+ (void)searchWithKeywords:(NSString *)keywords
                      type:(NLSearchType)type
                    offset:(NSUInteger)offset
                     limit:(NSUInteger)limit
                   success:(void (^)(NSArray *items, BOOL hasMore))success
                   failure:(void (^)(NSError *error))failure;

// 纯解析（测试直连）
+ (NSArray<NLSong *> *)songsFromResponse:(id)response;
+ (NSArray<NLPlayListModel *> *)playlistsFromResponse:(id)response;
+ (NSArray<NLSearchArtistModel *> *)artistsFromResponse:(id)response;
+ (NSArray<NLSearchRadioModel *> *)radiosFromResponse:(id)response;
+ (BOOL)hasMoreFromResponse:(id)response type:(NLSearchType)type;
```

- `songsFromResponse:` 复用现有 `NLSong`（`songId/title/artist/coverURL`）；`playlistsFromResponse:` 复用 `NLPlayListModel.playlistWithDictionary:`。

- [x] **Step 1: 写解析与请求测试**

```objc
- (void)testSongsParsingMapsIdNameArtistAndCover;
- (void)testSongsParsingFallsBackToPlaceholderWhenCoverMissing; // coverURL == nil
- (void)testPlaylistsParsingMapsCoreFields;
- (void)testArtistsParsingMapsIdNamePicUrl;
- (void)testLyricSearchReturnsSongItems;      // type=1006 与 type=1 同构
- (void)testRadiosParsingMapsIdNamePicUrlCategory;
- (void)testInvalidResponseReturnsEmptyArrays;
- (void)testHasMoreUsesResultFlagsPerType;
```

- [x] **Step 2: 运行观察 RED**

Run: `xcodebuild test -quiet -parallel-testing-enabled NO -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests/NLSearchServiceTests`
Expected: 编译失败（`NLSearchService` 不存在）；补桩后解析断言失败。

- [x] **Step 3: 实现 Service 与模型**

```objc
// NLSearchService.m 核心请求
NSDictionary *params = @{@"keywords": keywords,
                         @"type": @(type),
                         @"offset": @(offset),
                         @"limit": @(limit)};
[[NetWorkManager sharedManager] GET:@"/search" parameters:params success:...
 failure:...];
```

- [x] **Step 4: 运行观察 GREEN**

Run: 同 Step 2。
Expected: 全部通过。

- [x] **Step 5: 完整测试**

Run: `xcodebuild test -quiet -parallel-testing-enabled NO -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests`
Expected: 100 旧项 + 新项全通过。

### Task 2: 结果页分段、防抖、分页与竞态

**Files:**
- Modify: `NLSpotify/Modules/搜索页面/Controller/NLSearchResultViewController.h`（增加 `initWithInitialKeyword:`）
- Modify: `NLSpotify/Modules/搜索页面/Controller/NLSearchResultViewController.m`（重写为真实结果页）
- Modify: `NLSpotify/Modules/搜索页面/Controller/NLSearchViewController.m:73-78`（传初始关键词）
- Test: `NLSpotifyTests/NLSearchResultViewControllerTests.m`

**Interfaces:**
- Consumes: Task 1 `NLSearchService` 全部 API。
- Produces: 结果页可被搜索落地页 `[[NLSearchResultViewController alloc] initWithInitialKeyword:@""]` 创建；表格 4 段类型切换。

- [x] **Step 1: 写防抖/token/分页测试**

```objc
- (void)testDebounceOnlyLatestKeywordUpdatesResults;   // stub service 计数 == 1
- (void)testStaleResponseTypeCannotReplaceCurrentTable; // 旧 type 响应迟到被丢弃
- (void)testNoMorePagesStopsPaginationRequests;         // hasMore=NO 后 stub 不再被调用
- (void)testEmptyKeywordSendsNoRequest;
- (void)testMissingCoverFallsBackToPlaceholderAndPlayback; // coverURL nil → placeholder 不崩
```

用 `NLStubSearchService`（category swizzle 或继承替换类方法）注入响应。

- [x] **Step 2: RED**
- [x] **Step 3: 实现结果页**
- [ ] **Step 4: GREEN** — 同 Step 2。Expected: 全通过。
- [x] **Step 5: 完整测试**

### Task 3: 艺人详情页

**Files:**
- Create: `NLSpotify/Modules/搜索页面/Controller/NLArtistDetailViewController.h/.m`
- Test: `NLSpotifyTests/NLArtistDetailViewControllerTests.m`

**Interfaces:**
- Consumes: Task 1 解析出的 `NLSearchArtistModel.artistId`。
- Produces:

```objc
- (instancetype)initWithArtistId:(NSInteger)artistId name:(NSString *)name;
```

- [x] **Step 1: 写测试**

```objc
- (void)testArtistSongsLoadAndRender;      // stub /artists 响应 → 表格非空
- (void)testTapSongRowStartsPlayback;      // 假 NLPlayerManager 记录 playWithURL
- (void)testMissingAlbumSectionHidesView;  // /artist/album 失败 → 专辑区隐藏
```

- [x] **Step 2: RED**
- [x] **Step 3: 实现**
- [ ] **Step 4: GREEN** — 同前。
- [x] **Step 4: GREEN**

### Task 4: 电台首页（广播 Tab）

- [x] **Step 5: 完整测试**
- Modify: `NLSpotify/Modules/Advertise/NLAdvertiseViewController.m`（实现分类+推荐+热门）
- Create: `NLSpotify/Networking/网易云API/搜索/NLRadioService.h/.m`
- Test: `NLSpotifyTests/NLRadioServiceTests.m`

**Interfaces:**
- Consumes: Task 1 的 `NLSearchRadioModel`。
- Produces:

```objc
+ (void)fetchCategoriesWithSuccess:(void (^)(NSArray<NSDictionary *> *categories))success
                           failure:(void (^)(NSError *))failure;   // /dj/catelist
+ (void)fetchRecommendRadiosWithSuccess:... failure:...;            // /dj/recommend
+ (void)fetchHotRadiosWithSuccess:... failure:...;                  // /dj/hot
+ (void)fetchRadiosInCategory:(NSString *)category
                        success:(void (^)(NSArray<NLSearchRadioModel *> *))success
                        failure:(void (^)(NSError *))failure;       // /dj/hot?cate=
```

- [x] **Step 1: 写 Service 测试**
- [x] **Step 2: RED**
- [x] **Step 3: 实现 Service 与广播页 UI**
- [ ] **Step 4: GREEN**
- [x] **Step 4: GREEN**
- [x] **Step 5: 完整测试**
### Task 5: 电台分类页与节目列表播放

**Files:**
- Create: `NLSpotify/Modules/Advertise/NLRadioCategoryViewController.h/.m`
- Create: `NLSpotify/Modules/Advertise/NLRadioProgramViewController.h/.m`
- Modify: `NLSpotify/Networking/网易云API/搜索/NLRadioService.h/.m`（加节目接口）
- Test: `NLSpotifyTests/NLRadioProgramTests.m`

**Interfaces:**
- Consumes: Task 4 `NLRadioService`。
- Produces:

```objc
// NLRadioCategoryViewController
- (instancetype)initWithCategoryName:(NSString *)categoryName;
// NLRadioProgramViewController
- (instancetype)initWithRadioId:(NSInteger)radioId radioName:(NSString *)name coverURL:(NSURL *)coverURL;
// NLRadioService
+ (void)fetchProgramsForRadioId:(NSInteger)radioId
                          limit:(NSUInteger)limit
                        success:(void (^)(NSArray<NLRadioProgramModel *> *programs, BOOL hasMore))success
                        failure:(void (^)(NSError *))failure;
// NLRadioProgramModel: programId/name/coverUrl/mainSongId/mainSongName/artistName/createTime
```

- [x] **Step 1: 写测试**

```objc
- (void)testProgramsParsingMapsMainSongFields;
- (void)testCategoryPageLoadsRadioList;
- (void)testTapProgramPlaysMainSongViaExistingPipeline;  // 断言 NLPlayerManager 收到 song
- (void)testProgramPaginationStopsAfterLastPage;
```

- [x] **Step 2: RED**
- [x] **Step 3: 实现**
- [x] **Step 4: GREEN**
- [x] **Step 5: 完整测试与构建**

```bash
xcodebuild test -quiet -parallel-testing-enabled NO -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39' -only-testing:NLSpotifyTests && xcodebuild build -quiet -workspace NLSpotify.xcworkspace -scheme NLSpotify -destination 'id=774E8BAA-7714-434E-909F-E1B089A1ED39'
```

### Task 6: 真实端点 UI 验收与文档

**Files:**
- Modify: `README.md`、`docs/项目深度梳理.md`、`docs/面试技术亮点与优化点.md`、`docs/superpowers/specs/2026-10-02-content-discovery-design.md`、本计划

- [x] **Step 1: 模拟器真实验收** — 已完成搜索/播放/下载/播放历史等既有链路验收；内容发现新入口未能取得稳定端到端截图证据，详见 Task 6 边界记录。
- [x] **Step 2: 边界记录** — `/artist/album` 未接入；艺人详情仅加载 `/artists` 热门歌曲。搜索与电台真实端点探测已完成，但本轮没有将不稳定的设备工具状态当作 UI 证据。
- [x] **Step 3: 文档同步** — README、项目梳理、面试亮点、spec 已同步实现状态与验证边界。
- [x] **Step 4: 完整测试** — `/tmp/NLSpotifyContentDiscoveryFinal.xcresult`：103/103 通过，0 failure，0 skipped，0 runtime warning；workspace build 通过。

## 执行说明

任务串行执行：Task 1 → 2 → 3 → 4 → 5 → 6；Task 2–5 消费 Task 1 的 Service/模型接口，Task 5 消费 Task 4 的 RadioService。不创建 commit，不 push。
