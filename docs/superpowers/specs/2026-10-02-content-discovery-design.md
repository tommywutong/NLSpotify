# 内容发现设计：四类搜索与电台/节目

> 状态：**核心搜索与广播播放链路已实施（2026-10-03）；计划验收范围并未全部落地。** 截至 2026-10-08 源码快照，搜索歌单结果点击、广播分类/分页/重试 UI 未接通；艺人详情和节目页为控制器文件内的局部类，不是独立控制器文件。历史测试/build 记录见 `docs/superpowers/plans/2026-10-02-content-discovery.md` Task 6；新入口稳定真实端到端截图尚未取得。

## 当前源码交付对照（2026-10-08）

- 搜索实际使用 `NLSearchSuggestService`，不是计划中的 `NLSearchService`；结果页已接入歌曲、歌单、艺人、歌词四类查询、防抖、分页和 token/keyword 过滤。
- 歌曲/歌词结果可播放；艺人行进入 `NLSearchResultViewController.m` 内的局部 `NLArtistDetailController`，只请求 `/artists` 热门歌曲；歌单行目前没有点击跳转。搜索历史和 `/search/suggest` 下拉建议没有接入结果页，失败态没有独立重试按钮。
- 广播页实际为 `/dj/recommend`、失败时 `/dj/hot` 兜底、点击电台后由同文件内联 `NLRadioProgramController` 读取节目并播放 `mainSong`。`/dj/catelist` 分类浏览、分类页、分页、token 管理和重试 UI 未接通。
- 下方“设计”和“验收标准”记录 2026-10-02 的目标，不代表这些条目都已完成；当前事实以源码与 `docs/项目深度梳理.md` 为准。

## 目标

让搜索落地页的文本输入变成真实可用的四类检索结果（歌曲、歌单、艺人、歌词），并让「广播」Tab 变成真实的电台分类/推荐/热门浏览与节目列表播放；所有新列表沿用现有异步、Token 竞态保护和播放/缓存链路，不把本地测试结果包装成远端承诺。

## 实施前基线（2026-10-02 实测）

- `NLSearchResultViewController` 的 `updateSearchResultsForSearchController:` 只 `NSLog` 文本；`NLSearchSuggestService` 存在但无调用点。
- 远端 `/search` 端点已用真实请求验证：`type=1` 歌曲列表（`result.songs[]`：`id/name/duration`，艺人 `artists[].name`，专辑 `album.id/name/picUrl`——搜索结果里 `picUrl` 可能为 null，需要 `song/detail` 兜底取 `al.picUrl`）；`type=1000` 歌单（`result.playlists[]`：`id/name/coverImgUrl/playCount/trackCount`）；`type=100` 艺人（`result.artists[]`：`id/name/picUrl/alias/albumSize/musicSize`）；`type=1006` 歌词（`result.songs[]`：`id/name/artists[]`）；`type=1009` 电台（`result.djRadios[]`：`id/name/picUrl/programCount/category`）。
- 电台端点已验证：`/dj/catelist`（`categories[]`）、`/dj/recommend`（`djRadios[]`）、`/dj/hot`（`djRadios[]`）、`/dj/program?rid=&limit=`（`programs[].mainSong`：`id/name`，`coverUrl`，可直接走 `/song/url` 播放）。
- `/artists?id=`（艺人热门歌曲）与 `/playlist/track/all?id=`（歌单全量曲目）可供原计划中的结果点击详情流程使用；当前源码事实见上方“当前源码交付对照”。
- 分页参数：`/search` 支持 `offset/limit`；`result.hasMore` 或 `songCount/artistCount` 可判断是否还有下一页。

## 设计

### 1. 搜索 Service 层

- 新建 `NLSearchService`（`Networking/网易云API/搜索/`）：统一 `+searchWithKeywords:type:offset:limit:success:failure:`，`type` 用 `NS_ENUM`（`NLSearchTypeSong=1`、`NLSearchTypePlaylist=1000`、`NLSearchTypeArtist=100`、`NLSearchTypeLyric=1006`、`NLSearchTypeRadio=1009`）；响应解析为四个纯函数 `+songsFromResponse:`、`+playlistsFromResponse:`、`+artistsFromResponse:`、`+radiosFromResponse:`，输入非法返回空数组并给出可断言错误，不静默吞掉。
- 空关键词不发请求；`keywords.trim` 后为空直接回调空结果。
- 歌曲封面兜底：搜索响应的 `album.picUrl` 为空时，点击播放前用 `/song/detail?ids=` 补一次封面（不阻塞列表渲染，列表封面占位用 SF Symbol `music.note`）。

### 2. 结果页 UI

- `NLSearchResultViewController` 增加 `UISegmentedControl`（歌曲/歌单/艺人/歌词），四类共用一个 `UITableView`；切类型即用当前关键词重新查询。
- 防抖：`dispatch_after` 300ms + 单调递增 `searchRequestToken`；只有最新 token 且关键词前缀匹配的结果才能更新表格。取消（`searchBarCancelButtonClicked`）时 token 失效并清空表格。
- 分页：滚动到底部触发 `offset += limit`；分页请求同样携带 token，过期响应丢弃；`hasMore` 为 NO 后不再请求。
- 行为：
  - 歌曲行：点行即 `NLPlayerManager` 播放（走现有完整缓存/流式缓存路径）。
  - 歌单行：push `NLSongListViewController initWithId:type:NLSongListTypePlaylist`。
  - 艺人行：push 新 `NLArtistDetailViewController`（Task 3 定义）。
  - 歌词行：点行即播放该歌曲（歌词命中即表达“这首歌包含该歌词”）。
- 空态：无结果或失败显示居中提示文案；失败时提供“重试”按钮。
- 搜索历史：沿用现有 `NLSearchRepository`（点击搜索按钮时保存，最多 20 条，点击历史行回填搜索词）；不新增表。

### 3. 艺人详情页（搜索的下游）

- 新建 `NLArtistDetailViewController`：头像 + 名称 + 热门 50 首（`/artists?id=`）；点行播放；顶部“全部专辑”区用 `/artist/album?id=&limit=`（若不可用则隐藏该区，不作为验收项）。

### 4. 广播 Tab（`NLAdvertiseViewController` 重命名语义为电台首页）

- 顶部：分类横滑列表（`/dj/catelist` → `NLCategoryCell` 复用）；点分类 push `NLRadioCategoryViewController`（`/dj/recommend?type=` 或 `/dj/hot?cate=`）。
- 主体：推荐电台（`/dj/recommend`）+ 热门电台（`/dj/hot`）两个分区；复用 `NLPlaylistCell` 卡片展示电台（封面/名称/节目数）。
- 点电台：push `NLRadioProgramViewController`（`/dj/program?rid=`），列表显示节目（名称 + 主歌艺人 + 发布时间）；点节目用 `mainSong.id` 走现有播放链路。
- 所有电台列表沿用同一 Token + 分页保护；远端失败显示错误与重试。
- Tab 名称与文件名不变（`NLAdvertiseViewController`），只改内部实现，避免 storyboard/TabBar 代码大改。

### 5. 竞态与生命周期

- 所有远端列表请求都在专用 Service 里串行发起，响应统一回主线程后才碰 UIKit。
- 结果页消失（`viewWillDisappear`）时递增 token，让在途响应失效。
- 不复用首页 `dispatch_group`；搜索/电台各自独立。

## 非目标

- 不实现 MV、视频、主播用户页、电台订阅/收藏写操作、评论写操作。
- 不实现搜索建议下拉（`NLSearchSuggestService` 保留原样，不在本期接入）。
- 不改播放器、缓存、下载链路。
- 不新增第三方依赖。

## 历史验收标准（目标，非当前完成声明）

1. 输入“那时雨”并切 4 个类型，都能在 2 秒内渲染非空列表；防抖期间连续输入只发最后一次请求（用 token 断言）。
2. 歌曲行点击后播放器开始播放；歌单行能进歌单详情；艺人行能进艺人详情；歌词行能播放。
3. 滚动到底部加载下一页；重复滚动不产生重复请求（`hasMore=false` 后停发）。
4. 广播 Tab 显示真实分类/推荐/热门；点分类、点电台、点节目三级导航可用；节目点击可播放。
5. 断网时搜索/电台显示失败态与重试按钮，恢复网络后重试成功。
6. 现有测试套件（100 项）全部继续通过；新增测试先 RED 后 GREEN。
7. 真实端点仅在请求有效时断言；不可用端点逐项记录为外部阻塞。

## 风险与边界

- 搜索接口 `album.picUrl` 经常为 null：列表封面需要占位图 + `song/detail` 兜底；兜底失败仅影响封面，不影响播放。
- `/dj/recommend` 首次响应约 6 秒：电台首页必须先渲染骨架/加载指示，不能白屏等远端。
- 电台节目 `mainSong` 无封面字段时用电台封面兜底。
- 上述模拟器 UI/真实远端数据验收是原规格目标，不等于已观察证据；当前未取得新入口稳定端到端截图，真机后台交付也未验证。
