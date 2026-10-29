# Overtone 接入飞牛云 NAS：工作量评估

> 评估对象：当前 `Sources/JellyfinMac`（SwiftUI，15,850 行，只支持 Jellyfin 单后端）
> 参考对象：**飞牛音乐**（fnOS 原生音乐应用，2026-08-27 随 fnOS 正式上线，2026-09-16 独立 App 三端同步：iOS / Android / 鸿蒙；官方桌面端只有 Web，无 macOS）
> 评估日期：2026-10-28 · 人日口径：1 人日 = 6 小时有效编码，单人熟悉 SwiftUI 的中级工程师
> 证据分级：**V** 源码直读／本机实测 · **S** 一手页面或仓库静态文件 · **A** 第三方实测报道 · **C** 待验证 · **U** 未核实
> 三份支撑调研：`docs/research/fnos-music-api.md`（协议事实档，1,179 行）· `docs/research/overtone-backend-coupling.md`（代码耦合，677 行）· `docs/research/fnos-integration-alternatives.md`（备选路径，288 行）

---

## 0. 只记四件事

1. **「接入飞牛云 NAS」最省的做法是 0 行客户端代码，而且已经有人把桥搭好了。**
   - **音桥**（[qianlipp/fn-music-bridge](https://github.com/qianlipp/fn-music-bridge)，AGPL-3.0，Go）：一个装进 fnOS 的 FPK 应用，把飞牛音乐翻译成 **Jellyfin Audio / OpenSubsonic / Audio Station / Ampache**，Overtone 当前那 10 类端点它基本都实现了（§2.0，已源码核对）。
   - **在 NAS 上装 Jellyfin**：Overtone 也能直接连（这是「另一套库」，和飞牛音乐不互通）。
   - 两条都只需 **0.5~1 人日**做验证与文档，区别是前者**与手机上的飞牛音乐共用同一份曲库**。
2. **只有「自研飞牛音乐协议」这条才需要写代码**：常见 **16 人日**（精简）到 **31 人日**（可维护的双后端架构）。
3. **自研路径的工期不由 Swift 代码量决定，由一个实验决定**：飞牛音乐的 `authx` 签名到底强不强制。
   - 不强制 → 播放层半天搞定（Cookie 是静态头，`AVURLAsset` 注入即可）。
   - 强制 → 必须写 `AVAssetResourceLoaderDelegate` 给每个 Range/HLS 分片重签，**多 3~5 人日**且容易踩坑。
   - 一个 **0.5 人日的 spike** 就能定死这件事（§5）。
4. **「macOS 上没有飞牛音乐客户端」这个差异化假设不成立。** 猿音 / [Primuse](https://github.com/chenqi92/primuse)（★229，MIT，App Store 已上架）已经是 macOS/iOS/tvOS 端的多源音乐客户端，**同时支持 Jellyfin、Subsonic、Plex、Emby、SMB、WebDAV 和飞牛音乐**。所以自研的价值要从「填补空白」改写成「做更好的那一版」，同时它也是**可直接复用的 MIT 参考实现**（§6）。

---

## 1. 现状：两边各自是什么

### 1.1 Overtone 侧（V：源码直读）

- **单后端硬绑定**：`APIClient.shared` 被 **14 个文件**直接引用；`BaseItemDto` 出现 **110 次 / 22 文件**，其中 UI 层（Views + Components）**47 次 / 13 文件**——但 UI 真正读到的语义字段只有 **10 个**（`id/name/album/albumArtist/userData/时长/封面/type/collectionType`）。
- **实际只用 10 类 Jellyfin 端点**：登录、`/Users/Me`、`/Users/{uid}/Views`、`/Users/{uid}/Items`（一切列表都靠 `IncludeItemTypes`+`SortBy` 参数）、封面、歌词、收藏、`/Sessions/Playing*` 进度上报、歌单读写、`/Audio/{id}/stream` 播放。
- **三处关键假设**（后面全部会撞上飞牛）：
  1. `MusicDataStore.swift:213-233` 三次请求**把整个曲库拉进内存**，无 `Limit/StartIndex`；`:100-122` 在客户端做全量派生排序 —— 即「服务端无分页 + 已排序 + `userData` 齐全」。
  2. `MusicPlayerModel.swift:453-483` 同步拼播放 URL（`?static=true&api_key=` 或转码参数），`:340` `AVPlayerItem(url:)` —— **播放源被建模成一个裸 URL**。
  3. `JellyfinModels.swift:83-91` 的 `artworkURL()` 在**数据模型里反向调用 `APIClient.shared`** —— 多后端时这是死结，必须先断。

### 1.2 飞牛音乐侧（S + V：协议事实档）

- **接入形态**：`https://{nasHost}/music/` 或 FN Connect（`fnos.net/{fnId}/music/` 引导 → `POST /api/v1/fn/con` 定位 → relay 激活 → `mode=relay` Cookie）。fnOS 面板端口 `5666/5667`，音乐服务在 `/music` 前缀下。
- **认证**：`POST /api/v1/user/password-login` → `music-token` Cookie；请求可携带 `authx: nonce=…&timestamp=…&sign=MD5(前缀+"_"+path+"_"+nonce+"_"+ts+"_"+dataHash+"_"+KEY)`。**签名常量硬编码自 Web 静态包**（`AUTHX_PREFIX`、`MUSIC_API_KEY`）。
- **接口面**：只读 **34 个**（MVP 只需 12）、音乐侧写 **15 个**（收藏、歌单全生命周期、事件上报）——覆盖面比预期完整。
- **播放**：`/api/v1/track/stream?guid=` 文件直出，支持 `Range`/206；转码是真实的：`POST /track/transcode` → `/hls/{guid}/preset.m3u8`（Opus）＋ heartbeat/quit。
- **两个硬缺口**（决定产品范围，不是工作量）：
  - **没有播放进度上报**——`event/report` 只有 `track_play`（仅曲目 GUID，无 position）。Overtone 的「继续播放 / 进度同步」**无法平移**，只能本地存。
  - 没有专辑/艺人收藏、没有歌单重排端点、歌词只有 LRC 文本、封面只有 `coverId + size`（无 Backdrop/大图）。

---

## 2. 五条路径与价钱

| # | 路径 | 做什么 | 工作量（乐观/常见/悲观，人日） | 用户侧安装成本 | 抗升级 | 与飞牛音乐数据互通 | 推荐度 |
|---|---|---|---|---|---|---|---|
| **0** | **音桥直连**（最省的真接入） | NAS 装「音桥」FPK，它把飞牛音乐翻译成 Jellyfin Audio；Overtone 当普通 Jellyfin 连 `http://NAS_IP:14040` | **0.5 / 1 / 2**（验证＋2 处小补丁） | 装 FPK 5~10 min，绑定飞牛账号；**x86_64 only**、fnOS ≥ 1.2.0300 | 中（依赖第三方 FPK 的维护） | ✅ **同一份曲库** | ⭐⭐⭐⭐⭐ 先做这个 |
| **B** | **基线：NAS 装 Jellyfin** | 应用中心 / `.fpk`（端口 8097）/ Docker（8096）装 Jellyfin | **0**（+0.5~1 写指南＋真机回归） | 5~30 min，需另建库与账号 | **高**（两者解耦） | ❌ 另一个库 | ⭐⭐⭐⭐ 与路径 0 并行验证 |
| **A-min** | **自研飞牛协议（精简）** | 复用 `BaseItemDto` 做映射 + 后端分派；借 Primuse 的协议层 | **11 / 16 / 27** | 0 | **低**（每次官方升级 1~3 人日回归） | ✅ | ⭐⭐⭐ 音桥不够用时 |
| **A** | **自研飞牛协议（完整多后端）** | 领域模型层 + `MusicBackend` 协议 + 双适配器 | **19 / 31 / 44** | 0 | 低（同上） | ✅ | ⭐⭐ 长期才值 |
| **C** | **通用 Subsonic 后端** | NAS 装 Navidrome（4533），Overtone 加 Subsonic 适配 | **18~24**（常见 20） | 20~40 min ＋**重建曲库** | **最高** | ❌ 独立库 | ⭐⭐ 不是「接入飞牛」的答案 |

> **A 与 A-min 的差别不在功能，在「第二次加后端要几天」**：A-min 省 15 人日，但技术债留到下次；A 的抽象层（M1~M3，约 6 人日）**可以不等协议摸清就开工**，不阻塞。

### 2.0 路径 0 的证据：音桥到底覆盖到哪一步（源码核对，V）

`qianlipp/fn-music-bridge`（Go，AGPL-3.0，监听 `0.0.0.0:14040`，Jellyfin 协议挂在根路径下）——我按 Overtone 实际发起的每一个请求逐一比对了它的路由表与 `capabilities.go` 自述能力：

| Overtone 实际调用 | 音桥 | 结论 |
|---|---|---|
| `POST /Users/AuthenticateByName`（JSON `Username`/`Pw`） | ✅ 有；`parseProtocolForm()` 会把 JSON body 合并进 `Form`，恰好兼容 Overtone 的 PascalCase JSON | **登录可直接用** |
| `GET /Users/Me`、`GET /Users/{uid}/Views` | ✅ | 可用 |
| `GET /Users/{uid}/Items?Recursive&IncludeItemTypes&SortBy&ParentId` | ✅（自述「real pagination and counts」） | 可用，分页比 Jellyfin 式更完整 |
| `GET /Items/{id}/Images/Primary?maxWidth&tag` | ✅ | 可用 |
| `GET /Audio/{id}/Lyrics` | ✅（自述「lyrics reading」） | 可用 |
| `POST\|DELETE /Users/{uid}/FavoriteItems/{id}` | ✅ 曲目收藏（自述「song favorites」） | 可用；**专辑/艺人收藏不支持** |
| `GET /Audio/{id}/stream?static=true` | ✅ 直连 + Range | 可用 |
| `GET /Audio/{id}/stream?static=false&audioCodec=mp3…`（转码） | ❌ 自述「transcoding」不支持 | **设置页「音质」四档会失效**，只能「原始」 |
| `/Sessions/Playing{,/Progress,/Stopped}`（进度上报） | ✅ 三个路径都实现了（`jellyfinPlaybackEvent`），`/Sessions/Capabilities` 也返回 204 | 请求不会 404；但飞牛侧不存播放位置，所以仍**续不了播**（能报，不能读回） |
| `GET /Users/{uid}/Items/Search?SearchTerm=`（搜索页） | ❌ 音桥只实现 `/Search/Hints` 与 `Items?SearchTerm=` | **搜索页会 404** → 客户端改 1 行，或给音桥提 PR |
| `POST /Playlists`、`DELETE /Items/{id}`（歌单同步） | ✅ 歌单 CRUD（自述「playlists」）；**重排不支持** | 可用；「上移/下移」需降级 |

**所以「零改动」要打个折，但折扣很小**：登录/浏览/专辑/艺人/歌曲/封面/歌词/直连播放/收藏/歌单在音桥上都可用；需处理的是 **①搜索路径一行改动 ②音质档位置灰 ③歌单重排降级**——合计 0.5~1 人日，且 ①② 也可以直接在音桥里补（它是 AGPL 的开源项目）。

**限制（必须提前告知用户）**：音桥是个人项目（★7，2026-08 最后推送，AGPL-3.0），**x86_64 only**、要求 fnOS ≥ 1.2.0300；ARM NAS（如飞牛 EVO 系列）用不了。它适合「今天就验证需求」，不适合作为产品形态承诺。

---

## 3. 路径 A-min 的工作量拆解（若决定自研）

按「能登录 → 能浏览 → 能播放 → 能收藏 → 有歌词」的最小可用范围：

| 步 | 工作 | 文件 | 人日（常见） | 说明 |
|---|---|---|---:|---|
| 0 | **协议 spike**（§5，必须先做） | `scripts/fnos-probe.sh` | 0.5~1.0 | 5 个 curl 实验，决定后面全部 |
| 1 | 飞牛 HTTP 客户端：基址规范化、`authx`、Cookie、错误码 | 新增 `Networking/FeiniuClient.swift` | 2.0 | **可对照 Primuse `FnMusicAPIProtocol.swift`（1,078 行）** |
| 2 | JSON → `BaseItemDto` 映射（10 个字段）+ 分页/排序兜底 | 同上 / 新增 `FeiniuMapping.swift` | 1.0 | 飞牛 `page/size` 从 1 起、排序值 `字段,方向`、GUID 非 `Id` |
| 3 | 播放源：直链 + 转码回退（含 `AVURLAsset` 头注入，必要时 ResourceLoader） | `MusicPlayerModel.swift`、可选新增 `Player/ResourceLoader.swift` | **0.5 ~ 4.0** | **跨度全在那个 spike 结果上** |
| 4 | 封面 `/api/v1/static/cover?coverId=&size=`（缓存键不能用带签名的 URL） | `APIClient.swift`、`MediaComponents.swift` | 0.5 | 现有 `ImageCache` 键 = `absoluteString`，见 R6 |
| 5 | 收藏读写、歌词（LRC 解析）、事件上报 | `APIClient.swift`、`PlaybackReporter.swift` | 1.0 | LRC 解析约半天（Primuse `FnMusicLyricSelection` 可参考） |
| 6 | 数据层分派（全量拉取先不分页）+ 能力门控（无进度/无专辑收藏时置灰而非假装） | `MusicDataStore.swift`、`AppState.swift` | 1.5 | 飞牛没有 `userData`，「最常播放/最近播放/继续播放」要空态化 |
| 7 | 登录 UI：后端选择器 + 飞牛字段（FN ID / 地址 / 安全码） | `LoginView.swift` | 1.0 | 复用 `Components.swift:488` 的 `SegmentedControl` |
| 8 | 凭据与命名空间（Keychain service / UserDefaults 键加 scope，老数据迁移） | `KeychainHelper.swift`、`AppState.swift` | 1.5 | **不可回滚**，见 R8 |
| 9 | 联调回归（无测试 target，双后端 × 两视觉风格 × 五档断点手测） | `scripts/` | 2.0 | 建议先补 3 个纯函数单测做锚点，<0.5 人日 |
| | **合计** | | **11.5 → 16** | |

**口径对齐（为什么 §2 把 16 当「常见」）**：
- 上表相加、`authx` 不强制（step3 = 0.5）：**11.5 人日** ← 乐观档；
- `authx` 强制（step3 = 4.0，且 step1 因处理时间戳过期重签 +0.5）：**≈ 16 人日** ← 常见档；
- 若还要求「专辑/艺人收藏、歌单同步、完整分页」等延后项：**≈ 27 人日** ← 悲观档。
- 证据目前是 **2:2 平手**（Dart / PS5 两个可用实现完全不签；Swift / Kotlin 都签），所以不做乐观假设，把 **16** 作为常见值。

**路径 A（完整架构）比 A-min 多出什么**：领域模型层 M1（3.0）+ 网络设施 M2（1.5）+ 协议与注册 M3（1.5）+ 把 Jellyfin 10 类端点搬进适配器 M4（4.5）+ 数据层重写 M6（3.0）+ UI 47 处字段改名 M7（3.0）+ 歌单多后端 M9（2.5，可延后）＝ 毛额 19 人日；其中数据层与登录/凭据部分与 A-min 重叠约 4 人日，**净增 ≈ 15 人日（16 → 31）**。换来的是「第二年加第三个后端只要 5 人日」。

---

## 4. 功能落差：飞牛侧缺什么，产品上怎么降级

| Overtone 现有能力 | 飞牛音乐 | 必须做的产品决策 |
|---|---|---|
| 继续播放 / 进度同步（`/Sessions/Playing*`） | ❌ 无进度上报 | 改本地快照（`SessionCache` 式），并在 UI 说明「进度仅本机」 |
| 最常播放 / 最近添加（`playCount`/`dateCreated`） | ⚠️ 只有 `play-history` 列表 | 保留「最近播放」，砍掉「最常播放 Top10」或改本地统计 |
| 专辑 / 艺人收藏 | ❌ 只有曲目收藏 | 收藏按钮只出现在曲目行与正在播放页 |
| 播放列表上移/下移 + 双向同步 | ❌ 无重排端点 | 降级为「删 + 按序重加」，或只做本地排序不同步 |
| 音质档位（原始/320/192/128） | ⚠️ 只有原始 + Opus 转码（AAC 报 8192 不可用） | 设置页改成「原始 / 标准（Opus）」两档 + 能力门控 |
| 结构化歌词（`/Audio/{id}/Lyrics`，含时间轴） | ⚠️ 只有 LRC 文本 | 自己解析 LRC（半天） |
| 详情页大图 / Backdrop | ⚠️ 只有 `coverId + size` | 详情页头图改为封面放大 + 模糊，不动布局 |
| 媒体库（`/Users/{uid}/Views` + `ParentId`） | ⚠️ `/shared-library/list` 语义不同 | 协议里允许返回单元素「全库」，合并 3 处重复的 `resolveLibraryId` |

> 这张表的结论：**飞牛版 Overtone 会比 Jellyfin 版「少几个模块」，而不是「一样但换了服务器」**。这必须在动手前跟用户预期对齐，否则上线即差评。

---

## 5. 决定工期的 5 个实验（P0 spike，0.5~1 人日，先做这个）

按「能砍掉多少人日不确定性」排序：

| # | 实验 | 判定 | 影响 |
|---|---|---|---|
| 1 | **不带 `authx`、只带 `music-token` Cookie 的 `Range` 请求能否 206** | 能 → `AVURLAsset` 注入 Cookie 即可；不能 → 上 ResourceLoader | **3~5 人日差**（最大项） |
| 2 | **转码产物 Opus-in-HLS 能否被 AVPlayer 播** | 不能 → APE/DSD/WMA/OGG 用户**无解**，只能明确降级提示 | 产品范围 |
| 3 | **FLAC 直连在 macOS 是否稳定** | Primuse 注释显示有坑（其 macOS 侧绕开 AVPlayer 走 libFLAC） | 播放层可靠性 |
| 4 | **`duration` 单位是秒还是毫秒** | 两套都要兼容（PS5 客户端用 20000 阈值判断） | 进度条错位/自动跳歌 |
| 5 | **官方 Web 静态包的签名常量是否随版本变** | 变 → 每次升级回归成本 1~3 人日 | 长期维护成本 |

> 工时分配：1 与 2 各半天，3~5 各 1 小时。**这一轮不做 UI、不写 Swift**，纯 curl + 一个 60 行探针脚本。做完才知道该报 16 人日还是 31 人日。

---

## 6. 一个必须知道的外部事实：Primuse / 猿音

| 项 | 内容 |
|---|---|
| 仓库 | `chenqi92/primuse`（★229，**MIT**，2026-10-27 仍在活跃提交，Swift 10,000+ 行） |
| 形态 | macOS / iOS / tvOS 音乐 App，**App Store 已上架**（搜「猿音」或 Primuse） |
| 已支持的源 | **飞牛音乐**、Jellyfin、Subsonic、Plex、Emby、SMB、WebDAV、网盘 |
| 对本次评估的两个含义 | ①**差异化不成立**：macOS 上「听飞牛音乐」已有人做了，要做到「更好」得靠 Overtone 的界面与中文体验（v3 玻璃 / v4 纸墨、五档断点、1,809 行设计令牌），不是靠「独占」；②**成本大幅下降**：`FnMusicAPIProtocol.swift`(1,078) + `FnMusicLibraryClient`(537) + `FnMusicServiceClient`(924) + `FnMusicStreamResolver`(381) + `FnMusicLyricSelection`(209) + `FnMusicSource`(767) ≈ **4,900 行 MIT 生产代码 + 2,900 行测试**，含 **authx 的 Swift 实现、FN Connect 解析器、AVPlayer 分片代理（400+ 行）** |

**这条事实是本评估里最有价值的发现**：它把路径 A 的置信度从「低」抬到「中」，也让「先做 spike 再决定」变得更划算（spike 甚至可以拿 Primuse 直接对着真机验）。

**但请注意 MIT 的边界**：抄代码可以，抄不来它的维护承诺。若长期跟随飞牛音乐升级，自己仍需要一份回归探针（`api.md` 的验证脚本改造成 CI，约 0.5~1 人日一次性投入）。

---

## 7. 风险登记（按对工期的影响排序）

| # | 风险 | 证据 | 缓解 |
|---|---|---|---|
| **R1** | **`authx` 是否强制未定**（Dart/PS5 两个可用实现完全不签，Swift/Kotlin 都签） | 协议档 §2.1 | 实验 1；不强制就按静态 Cookie 设计 |
| **R2** | **播放源不是 URL** 是架构级问题：`MusicPlayerModel.swift:453-483` 同步拼 URL，`:340` `AVPlayerItem(url:)`；`loadCurrent()` 有 **10 个调用点** | V | 协议里返回 `PlayableSource` 描述符而非 `URL`；MVP 先验直链 |
| **R3** | **签名常量来自 Web 静态包，升级即可能变** | 协议档附录 A | 常量集中一处 + 版本探测 + CI 探针 |
| **R4** | **「全量入内存 + 客户端派生」假设**（`MusicDataStore.swift:213-233`）：飞牛强制分页后，首页四个模块与三种排序全部失真 | V | 分页窗口化，或先接受「首屏 N 千首」的上限并显式提示 |
| **R5** | **飞牛无 `userData`** → 收藏态/播放统计静默缺失，用户以为「坏了」 | S | `BackendCapabilities` 门控 + 空态文案（不能只留白） |
| **R6** | **图片缓存键失效**：`ImageCache` 键 = `url.absoluteString`（`MediaComponents.swift:16`），若 URL 带时间戳签名则滚动即重下 | V | 封面统一走 `ArtworkRef.cacheKey`（`coverId+size`） |
| **R7** | **多服务器凭据互相覆盖**：Keychain `service` 写死 `com.jellyfin.mac-client`、account = 用户名 | V | 加 `scopeID` 命名空间 + 一次性迁移；**不要改 Bundle ID / 目录名**（`docs/naming.md` 明确说会丢列表） |
| **R8** | **没有测试 target**，回归全靠手测；双后端 × 两风格 × 五档断点 ≈ 20 组 | V（`Package.swift` 只有 `executableTarget`） | 预留 2 人日；先补 3 个纯函数单测 |
| **R9** | 自签 HTTPS 证书 + `AVPlayer` 自有网络栈，`URLSession` 的信任策略未必覆盖 | C | P0 只承诺 http 内网 / 可信 https |
| **R10** | CUE 整轨、`accessStatus != 0` 不可播曲目、416 越界 | S | 逐条按协议档 §7.7 的 15 条坑清单处理 |
| **R11** | 若将来要上 App Store：`AVURLAssetHTTPHeaderFieldsKey` 是非公开键，审核有拒的风险 | C | 上架前换成 `AVAssetResourceLoaderDelegate`（+1~2 人日）；本项目若只做个人使用则可忽略 |

---

## 8. 推荐路线图

**第 0 步｜本周，0.5~1 人日，不写功能代码：先用路径 0 把需求验掉**
- 装「音桥」FPK → 绑定飞牛音乐账号 → 用 Overtone 当 Jellyfin 连 `http://NAS_IP:14040`；
- 按 §2.0 那张表逐项过一遍，记录真实可用项（这份清单本身就是最有价值的资产）；
- 顺手补上搜索路径（1 行）与音质档位的能力门控（半天）。
- **产出**：Overtone 能播飞牛音乐的**同一份曲库**（收藏/歌单也通），代价 1 人日以内。
- **同时**（并行、不冲突）：写一篇《在 fnOS 上安装 Jellyfin 并连接 Overtone》，给 ARM 用户和「不想装第三方 FPK」的用户兜底——端口提醒：应用中心/`.fpk` = **8097**、Docker = 8096、面板是 5666/5667 别填错。

**第 1 步｜0.5~1 人日：跑 §5 的 5 个实验，决定要不要真的写代码**
- **闸门**：实验 1 和 2 都过 → 值得投 A-min；任一失败 → 停在路径 0 + Jellyfin 兜底，把省下的 16 人日花在界面与体验上。
- 注意：如果路径 0 已经满足使用，**这一步的结论大概率是「不值得自研」**——那也是一个成功结论。

**第 2 步｜若过闸，16 人日（业余约 3 周 / 全职 1 周）：A-min**
- 里程 1（5 人日）：登录 + 曲库/专辑/艺人浏览 + 直连播放 → **可自己用了**；
- 里程 2（6 人日）：封面 + 收藏 + 歌词 + 转码回退 + 能力门控；
- 里程 3（5 人日）：凭据命名空间、登录页后端选择、回归手测。

**第 3 步｜只有前两步都证明「有人在用」才做**：升级到路径 A（+15 人日），把 Jellyfin 也搬进适配器，从此第三个后端 5 人日。**不要一上来就做 A**——它的 6 人日抽象层在「飞牛只有你一个人用」时是纯沉没成本。

**明确不建议**：先做 C（Subsonic）。它花 20 人日、要求用户另装 Navidrome、还得重建曲库，却和「接入飞牛云」这个诉求毫无关系——它只对「Overtone 要做通用播放器」这个更大的野心有意义。

### 8.1 验收标准（路径 0 / A-min 通用）

1. 能用飞牛账号登录，重启免登录；
2. 资料库能列出专辑/艺人/歌曲，专辑内曲序正确；
3. 点一首歌能播完并自动下一首（顺序播放），Range seek 正常；
4. 迷你条 / 正在播放页的标题、艺人、封面正确；
5. 收藏能写回服务端（重新进入仍是已收藏）；
6. 失败态可见：地址错、账号错、token 失效、NAS 离线各有明确提示；
7. 明确不支持的能力**置灰 + 给文案**，不是静默失败；
8. **Jellyfin 侧全路径零回归**。

**自研路径（A-min/A）追加**：搜索四类结果分组正确 · 收藏双向同步 · 歌词按 LRC 逐行滚动（纯文本降级） · 不支持格式（APE/DSD/WMA）明确提示而非静默跳歌 · 大曲库（≥5,000 首）首屏 < 2s · 双视觉风格 × 五档断点抽测通过。

**本评估明确不做（第一期）**：NAS 账号 OAuth 扫码、多服务器同时在线、DLNA/AirPlay 投屏、CUE 整轨拆分、每日推荐/私人 FM、专辑/艺人收藏。（原列表里的 FN Connect 已在后续补齐。）

---

## 9. 结论

| 如果你的真实诉求是… | 该做什么 | 成本 |
|---|---|---|
| 「想让 Overtone 播我 NAS 上飞牛音乐的那个库」 | **路径 0：装音桥 FPK，Overtone 直连 14040** | **0.5~1 人日**（x86_64 NAS） |
| 「只想在飞牛 NAS 上用自己的播放器听歌，不在乎哪个库」 | **B**：装 Jellyfin ＋ 一篇指南 | **0.5~1 人日** |
| 「要产品化：不依赖第三方 FPK、和官方三端同库、能长期跟版本」 | 先 spike（0.5~1）→ 过闸后 **A-min** | **16 人日**（悲观 27） |
| 「想长期做多源客户端」 | **A**（把抽象层做好） | **31 人日**，或 A-min 后 +15 |
| 「想验证这件事值不值得做」 | **路径 0**：成本最低、信息量最大 | **≤1 人日** |

**一句话**：这个任务比看起来便宜得多——**飞牛音乐本身没有公开 API，但社区已经把它桥接成了 Jellyfin 协议**，而 Overtone 恰好就是一个 Jellyfin 客户端，所以「接入飞牛云」的第一版几乎不用写代码。真正要花 16~31 人日的是「不再依赖那座桥、自己成为飞牛音乐客户端」——那是一个**产品定位决策**，不是技术决策。而在做这个决策之前，还有一个事实要正视：猿音/Primuse 已经用 MIT 的开源方式在做同一件事了。

---

## 10. 立项前要钉死的 5 个问题

1. **目标**：自用尝鲜，还是长期并列支持 Jellyfin？——决定是 1 人日、16 人日还是 31 人日。
2. **NAS 架构是 x86_64 吗？**——决定能不能用「音桥」做 0 成本验证（ARM 用不了）。
3. **首版能否接受「无跨端续播、无播放次数、只有曲目级收藏」？**——不能接受就要先改产品预期，而不是加代码。
4. ~~是否需要 FN Connect 远程访问？~~ **已实现**（FN ID 即填即用）；剩余成本在自签证书信任与 relay 稳定性验证。
5. **是否会分发（App Store / 对外发布）？**——会的话，播放请求头的实现方式与 AGPL 依赖都得重新设计（R11）。

---

## 11. 实施结果（2026-10-28，路径 A 已落地）

> 结论：**完整多后端架构 + 飞牛音乐适配器已实现并通过编译/自检**；
> 飞牛侧的协议细节仍需真机验证（见 §11.3），Jellyfin 侧为纯重构（界面与行为不变）。

### 11.1 实际交付

| 项 | 结果 |
|---|---|
| 代码规模 | 新增 **~4,600 行**（`Backend/` 2,467 + `Models/Domain` 275 + `State/Local` 638 + `Player/MediaResourceLoader` 741 + `Networking/HTTPClient` 177 + `Diagnostics` 324），改动 27 个文件（+1,336 / −1,446），删除 4 个旧文件（`APIClient` / `JellyfinModels` / `PlaybackReporter` / `MusicViewModels`） |
| 领域模型 | `MediaItem`（含 `genres` / `childCount` / `userData`）、`ArtworkRef`（稳定缓存键）、`Paged`、`SearchResults`、`MusicLibrary`、`BackendUser` |
| 协议 | `MusicBackend`（会话 / 浏览 / 媒体 / 写 / 远程歌单 20+ 方法）+ `BackendCapabilities` + `PlayableSource` + `RequestAuthorization` |
| Jellyfin 适配 | 10 类端点全量搬入 `Backend/Jellyfin/`，行为与改造前一致（`MediaBrowser` 头、PascalCase 解码、`/Sessions/Playing*` 上报） |
| 飞牛适配 | **27 个端点**：登录/会话、库、曲目/专辑/艺人/搜索、封面、歌词（LRC→秒）、直连流 + 转码 HLS、收藏、播放事件、歌单全生命周期；`authx` 签名、地址规范化（5 种输入）、宽容 JSON 信封（`Backend/Feiniu/` 8 个文件） |
| 播放链路 | `PlayableSource` → `AVURLAsset`；**动态凭据（飞牛 authx）走 `AVAssetResourceLoaderDelegate` 逐请求重签**，固定头走 `AVURLAssetHTTPHeaderFieldsKey`，HLS 播放列表被改写使分片也逐片重签 |
| 本地兜底 | `LocalLibraryState`：续播位置 / 播放次数 / 最近播放 / 专辑艺人收藏，按「后端+账号」作用域落盘（debounce + 退出前 flush），`merge` 规则见架构文档 §3.3 |
| 界面 | 登录页后端选择器 + 飞牛安全码；设置页后端切换、服务器地址、能力门控（音质/进度上报/音量归一化置灰）；资料库加载状态横幅（失败/截断/部分失败）、搜索本地降级提示；专辑页流派与曲目数 |
| 验证 | `./scripts/dev-typecheck.sh` → **Build complete!**；`./scripts/dev-test.sh` → **51 项断言全过**；`./scripts/build-app.sh` → **build/Overtone.app 打包成功** |

### 11.2 与评估的偏差

| 评估项 | 评估值 | 实际 |
|---|---|---|
| 完整方案（A） | 常见 **31 人日** | 本次约 1 个工作日量级（多 agent 并行）+ 交付面基本对齐 M1~M12（M9 播单多后端做了但重排仍降级） |
| 工期最大变量 `authx` | 强制与否差 3~5 人日 | **两种实现都写了**（`authxEnabled` 开关 + `isDynamic` 声明），不再需要先判定：真机若 401 就关掉签名走静态头 |
| Primuse 参考 | 可对照的 MIT Swift 实现 | 实际**没有逐行移植**（协议档 + 3 个第三方客户端的行为已足以写出适配器），仅作为交叉验证 |
| 「没有测试 target」风险 | 建议补 3 个纯函数单测 | 因 CLT 无 XCTest，改为**内建 `--selftest`**（51 项断言），无需 Xcode 与服务器即可跑 |

### 11.3 必须真机验证的 5 件事（按风险排序）

1. **`authx` 是否强制 + Range 能否 206**：`curl -H "Cookie: music-token=$T" -H 'Range: bytes=0-1'`；
   不强制则把 `FeiniuBackend.authxEnabled` 置 false（播放走静态头，最省）。
2. **转码 Opus-HLS 能否被 AVPlayer 播**：不能则 APE/DSD/WMA 用户无解，需明确提示。
3. **HLS 分片是否回到 `MediaResourceLoader`**：不回到则需 loopback 代理兜底（`// TODO(C)` 已留）。
4. **`duration` 单位与收藏 body 大小写**（`trackGUID` vs `trackGuid`）：错了只表现为「时长差 1000 倍」或「收藏静默不生效」，用 `favorite-track/list` 回查。
5. **自签 HTTPS 证书**下 AVPlayer 的信任表现（第一版承诺 http 内网 / 可信 https）。

### 11.4 明确留白

~~FN Connect~~（**已补**：FN ID 自动定位/选路/中继，见架构文档 §6）、飞牛转码预热/心跳、
CUE 整轨偏移、`accessStatus != 0` 曲目标灰、多服务器同时在线、曲库真分页懒加载、
播放列表拖拽排序 —— 均已在架构文档 §7 列明。

---

## 附录：支撑文档索引

| 文档 | 内容 | 行数 |
|---|---|---|
| [`docs/research/fnos-music-api.md`](research/fnos-music-api.md) | 34 只读 + 15 写接口全表、`authx` 与 FN Connect、转码契约、字段表、15 条坑、16 个未解问题、可执行 curl | 1,179 |
| [`docs/research/overtone-backend-coupling.md`](research/overtone-backend-coupling.md) | 76 个带行号的耦合点、`MusicBackend` 协议草案、M1~M12 三档估算、R1~R12 风险、MVP 切片 | 677 |
| [`docs/research/fnos-integration-alternatives.md`](research/fnos-integration-alternatives.md) | Jellyfin-on-fnOS 三条安装通道、DLNA/SMB/WebDAV 排查、Subsonic 对比、客户端生态、未核实清单、Primuse 复核补注 | 288 |
| 外部参考 | [seasonyuu/FnMusic `api.md`](https://github.com/seasonyuu/FnMusic)（41 PASS 实测逆向文档）· [qianlipp/fn-music-bridge](https://github.com/qianlipp/fn-music-bridge)（音桥：飞牛音乐 → Jellyfin/OpenSubsonic 协议桥，AGPL-3.0）· [chenqi92/primuse](https://github.com/chenqi92/primuse)（MIT，Swift 多源客户端）· [conversun/fnos-apps](https://github.com/conversun/fnos-apps)（fnOS 第三方 `.fpk` 商店） | — |
