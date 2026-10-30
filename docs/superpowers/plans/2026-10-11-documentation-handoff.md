# NLSpotify Documentation Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立一个以当前源码为准、能区分实现事实/历史证据/面试表达的 NLSpotify 文档接手入口，并删除已迁移的根目录碎片稿。

**Architecture:** `docs/README.md` 只负责发现路径、权威级别和证据边界；`docs/项目深度梳理.md` 保留唯一详细的当前源码链路事实；根 `README.md` 与 `CLAUDE.md` 分别承担项目介绍/运行入口和协作上下文；`docs/面试技术亮点与优化点.md` 只承担面试表达。根目录补充计划、重复伪代码和已迁移问答在核对后删除，`docs/superpowers/` 历史记录保持不变。

**Tech Stack:** Markdown、Objective-C/UIKit 项目文档；使用 `read`/`edit` 做定点编辑，使用 `grep`、`bash` 和 Markdown 链接脚本做静态验证；不运行 App build、XCTest 或真实端点。

**Spec:** `docs/superpowers/specs/2026-10-10-documentation-handoff-design.md`

## Global Constraints

- 源码和当前工作区是事实基线；历史 xcresult/build 只能标为历史证据，不得写成本轮验证。
- 不修改业务源码、Podfile、Info.plist、CocoaPods、生产配置、远端 API、原始资料或用户已有改动。
- 不删除 `docs/superpowers/specs/`、`docs/superpowers/plans/` 或 `.superpowers/sdd/` 历史记录。
- 刷新请求 `/login/refresh` 也经 `NetWorkManager`；刷新端点自身返回 301/401 时必须记录静态递归/收口风险，不能声称所有刷新失败都可靠强制登出。
- 搜索歌单点击未接详情跳转；`/search/suggest` 和搜索历史未接当前结果页；广播分类、分页和独立重试 UI 未接通。
- RAC UI 订阅未全部保存/释放 disposable；不得把 weakify 描述成订阅生命周期闭环。
- 真机后台 session 交付、force-quit 后恢复、真实 CDN、断网离线人工播放和同长度内容损坏检测仍标为未验证。
- 不写入 Cookie、API key、token、真实 URL 参数或其他凭据；不提交、不推送、不改写 Git 历史。

## Review Focus

- **入口职责漂移：** 新 AI 是否能从 `docs/README.md` 明确知道当前事实、协作上下文、面试材料和历史计划的先后关系；由 Task 1 的链接/标题检查覆盖。
- **认证过度承诺：** 文档是否把刷新失败写成无条件收口，是否遗漏 `/login/refresh` 经同一恢复器的风险；由 Task 2 的关键词和段落检查覆盖。
- **计划/实现混淆：** 已接通、源码存在但未接线、未来建议和历史验证是否分开；由 Task 2/3/4 的边界清单检查覆盖。
- **证据伪造：** 是否把历史 result bundle、真实端点探测或静态源码审阅写成本轮 App/真机验证；由 Task 3/4/5 的验证命令覆盖。
- **删除造成断链：** 删除的 20 份根文档是否仍被保留文档引用，superpowers 历史路径是否意外受影响；由 Task 5 的路径存在性、引用扫描和工作区范围检查覆盖。

---

### Task 1: 建立文档接手入口

**Files:**
- Create: `docs/README.md`
- Read: `README.md`, `CLAUDE.md`, `docs/项目深度梳理.md`, `docs/面试技术亮点与优化点.md`

**Interfaces:**
- Consumes: 当前四份主文档的相对链接、源码事实入口和历史计划路径。
- Produces: 一个不复制完整实现细节的文档地图，后续任务将其作为所有入口文档的共同链接目标。

- [ ] **Step 1: 写入入口文档的固定结构**

按以下顺序创建章节，避免入口再次变成第二份事实手册：

1. `# NLSpotify 文档入口`
2. `## 快速接手路径`：先读 `README.md`，再读本文，随后读 `docs/项目深度梳理.md`；需要协作规则读根 `CLAUDE.md`，需要面试表达最后读面试文档。
3. `## 权威级别`：源码 > 当前事实文档/本入口 > 根 README/CLAUDE 协作摘要 > 面试材料 > superpowers 历史计划/spec；明确历史计划不等于当前实现。
4. `## 当前事实入口`：链接 `docs/项目深度梳理.md`，列出启动认证、内容发现、播放、缓存、下载、WCDB、歌词评论七条链路及关键源码目录。
5. `## 按任务查找`：用表格列出问题类型、先读章节和关键源码入口，例如认证看 `NetWorkManager`/`NLAuthManager`，缓存看 `NLResourceLoader`/`NLCacheManager`，下载看 `NLDownloadManager`/`NLOfflineAudioStore`。
6. `## 证据标签`：解释“源码事实”“本地历史测试证据”“真实端点只读探测”“未验证边界”四个标签。
7. `## 修改前检查`：要求先回源码、确认所有权层和调用方，不把建议/历史计划直接当实现。
8. `## 历史材料`：链接现有 `docs/superpowers/specs/`、`docs/superpowers/plans/` 和 `.superpowers/sdd/`，说明只用于了解设计/实施过程。
9. `## 文档整理边界`：说明本轮只改 Markdown，不运行 App/Test，不接通新业务。

每个链接使用仓库相对路径；不在入口复制 URL、Cookie、测试 token 或长伪代码。

- [ ] **Step 2: 验证入口自洽**

Run: `grep -nE '^#|\]\(' docs/README.md`
Expected: 入口包含上述职责章节，且所有链接目标使用相对路径。

Run: `test -f docs/项目深度梳理.md && test -f docs/面试技术亮点与优化点.md && test -f CLAUDE.md && test -f README.md`
Expected: 所有当前主文档存在。

---

### Task 2: 校准唯一当前源码事实文档

**Files:**
- Modify: `docs/项目深度梳理.md`
- Reference: `NLSpotify/Networking/网易云API/NetWorkManager.m`, `NLSpotify/Networking/网易云API/Login && 双Token/NLAuthService.m`, `NLSpotify/Networking/网易云API/Login && 双Token/NLAuthManager.m`, `NLSpotify/Modules/播放器/NLPlayerManager.m`, `NLSpotify/Modules/播放器/NLDownloadManager.m`

**Interfaces:**
- Consumes: Task 1 的入口链接约定；当前源码链路事实和已有文档内容。
- Produces: 唯一详细事实文档；Task 3/4 只从本文链接或引用事实，不再建立第二份全量手册。

- [ ] **Step 1: 修正认证刷新段落**

在“认证失效与根路由切换”及“失败与工程取舍”中保留已核对的 301/401 队列、单次重放和 `NLForceLogoutNotification`，并补充明确边界：`NLAuthService.refreshLoginWithSuccess:failure:` 通过 `NetWorkManager` 请求 `/login/refresh`；因此刷新端点自身再次返回 301/401 时会重新进入网络层恢复路径，当前静态实现存在递归/收口风险。用“正常业务请求的失败路径具备统一通知收口；刷新端点自举失败仍需专项修复/验证”替代“刷新失败必然可靠登出”的绝对表述。

- [ ] **Step 2: 校准内容、播放器、缓存、下载和辅助链路摘要**

保持现有已核实章节结构，只做必要定点修正：

- 将搜索边界固定为歌曲、歌单、艺人、歌词四段；说明 Service 支持电台类型不代表结果页已接电台段；歌单结果未实现详情跳转。
- 保留广播 `/dj/recommend` → `/dj/hot` 兜底 → `/dj/program` 的调用关系，说明无合法 `mainSong` 不创建播放意图。
- 保留播放优先级“离线正文 → 完整普通缓存 → 已有 URL → 获取 URL”，并明确 token/Item identity 是结果作废保护，不等于取消网络请求。
- 保留 L1/L2/L3、Range ledger、SHA-256 identity、ready gate、写入分片和 clear barrier；明确文件系统与 WCDB 不是跨系统原子事务，同长度内容损坏不能被当前长度检查发现。
- 保留下载 generation、Application Support 离线正文和完成事务顺序；将真机后台、force-quit、真实 CDN 和断网人工播放统一列为未验证。
- 保留歌词行级 LRC、评论 TextKit 折叠、RAC 五个信号和 WCDB writer queue；明确 UI disposable 生命周期不是全部闭环。

- [ ] **Step 3: 校准验证章节与接手入口**

在“验证证据与未验证边界”中把所有 result bundle/build 明确写成历史记录，不增加本轮运行结果；保留真实端点只读探测与其不能证明的范围。将“后续接手入口”链接到 `docs/README.md`，并把源码事实文档声明为静态链路导航而非源码替代品。

- [ ] **Step 4: 静态事实检查**

Run: `grep -nE 'login/refresh|递归|收口风险|歌单.*没有|RACDisposable|disposable|未验证|历史' docs/项目深度梳理.md`
Expected: 认证风险、搜索缺口、订阅边界和历史/未验证标签均可定位。

Run: `git diff --check -- docs/项目深度梳理.md`
Expected: 无空白错误。

---

### Task 3: 收口根 README 与 CLAUDE 协作职责

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Reference: `docs/README.md`, `docs/项目深度梳理.md`

**Interfaces:**
- Consumes: Task 1 的文档入口和 Task 2 的当前事实边界。
- Produces: 面向用户的项目简介/运行入口与面向 AI 的协作上下文；二者不再复制完整源码链路。

- [ ] **Step 1: 精简 README 的职责范围**

保留项目简介、截图、核心能力概览、稳定模块结构、技术栈、workspace 安装运行、API 来源的非敏感说明、当前边界和文档入口。删除或改写以下重复/易漂移内容：

- 用一句话链接 `docs/README.md` 和 `docs/项目深度梳理.md`，不在根 README 维护完整缓存/下载调用细节。
- 历史测试结果保留时明确为历史证据，并链接事实文档；不得写成当前真实端到端保证。
- `NLSearchSuggestService` 条目区分“类型搜索已接结果页”和“`/search/suggest` 下拉未接”。
- 不把“后台播放、锁屏控制”扩写成真机验收结论；保留为源码能力摘要并指向事实文档。
- 不写远端凭据、真实代理地址、Cookie 或 token。

- [ ] **Step 2: 精简 CLAUDE 的稳定协作信息**

保留语言、部署目标、架构、UI 方案、根路由、稳定目录层级、依赖用途、开发约定、构建入口、当前边界和文档入口。将易过期的完整文件枚举压缩为稳定模块地图，并将所有详细链路指向 `docs/README.md` / `docs/项目深度梳理.md`。补充“源码事实优先、历史验证不等于本轮验证”的协作规则；保留不修改业务源码/生产配置和不写凭据的约束。

- [ ] **Step 3: 处理共同边界的单一链接**

两份根文档都必须指向同一份当前事实文档；对认证刷新风险、RAC disposable、真机/CDN 未验证边界只保留短摘要，详细说明由 Task 2 负责。

- [ ] **Step 4: 检查职责与敏感词**

Run: `grep -nE 'docs/README\.md|docs/项目深度梳理\.md|当前边界|历史|未验证|Cookie|token|api[_ -]?key|Authorization' README.md CLAUDE.md`
Expected: 两个根文档都有文档入口和证据边界；只出现概念性字段名，不出现任何凭据值。

Run: `git diff --check -- README.md CLAUDE.md`
Expected: 无空白错误。

---

### Task 4: 收口面试材料并迁移可保留追问

**Files:**
- Modify: `docs/面试技术亮点与优化点.md`
- Read before deletion: `existing_qa.md`, `qa_additions.md`, `tech_qa.md`, `rac_supplement.md`, `playback_supplement.md`, `首页ViewModel面试讲解.md`

**Interfaces:**
- Consumes: Task 2 的源码事实；根目录碎片中已核实的面试问答。
- Produces: 单一面试材料；删除清单中的碎片稿不再承载唯一有效内容。

- [ ] **Step 1: 校准面试文档中的事实性表述**

保留可由源码或已有历史证据支持的内容：Range 缓存、token/generation、Cookie 队列、离线所有权、RAC、TextKit、歌词、搜索/广播边界。对下列内容使用保守表述：

- 刷新队列必须说明 `/login/refresh` 复用 `NetWorkManager` 的静态递归/收口风险。
- WCDB 只描述项目实际使用的 ORM/事务/写队列；删除“性能优于 Core Data”“当前启用加密”“腾讯生产验证”这类无项目测量或未启用功能断言。
- `AVAssetDownloadTask` 对比改为项目当前是单文件 `NSURLSessionDownloadTask`，若未来资源转 HLS 再评估 Apple HLS 离线路径；不写“只支持 HLS”这种超出当前资料边界的绝对归因。
- RAC 章节保留“当前若干 UI 订阅未保存 disposable”的诚实边界，不把示例代码写成当前实现。
- 删除签名 URL、CBR/Xing 头、Spotify 私有格式等未由项目源码/本轮资料证明的项目事实；若保留泛化追问，明确其为外部知识且不代表本项目实现。
- 历史测试结果注明日期和 result bundle 语义，不称为本轮重新验证。

- [ ] **Step 2: 合并有价值的问答并去重**

将首页并发的固定槽位/`dispatch_group` 取舍、下载 generation/`NSURLSessionDownloadTask`、缓存完整性边界、Token 与取消职责、CarPlay 尚未接 UI、搜索歌单未跳转等问答各保留一份，放在对应章节；删除重复伪代码，使用链接指向事实文档的详细链路。

- [ ] **Step 3: 维护面试文档入口说明**

在文首加入一句：本文仅用于面试表达和追问准备，当前实现以源码及 `docs/项目深度梳理.md` 为准；历史测试只按记录日期解释。

- [ ] **Step 4: 面试事实扫描**

Run: `grep -nE '性能优于|腾讯生产|已启用加密|CBR|Xing|签名 URL|只支持 HLS|刷新.*必然|真实 CDN|100/100|103/103|disposable' docs/面试技术亮点与优化点.md`
Expected: 无未经证实的项目断言；保留的性能/外部知识/历史结果均带限定语，RAC disposable 边界明确。

Run: `git diff --check -- docs/面试技术亮点与优化点.md`
Expected: 无空白错误。

---

### Task 5: 删除已迁移碎片并完成文档范围验证

**Files:**
- Delete exactly: `cache_consistency.md`, `cookie_refresh.md`, `download_state_machine.md`, `existing_playback.md`, `existing_qa.md`, `home_concurrent.md`, `integration_plan.md`, `interview_supplement_plan.md`, `new_h2_concurrent.md`, `new_h2_cookie.md`, `new_h2_download.md`, `new_h2_wcdb.md`, `playback_supplement.md`, `qa_additions.md`, `rac_supplement.md`, `review_plan.md`, `tech_qa.md`, `token_addition.md`, `wcdb_consistency.md`, `首页ViewModel面试讲解.md`
- Preserve: `docs/superpowers/specs/`, `docs/superpowers/plans/`, `.superpowers/sdd/`

**Interfaces:**
- Consumes: Task 1–4 已完成的入口、事实和面试材料。
- Produces: 无重复根级碎片、无被删除文件引用、保留历史目录不受影响的工作区。

- [ ] **Step 1: 删除精确清单中的 20 个文件**

只删除上面列出的文件；不得使用 `git clean`、目录级删除、重置或覆盖其他用户改动。`existing_playback.md` 的唯一内容为空行，其他文件必须已通过 Task 2/4 的文档内容承接后再删。

- [ ] **Step 2: 扫描删除文件引用与 Markdown 链接**

Run: `grep -RIn --exclude-dir=.git --exclude='*.xcresult' -E 'cache_consistency\.md|cookie_refresh\.md|download_state_machine\.md|existing_playback\.md|existing_qa\.md|home_concurrent\.md|integration_plan\.md|interview_supplement_plan\.md|new_h2_(concurrent|cookie|download|wcdb)\.md|playback_supplement\.md|qa_additions\.md|rac_supplement\.md|review_plan\.md|tech_qa\.md|token_addition\.md|wcdb_consistency\.md|首页ViewModel面试讲解\.md' .`
Expected: 除删除清单本身的历史说明外，不存在保留文档对这些碎片的引用。

Run: `python3 - <<'PY'
from pathlib import Path
import re
root = Path('.')
files = [Path('README.md'), Path('CLAUDE.md'), *Path('docs').rglob('*.md')]
missing = []
for path in files:
    text = path.read_text()
    for target in re.findall(r'\]\(([^)#]+)(?:#[^)]+)?\)', text):
        if '://' in target or target.startswith('#'):
            continue
        candidate = (path.parent / target).resolve()
        if not candidate.exists():
            missing.append(f'{path}: {target}')
if missing:
    raise SystemExit('\n'.join(missing))
print(f'checked {len(files)} markdown files; all relative targets exist')
PY`
Expected: 输出所有相对 Markdown 链接目标存在。

- [ ] **Step 3: 检查凭据模式和工作区范围**

Run: `grep -RIn --exclude-dir=.git --exclude='*.xcresult' -E 'sk-[A-Za-z0-9]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|Cookie:[[:space:]]*[^`[:space:]]+|JSESSIONID=[^;[:space:]]+' README.md CLAUDE.md docs || true`
Expected: 无命中；概念字段名（如 `Cookie`、`token`）不算凭据值。

Run: `git diff --check`
Expected: 无空白错误。

Run: `git status --short`
Expected: 只出现本计划新增/修改/删除的文档以及整理前已存在的用户工作区改动；不出现业务源码、Podfile、Info.plist 或其他生产配置变更。

- [ ] **Step 4: 记录验证边界**

在最终回复中明确：本轮验证了 Markdown 结构、相对链接、删除清单、凭据模式和 diff 空白；没有重新运行 App build、XCTest、真实 API、模拟器/真机 UI、真实 CDN、后台系统交付或断网人工播放。

本任务不提交 Git commit、不 push、不改写历史。

---

## Completion Checklist

- [ ] `docs/README.md` 是唯一文档发现入口，链接目标存在。
- [ ] `docs/项目深度梳理.md` 是唯一详细当前源码链路文档，认证刷新风险和未验证边界准确。
- [ ] `README.md` 与 `CLAUDE.md` 完成职责收口并链接入口。
- [ ] `docs/面试技术亮点与优化点.md` 无未经证实的项目事实，面试材料与实现规格分离。
- [ ] 精确 20 个根级碎片稿已删除，历史目录保留。
- [ ] Markdown 相对链接、凭据模式、diff 空白和工作区范围检查通过。
- [ ] 未运行不在范围内的 App/Test/真实环境验证，最终报告已标明。
