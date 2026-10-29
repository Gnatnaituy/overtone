# Overtone 能力基线（工作区实测）

> 审计对象：`/Users/ravooo/Code/Github/overtone` 工作区（**含未提交的多后端重构**；git HEAD `a7eedc7`，工作区新增 `Backend/`、`Diagnostics/`、`Models/Domain/`、`State/Local/`、`Player/MediaResourceLoader.swift`，删除旧 `JellyfinModels/APIClient/PlaybackReporter/MusicViewModels`）。
> 判定口径：**一律以工作区源码为准**；README / docs 只作线索（已发现多处文档-代码漂移，见 §14）。
> 证据格式：`文件:行号`（路径相对仓库根）。全程只读，未修改任何源码。
> 自检实跑（2026-10-29）：`./scripts/dev-test.sh` → `[selftest] ✓ 78 项断言全部通过`（README 与架构文档写「51 项」，已过时）。
> 规模：`Sources/JellyfinMac/**` 共 50 个 Swift 文件、22,106 行（`find Sources -name '*.swift' | xargs wc -l`）。

## 0. 一句话定位

Overtone 是 **Jellyfin / 飞牛音乐（fnOS）双后端的 macOS 流媒体音乐客户端**：服务端负责曲库与元数据，客户端负责浏览、播放、歌词、播放列表同步与本地兜底，**不是本地曲库管理器**。这一条决定了后文「缺失项该不该做」的判定边界。

## 0.5 审计覆盖与口径

- **精读**（逐行）：`JellyfinApp.swift`、`State/AppSettings.swift`、`State/AppState.swift`、`Views/SettingsView.swift`、`Views/MainView.swift`、`Views/Music/NowPlayingView.swift`、`Player/MusicPlayerModel.swift`、`Backend/MusicBackend.swift`、`Models/Domain/MediaModels.swift`、`Backend/Feiniu/FeiniuLyrics.swift`、`Components/Components.swift`（快捷键/组件段）、`Theme.swift`（令牌/断点段）、`Diagnostics/SelfTest.swift`（入口/断言段）。
- **结构+关键段**（大纲 + 关键函数 + grep 交叉验证）：`HomeView`、`MusicLibraryView`、`MusicAlbumView`、`MusicArtistView`、`PlaylistDetailView`、`PlaylistsView`、`MusicSearchView`、`DiscoverPages`、`LoginView`、`MediaComponents`、`MiniPlayerBar`、`QueuePanelView`、`PaperComponents`、`MediaResourceLoader`、两个后端适配器、`State/Local/LocalLibraryState`、`PlaylistStore/SyncService`、`Networking/HTTPClient`、`BackendRegistry`。
- **文档**：README、`docs/architecture-multibackend.md`、`docs/ui-design/UI-Redesign-v4.md`、`UI-Design-Spec.md`、`UI-Redesign-v5.md`（未落地）、`docs/research/{fnos-music-api,feiniu-backend-notes,local-fallback-notes,fnos-integration-alternatives,overtone-backend-coupling,client-scraping-sources}.md`、`docs/fnos-integration-assessment.md`。
- 判定原则：**grep 到的代码才写「有」，只看到注释/TODO/文档的一律写「无」或「部分」**；不运行网络请求（无真实服务器），不修改源码。

## 1. 页面与导航

| 一级页 | 实现 | 备注 |
|---|---|---|
| 首页 | `Views/HomeView.swift` | 问候语+账号菜单（收藏/最近/最常）、继续播放（最多 6 张，按专辑去重）、4 个快速入口（收藏/最近播放/最常播放/随机播放全部）、最近添加（网格+3 种排序）、最常播放 Top10 |
| 资料库 | `Views/Music/MusicLibraryView.swift` | 专辑/艺人/歌曲/播放列表 4 分段、网格/列表双视图、排序菜单、骨架屏、空态、超限提示 |
| 播放列表 | `Views/Music/PlaylistsView.swift` | 「我创建的」+「智能列表」两区块；新建/重命名/删除、服务器同步状态 |
| 正在播放 | `Views/Music/NowPlayingView.swift` | 大封面/歌词二选一、氛围取色、5 键控制、进度条、待播清单（W3+ 右栏 / 窄窗抽屉）、睡眠定时 |
| 搜索 | `Views/Music/MusicSearchView.swift` | 常驻搜索框、历史胶囊（8 条）、结果按歌/专辑/艺人/播放列表分组、本地兜底提示 |
| 二级详情 | `MusicAlbumView` / `MusicArtistView` / `PlaylistDetailView` / `DiscoverPages.TrackListPage` | 面包屑+大封面头部+曲目表（收藏/下一首播放/加入队列/曲目信息） |

- 导航模型：`ContentPage` 枚举 + 单栈（一级切换=替换栈，二级=push），`MainView.swift:5-46,115,630-660`。
- 侧栏：完整 240pt（可拖 180–320，`Theme.Size.sidebarMin/Max`）↔ 64pt 图标栏；W1 额外提供 240pt 覆盖式抽屉（`MainView.swift:237-340`）。
- 顶栏 64pt 常驻搜索框（W2+ 显示 ⌘F 提示）；迷你播放条 68/60pt 三区（窄窗降级两区）。
- 窗口：单主窗口 + 独立设置窗口；红黄绿三键保留并移进悬浮侧栏（`State/WindowConfigurator.swift`），透明标题栏 `JellyfinApp.swift:40`，最小窗口 520×480。

## 2. 五档断点（代码实际值）

`Theme.swift:1654-1809` 用**窗口宽度**划分（`from(windowWidth:)`，`MainView.swift:134`）：

| 档 | 窗口宽阈值 | 侧栏 | 页面边距 | 网格 min | 关键降级 |
|---|---|---|---|---|---|
| W0 | < 640 | 图标栏 64 | 16 | 140 | 播放条两区、隐藏音量与时间码 |
| W1 | 640–859 | 图标栏 64 + 抽屉入口 | 20 | 150 | 详情页纵向堆叠、待播改抽屉 |
| W2 | 860–1099 | 完整侧栏 220 | 24 | 160 | 显示音量区 |
| W3 | 1100–1419 | 完整侧栏 240 | 28 | 180 | 显示时间码、正在播放右栏 320 |
| W4 | ≥ 1420 | 完整侧栏 240 | 32（内容最大 1440 居中） | 200 | — |

⚠️ 漂移：`Theme.swift:1686` 注释写「520/760/1000/1180/1440」，与代码阈值（640/860/1100/1420）不一致；`docs/ui-design/UI-Design-Spec.md:334-344`（内容宽 640/820/1024/1340）与 v4 规范 §5（<620/<820/≥820）又各是一套。**以代码为准**。`from(contentWidth:)` 无调用点。

## 3. 视觉风格现状

- 两套并存皮肤（`Theme.VisualStyle`，`Theme.swift:71-96`；设置即时切换、重启保持）：
  - **glass**（v3 Liquid Glass，默认）：玻璃材质 + 圆角 10/14 + 投影分层，共享 `GlassTokens`；
  - **paper**（v4「纸带与信号」）：纸/墨/信号红、1px 细线、零投影、规则标签、VU 段条、衬线标题（`Theme.Paper` 776-915、`Components/PaperComponents.swift`）。
- 双主题：浅色/深色/跟随系统，令牌为动态色，切换不重建视图树（`Theme.swift:20-38,125-131`）。
- 强调色：**已实现 4 预置**（信号红/靛蓝/泛音青/紫，`AppSettings.swift:64-89`），并按皮肤取不同色阶（`AccentRamp.forChoice(_:style:)`）；无自定义取色器。v5「暖阳胶片」规范与预览已写（`docs/ui-design/UI-Redesign-v5.md`）但**未落地**（README:124）。
- 令牌齐全：字号阶梯 11–34pt 随系统缩放（`Theme.swift:1049-1145`）、间距/圆角/阴影/动效/尺寸（916-1048）、两套令牌实例稳定。
- 减少动态效果/降低透明度：系统级 + 应用内设置合并（`JellyfinApp.swift:171,199-202`；`AccessibilityDisplayObserver` Theme:1371-1395）。

## 4. 后端协议 MusicBackend（方法面与能力矩阵）

协议在 `Backend/MusicBackend.swift:194-259`，共 22 个方法 + 4 个属性（kind/capabilities/session/playbackPreferences）：

- 会话：`signIn / validateSession / signOut`
- 媒体库/浏览：`libraries / items(in:kind:sort:offset:limit:) / albumTracks / artistAlbums / artistTracks / search`
- 媒体：`artworkURL / authorizedImageRequest / lyrics / playableSource`
- 写：`setFavorite / report(PlaybackEvent)`
- 远程播放列表（7 个）：`remotePlaylists / remotePlaylistEntries / createRemotePlaylist / updateRemotePlaylist / deleteRemotePlaylist / addRemotePlaylistTracks / removeRemotePlaylistEntries`
- 默认实现统一抛 `.unsupported`（`MusicBackend.swift:261-324`）；`PlayableSource` 带 `authorization(headers+isDynamic) / isHLS / playMethod / unplayableReason / transcodeFallback`（143-153）。

**能力矩阵（实际生效声明）**：Jellyfin `MusicBackend.swift:59-71`；飞牛 `FeiniuBackend.swift:24` 使用**重写副本** `BackendCapabilities.feiniuBackend`（941-967），而非协议层 `.feiniu`（73-85，已过时：其中 `search=false`，而飞牛实际实现了搜索并在重写副本里置 true）。

| 能力 | Jellyfin | 飞牛 | 关闭时行为 |
|---|---|---|---|
| serverPaging | ❌ | ✅ | 飞牛强制 page/size |
| playbackProgress | ✅ | ❌ | 进度间隔置灰、续播走本地 |
| playStats | ✅ | ❌ | 最常播放用本地统计 |
| trackFavorites | ✅ | ✅ | — |
| albumArtistFavorites | ✅ | ❌ | 专辑收藏按钮置灰+本地记忆 |
| transcode | ✅ | ✅（Opus/HLS，仅一档） | 音质/直连/音量归一化置灰 |
| lyrics | ✅ | ✅ | 不对 |
| remotePlaylists | ✅ | ✅ | 不同步 |
| playlistReorder | ✅ | ❌ | 飞牛只改本地 |
| search | ✅ | ✅（3 接口并发） | 本地匹配+提示 |
| artistBrowsing | ✅ | ✅ | — |

- Jellyfin 适配：`/Users/AuthenticateByName`、`/Users/Me`、`/Sessions/Logout`、`/Views`、`/Items`×4、`/Items/Search`、`/Images`、`/Audio/{id}/Lyrics`、`/Audio/{id}/stream`、React `FavoriteItems`、`/Sessions/Playing*`、`/Playlists*`（`JellyfinBackend.swift` 全文 490 行）。
- 飞牛适配：`authx` 逐请求签名 + `music-token` Cookie + 27 端点（登录/库/专辑/艺人/曲目/搜索/封面/歌词/直链/转码/事件/收藏/歌单全生命周期），见 `FeiniuBackend.swift`、`docs/research/feiniu-backend-notes.md:26-96`。
- 能力门控写法：UI 读 `AppState.capabilities`（`AppState.swift:43`），不写后端类型判断；例 `SettingsView.swift:154-200`、`MusicAlbumView.swift:175-239`。

## 4.5 会话、凭据与网络安全（现状）

- 会话持久化：`SessionPersistence` 把 `BackendSession`（JSON：backend/serverURL/username/token/userID/extraCookie/fnID）写 UserDefaults 键 `backend.<kind>.session`；密码进钥匙串（service `com.jellyfin.mac-client`，account `<kind>|<username>`），旧版单后端键一次性迁移（`BackendRegistry.swift:3-31,120-158`）。
- Token **不在钥匙串**：`KeychainHelper.swift:9-14` 明确注释「ad-hoc 签名每次重建会让 ACL 失配弹授权框，token 必须在启动路径无感」→ 会话 token 明文存在 UserDefaults 的 JSON 里。安全等级取决于本机账户隔离，做「多用户/共享 Mac」功能时要重新评估。
- HTTP：每个后端独立 `URLSession` + 独立 `HTTPCookieStorage`（避免切后端串会话，`HTTPClient.swift:33-40`）；Jellyfin 用 `Authorization: MediaBrowser …` 头、飞牛用 Cookie + `authx`；封面等非 API 请求由 `authorizedImageRequest(for:)` 补凭据（飞牛经中继还要 `mode=relay`）。
- TLS：自签证书只对**私网主机**放行（`FeiniuFNConnect.swift:458-498` 的 `SelfSignedHostDelegate`，`.local/10./192.168/…`），relay 与公网域名仍走系统校验（自检里有断言，`SelfTest.swift:414-418`）。
- 无遥测/无崩溃上报（`grep -rn "analytics|telemetry|sentry|bugsnag|Crashlytics"` → 0）；无应用内日志导出；调试信息走 `print` 与 `--selftest/--fn-resolve/--feiniu-validate` 命令行。

## 4.6 飞牛 FN Connect（远程访问现状）

- 输入 FN ID（如 `ravooo`）或 `https://fnos.net/{id}/music`，`FeiniuAddress.resolve` 自动选路：`POST https://{5ddd.com|fnos.net}/api/v1/fn/con` 定位 → 生成候选（内网 IPv4/IPv6 → 内网 https → 公网 IPv6 → 公网 IPv4 → DDNS → relay）→ 按批并发探测 → 取第一个可达基址（`Backend/Feiniu/FeiniuFNConnect.swift:122-456`，498 行）。
- 两种签名：`authx`（5ddd.com）与 `fn-sign`（SHA256("trim_connect`{fnId}`{ts}anna")，fnos.net）；**定位 key 与音乐 key 不同**（docs/architecture-multibackend.md:153-155）。
- 中继：直接带 `Cookie: mode=relay`，域名必须命中 `*.fnos.net`/`*.5ddd.com` 白名单，relay Cookie 存进 `BackendSession.extraCookie`，API/封面/播放三条链路共用（`FeiniuBackend.swift:720-753`）。
- 失效重定位：会话里存 `fnID`，`validateSession` 失败时自动重新定位一次（`FeiniuBackend.swift:148-205`）。
- 实测记录（架构文档:166）：内网 IPv4、公网 IPv6、relay 三路可达。**这是「远程访问/中继」能力里唯一已落地的部分，且只在飞牛侧；Jellyfin 侧没有内建中继**。

## 4.7 双后端行为差异速查（做新功能时最容易踩的地方）

| 维度 | Jellyfin | 飞牛音乐 |
|---|---|---|
| 登录 | 用户名/密码 → `AccessToken` | `password = SHA256(明文)` 小写 hex + 持久化 32 位 `deviceId` + 自写 `music-token` Cookie（服务端不 Set-Cookie） |
| 地址 | `http(s)://host:8096`，可省略 scheme | NAS 地址自动补 `/music`；FN ID → FN Connect 选路/中继 |
| 分页 | 不强制（也接受全量） | 强制 `page/size`（从 1 开始）；`offset` 非 size 整数倍时有偏差 |
| 转码 | `static=false` + `audioCodec=mp3` + `maxAudioBitrate` + `enableAudioNormalization` | `POST /track/transcode`（Opus）→ HLS，仅一档码率；格式黑名单在客户端判断 |
| 进度上报 | `/Sessions/Playing{Started,Progress,Stopped}` | 只有 `track_play` 事件（无位置/时长/暂停） |
| 收藏 | 曲目/专辑/艺人/播放列表 | **仅曲目级**（专辑艺人落本地） |
| 搜索 | 单端点 `/Items/Search` | `/search/{track,album,artist}` 三接口并发 |
| 歌词 | `/Audio/{id}/Lyrics`（结构化行） | `/lyric/list` 返回 LRC 文本 + `preferred`，客户端解析 |
| 请求签名 | token 在 URL query（静态） | `authx` 逐请求签名（nonce/timestamp/path）→ 必须动态 loader |
| 歌单重排 | 支持（`playlistReorder=true`） | 无重排端点，只改本地 |
| 封面 | `ImageTag` 版本号 | `coverId` + `size` 档位（200/400/800）+ 中继 Cookie |
| 不支持格式 | 无客户端判断（可能静默失败） | APE/WavPack/DSD/DTS/TTA/WMA/OGG… 自动转码，转码失败明确报错 |


## 5. 播放链路（逐段核实）

**单 AVPlayer，无第二播放器**：`MusicPlayerModel.swift:67` 只有 `let player = AVPlayer()`；仓库内 `grep -rn "AVPlayer("` 仅此一处。

- 选源：`loadCurrent()` → `backend.playableSource(for:)`（`MusicPlayerModel.swift:332-357`）→ `MediaResourceLoader.makeAssetAndLoader` → `AVPlayerItem(asset:)` → `replaceCurrentItem`（359-365）。
- 直连 vs 转码：
  - Jellyfin：默认 `static=true` 直连原始文件；`requiresTranscode`（关闭直连优先或音质非原始）时 `static=false&audioCodec=mp3&maxAudioBitrate=…`（`JellyfinBackend.swift:245-277`）。
  - 飞牛：`/track/stream` 直连；要求转码或格式黑名单（APE/DSD/WMA/OGG…）时 `POST /track/transcode` 取 HLS，失败则抛「无法播放」（`FeiniuBackend.swift:435-483`、`FeiniuPlaybackFormat.swift:15-53`）。
  - `PlayableSource.transcodeFallback` 与 `isHLS` **播放器未消费**（`grep -rn "transcodeFallback"` 仅后端赋值；`MusicPlayerModel` 无回退逻辑）→ 「直连失败自动回退转码」目前**不存在**。
- 动态签名：飞牛 `authx` 走自定义 scheme + `AVAssetResourceLoaderDelegate`，逐请求重签、Range 206、HLS m3u8/分片重写（`Player/MediaResourceLoader.swift:55-79,182-330,400-425`）。
- 队列：内存数组 + `currentIndex`；顺序/列表循环/单曲循环/随机 4 模式；`playNext / enqueue / remove / move`；**不持久化**（退出即丢，无 save/restore 代码）。
- 预加载/无缝：**无**——`grep -rn "preload\|gapless\|nextItem"` 0 命中；每曲 `replaceCurrentItem`，曲间必有无缝缺口。
- 交叉淡入（核实 README 说法）：设置项叫「交叉淡入」0–12s，但代码只有**换曲淡入**（起播 `player.volume=0` → `startFadeIn` 定时升到目标，`MusicPlayerModel.swift:379-383,432-455`）+ **睡眠定时最后 5s 淡出**（310-328）；暂停/换曲**没有淡出**，也没有双播放器交叉混合。README:117 的「作用于换曲淡入/暂停淡出」不准确（暂停无淡出）。
- 睡眠定时：15/30/45/60 分钟 + 关闭，最后 5s 音量线性衰减后暂停（`NowPlayingView.swift:585-599`；`MusicPlayerModel.swift:296-328`）。
- 进度上报：起播报 `started`，播放中按设置间隔（5–60s，默认 10）报 `progress`，换曲/停止报 `stopped`（`MusicPlayerModel.swift:390-398,415-430,506-533`）。Jellyfin 三端点；飞牛只有 `track_play` 事件（丢 progress/stopped，`FeiniuBackend.swift:508-535`）。本地始终另存续播位置（5s 节流落盘）。
- Now Playing / 媒体键：**已设置** `MPNowPlayingInfoCenter`（标题/艺人/专辑/时长/速率/已播时间/封面，`MusicPlayerModel.swift:577-598`）与 `MPRemoteCommandCenter`（播放/暂停/toggle/下一曲/上一曲/seek，541-574）。未注册 shuffle/repeat/rating 远程命令。
- 播放失败/缓冲：**无** `AVPlayerItem.status` / `FailedToPlayToEndTime` 监听、无缓冲指示（`grep -rn "FailedToPlayToEnd\|timeControlStatus"` 0 命中）；`isLoading` 在 replace 后立即置 false。这是后续做 gapless/回退/离线的**前置债**。
- 失败可见性：后端错误 → `errorMessage`，仅正在播放页展示（`NowPlayingView.swift:175`）；直连播放失败（AVPlayer 内部错误）不会给用户任何提示。

## 6. 歌词

- 数据源：仅服务端。Jellyfin `GET /Audio/{id}/Lyrics`（`JellyfinBackend.swift:239-242`）；飞牛 `/lyric/list` 取 `preferred` 后解析 LRC（`FeiniuBackend.swift:396-413`）。
- 解析：`FeiniuLyrics.parse` 支持 `[mm:ss(.x/.xx/.xxx)]`、多时间戳、`[offset:±ms]`（正值提前）、BOM/CRLF、纯文本退化（`FeiniuLyrics.swift:24-171`）；**增强 LRC 逐字标签 `<mm:ss.xx>` 被剥掉**（152-163）。
- 模型：`LyricLine { text; start: Double? }`（`Models/Domain/MediaModels.swift:280-286`）——没有逐字、翻译、偏移字段。
- UI：正在播放页封面/歌词切换；行级高亮 + 自动滚动（`NowPlayingView.swift:617-639,1170-1238`）。
- 没有：逐字/KTV、翻译/双语、偏移 UI 调节、歌词编辑、歌词搜索、本地 .lrc 文件加载。

## 7. 播放列表与智能列表

- 本地：`Application Support/JellyfinMac/playlists.json`（`PlaylistStore.swift:42-46`），普通列表 + 智能列表；`serverId / itemMap / backend` 字段支持双后端隔离与服务器绑定。
- 服务器同步：`PlaylistSyncService`（144 行）——全量 `syncAll`（服务器为权威）+ 创建/删除/重命名/加曲/移曲单项实时推送；无能力时静默降级纯本地（`PlaylistSyncService.swift:11-33`）。
- 智能列表：**单规则** `SmartRule.artistKeyword`（按艺人/专辑关键字包含），每次打开动态匹配并镜像成服务器普通列表（`PlaylistStore.swift:18-20,77-95`；`MusicDataStore.swift:483-493`；`PlaylistDetailView.swift:140-156`）。
- 排序：详情页「上移/下移」菜单（`PlaylistDetailView.swift:248-266`），**无拖拽排序**；播放队列面板有拖拽（`QueuePanelView.swift`，List.onMove）。
- 无：多条件智能规则、按流派/年代/评分/播放次数规则、导入导出 M3U。

## 8. 本地兜底存储

- 文件：`Application Support/JellyfinMac/local-state/profile-<sha256(profileKey) 前16位>.json`（`State/Local/LocalLibraryState.swift:70-90,243-302`）。
- 作用域：`AppState.profileKey` = **归一化用户名，跨后端共享**（`AppState.swift:46-56`），条目键用 `ContentIdentity`（标题+艺人+时长±2s 指纹，`Models/Domain/ContentIdentity.swift`）→ 同一首歌在 Jellyfin/飞牛共用进度、次数、收藏与封面缓存。⚠️ 与 `docs/architecture-multibackend.md:37,95-102`「按后端+账号作用域」**不一致**（文档落后于代码）。
- 内容：收藏、播放次数、最近播放、续播位置、已播标记；写盘 debounce 300ms + 退出 `flushNowBlocking`（`JellyfinApp.swift:136-138`）；损坏容错、SHA-256 文件名、合并规则（服务端支持收藏则以服务端为准，统计/进度本地优先，`LocalLibraryState.swift:348-390`）。
- 定位：飞牛没有进度/统计/专辑收藏时 UI 无感（字段位置不变）。**不缓存音频文件**，只缓存用户元数据。

## 9. 设置项完整清单（逐项）

（默认值来自 `AppSettings.init` `AppSettings.swift:197-224`；「消费点」= 实际读取该值的代码）

| 分组 | 设置项 | 形态/取值 | 默认 | 消费点 | 状态 |
|---|---|---|---|---|---|
| 通用 | 启动时自动连接 | 开关 | 开 | `JellyfinApp.swift:70-74` | 生效 |
| 通用 | 默认打开页面 | 首页/资料库/播放列表/正在播放 | 首页 | `MainView.swift:704-711` | 生效 |
| 通用 | 关闭窗口时继续播放 | 开关 | 开 | `JellyfinApp.swift:140-143` | 生效 |
| 通用 | 语言 | 跟随系统/简体中文/English | 跟随系统 | **无消费点**（仅 `AppSettings.swift:113` 存取） | ⚠️ 空转：仓库无 `.strings/.xcstrings`、无 `localizedString` 调用，全界面中文硬编码 |
| 播放 | 音质 | 原始/高 320/中 192/低 128 kbps | 原始 | `AppSettings.swift:22-30` → `AppState.swift:245-252` → 后端转码参数 | 生效（飞牛只决定「是否转码」，不决定码率，`FeiniuBackend.swift:673-677`） |
| 播放 | 直连优先 | 开关 | 开 | `MusicBackend.swift:183`、`JellyfinBackend.swift:245-266` | 生效（飞牛同时受能力门控） |
| 播放 | 交叉淡入 | 0–12s，步长 0.5 | 0（关） | `AppSettings.swift:231-234` → `MusicPlayerModel.swift:432-455` | **部分**：只有换曲淡入，无淡出/无真 crossfade |
| 播放 | 音量归一化 | 开关 | 关 | 仅 `JellyfinBackend.swift:257`（转码参数 `enableAudioNormalization`） | **部分**：直连不生效；飞牛后端完全未读该项 → 飞牛上开关空转 |
| 播放 | 进度上报间隔 | 5–60s，步长 5 | 10 | `MusicPlayerModel.swift:506-513` | 生效（飞牛置灰，`SettingsView.swift:185-200`） |
| 外观 | 视觉风格 | 玻璃 / 纸墨 | 玻璃 | `AppSettings.swift:133-154`、`Theme.applyVisualStyle` | 生效（即时切换，重建呈现层） |
| 外观 | 主题 | 浅色/深色/跟随系统 | 浅色 | `AppSettings.swift:125-131`、`Theme.applyTheme` | 生效 |
| 外观 | 强调色 | 信号红/靛蓝/泛音青/紫 | 靛蓝 | `AppSettings.swift:64-89,156-165`、`SettingsView.swift:231-239` | 生效（含皮肤签名色自动跟随） |
| 外观 | 降低动效 | 开关 | 关 | `JellyfinApp.swift:199-202` | 生效（与系统 Reduce Motion 合并） |
| 外观 | 显示歌词 | 开关 | 关 | `NowPlayingView.swift:69,207-212` | 生效 |
| 媒体库 | 上次刷新 + 立即刷新 | 按钮 | — | `SettingsView.swift:253-269,313-326` | 生效 |
| 媒体库 | 缓存占用 | 只读进度条 | — | `SettingsView.swift:270-272,538-570` | 显示（磁盘目录 + 内存估算取大） |
| 媒体库 | 缓存上限 | 1–100GB 步进器 | 2GB | **仅 `SettingsView.swift:527,533` 显示** | ⚠️ 未执行淘汰：`ImageCache` 固定 400 张内存 LRU（`MediaComponents.swift:93-94`），无磁盘写入 |
| 媒体库 | 清除缓存 | 按钮 + 二次确认 | — | `SettingsView.swift:283-290,328-340` → `ImageCache.removeAll` | **部分**：只清内存缓存，不涉及 URLCache/磁盘 |
| 媒体库 | 曲目数量 | 只读文本 | — | `SettingsView.swift:291-294` | 显示 |
| 服务器与账号 | 服务器类型 | Jellyfin / 飞牛音乐 | 上次活动 | `SettingsView.swift:354-370` → `AppState.switchBackend:132-142` | 生效（切后端清队列、重载曲库、凭据分开保存） |
| 服务器与账号 | 服务器地址 | 只读 + 复制 | — | `SettingsView.swift:371-396,430-435` | 生效 |
| 服务器与账号 | 当前用户 / 切换用户 | 按钮 + 确认 | — | `SettingsView.swift:397-408,438-447` | 生效 |
| 服务器与账号 | 退出登录 | 按钮 + 确认 | — | `SettingsView.swift:409-416,449-458` | 生效（清会话与钥匙串密码，本地列表保留） |
| 关于 | 版本 / 开源许可 | 文本 + 外链 | — | `SettingsView.swift:464-473` | 显示 |
| 关于 | 快捷键速查 | 9 行表格 | — | `SettingsView.swift:475-501` | ⚠️ 表格含 3 项未接线（见 §11） |

**非设置页但属于用户可调项**（便于做功能对标时别漏）：

| 位置 | 项 | 取值 | 证据 |
|---|---|---|---|
| 正在播放 | 睡眠定时 | 15/30/45/60 分钟、关闭 | `NowPlayingView.swift:585-599`、`MusicPlayerModel.swift:296-328` |
| 正在播放/播放条 | 播放模式 | 顺序/列表循环/单曲循环/随机 | `MusicPlayerModel.swift:42-65,149-184` |
| 正在播放 | 收藏、曲目信息、待播清单 | — | `NowPlayingView.swift:84-115,392-567`、`TrackInfoView.swift` |
| 播放条 | 音量滑杆 + 静音 + 队列 | 0–1 | `MiniPlayerBar.swift:374-411` |
| 搜索页 | 搜索历史 | 最多 8 条（@AppStorage） | `MusicSearchView.swift:23-27,160-175` |
| 播放列表页 | 新建智能列表 | 名称 + 艺人关键字 | `PlaylistsView.swift:63-71,226-231` |

## 10. 快捷键（实际接线 vs 展示）

实现是全局 `NSEvent` 本地监听（`Components/Components.swift:1517-1610`），不是 SwiftUI `.commands` / `keyboardShortcut`：

| 键 | 行为 | 实际状态 |
|---|---|---|
| ⌘F | 聚焦搜索 | 生效（任何场景，含输入框内） |
| 空格 | 播放/暂停 | 生效（输入框聚焦时放行） |
| ⌘→ / ⌘← | 下一曲 / 上一曲 | 生效 |
| ⌘1…⌘5 | 一级页切换 | 生效 |
| ⌘[ | 返回上一级 | 生效 |
| Esc | 收起抽屉 | 生效 |
| ⌘, | 打开设置 | 生效（系统 Settings scene） |
| ⌘R | 刷新媒体库 | **未接线**：`MainView.swift:614-626` 未传 `onRefresh`，`Components.swift:1528` 默认空实现 |
| ⌘↑ / ⌘↓ | 播放列表上移/下移 | **未接线**：同上（`onMoveUp/onMoveDown` 默认空） |
| ⌫ | 删除选中项 | **未接线**：`MainView.swift:624` 传的是空闭包 |

无自定义快捷键/无键位重映射。系统媒体键（F7/F8/F9 等）与耳机线控依赖已注册的 `MPRemoteCommandCenter`；无应用级快捷键配置界面。

## 11. 可访问性

- 规模：`accessibility*` 相关调用 119 处；`focusRing(` 15 处、`hitExpand(` 22 处、`accessibilityElement` 29 处（均 `grep -rn` 统计）。
- 键盘焦点：hover 控件同时由 `@FocusState` 驱动（如 `TrackRowActions`、`SidebarNavRow`），焦点环统一 `Theme.focusRing`。
- 进度条：`accessibilityAdjustableAction` ±5s（`NowPlayingView.swift:1145-1156`）。
- 动态字号：字号令牌随系统缩放，`.textStyle(_:)` 统一入口（`Theme.swift:1049-1145`）。
- 减少动效 / 降低透明度双通道（系统 + 应用内），玻璃降级为实底。
- 分组标题 `.isHeader`、图标按钮 `accessibilityLabel`、配色不单独承载状态（红条+文字+VU）。
- 缺口：无 VoiceOver 全面巡检、无自动化可访问性测试；部分自定义绘制控件（EqualizerBars、封面拼图）未合并为单元素；语言设置空转意味着没有英文界面。

## 12. 自检与测试脚本

- 内建断言：`Diagnostics/SelfTest.swift`（491 行）——authx 签名、地址规范化、时长、歌词、流派、共享逻辑、FN Connect 七组；`--selftest` 运行后退出码非 0 表示失败（`JellyfinApp.swift:10-15`）。**实跑 78 项全部通过**（文档写 51）。
- 命令行诊断：`--fn-resolve <FN ID>`（FN Connect 定位/探测，`SelfTest.swift:472-489`）、`--feiniu-validate [base]`（已存会话校验，`SelfTest.swift:424-470`）。
- 脚本：`scripts/dev-test.sh`（复用 `.build/.typecheck.lock`、CLT 下用替身 SwiftUI 宏插件）、`dev-typecheck.sh`、`build-app.sh`、`watch-build.sh`、`dev-shot.sh`。
- 无 XCTest target、无 UI 自动化（`Package.swift` 仅一个 executableTarget）；纯逻辑断言内建在可执行文件里。

## 13. 缺失验证表

判定：**有 / 部分 / 无**。grep 均在 `Sources/` 下执行（命令关键词见证据列）。「接入点」用 Backend / State / Player / UI / 新 Service 表示。

| 能力 | 判定 | 证据（验证方式 + 文件:行号） | 适合做? | 接入点 | 量级/风险 |
|---|---|---|---|---|---|
| EQ/均衡器 | **无** | `grep -rn "AVAudioEngine\|AVAudioUnit\|AVAudioUnitEQ\|EQPreset" Sources` → 0 命中；`EqualizerBars` 只是播放态装饰动效（`Components.swift:114`） | 适合做 | Player（输出链路重写）+ 新 EQPreset + Settings | **L**：AVPlayer 无 EQ，需 AVAudioEngine/audio unit 重写输出；双后端无影响，风险高 |
| 音频输出设备选择 | **无** | `grep -rn "outputDevice\|CoreAudio\|AudioObject\|kAudioDevice\|AVRoutePicker"` → 0 命中 | 适合做（中优先） | Player + 设置 | **M**：需 CoreAudio HAL 枚举/切换；AVPlayer 需经 AVAudioEngine 或切换系统默认输出，体验受限 |
| 独占模式/独占音频 | **无** | 同上一行（无 CoreAudio 相关代码） | **不适合** | — | macOS 无独占语义；需 hog mode + 直出重写，与流媒体客户端定位不符 |
| 采样率切换/位深处理 | **无** | 仅元数据展示：`TrackInfoView.swift:45-49`；`grep "sampleRate"` 只有 Backend 映射（`JellyfinBackend.swift:465`、`FeiniuMapping.swift:82`），无 `AVAudioFormat`/`setPreferredSampleRate` | **不适合** | — | AVPlayer 输出交给 CoreAudio，客户端不可控；逐曲切换需 CoreAudio 直出（L） |
| DSD | **无** | 仅列入「必须转码」黑名单：`FeiniuPlaybackFormat.swift:28-31`（dsf/dff/…）；无 DSD 解码/DoP 代码；Jellyfin 侧无格式判定 | **不适合** | — | 需原生 DSD/DoP + 独占输出；飞牛本可转码，专业需求应由专用播放器承担 |
| 无缝播放 gapless | **无** | `grep -rn "preload\|gapless\|nextItem\|AVQueuePlayer"` → 0；每曲 `replaceCurrentItem`（`MusicPlayerModel.swift:361-365`） | 适合做（收益有限） | Player（AVQueuePlayer/预插入 AVPlayerItem） | **M**：转码/HLS 下无法保证无缝；需先补播放失败监听 |
| 真交叉淡化（双 AVPlayer） | **无**（现存仅淡入/睡眠淡出） | 单播放器 `MusicPlayerModel.swift:67`；淡入 432-455；睡眠淡出 315,321-328；暂停/换曲无淡出 | 适合做 | Player（双 AVPlayer + 音量包络）+ Settings 语义修正 | **M**：需双 loader/双进度/睡眠淡出共存；HLS 转码路径需降级 |
| ReplayGain/响度归一化 | **部分** | `normalizeVolume` → 仅 `JellyfinBackend.swift:257`（转码时 `enableAudioNormalization`）；飞牛未读（`FeiniuBackend.swift:435-483`） | 不做（应由服务端/转码承担） | 修正：飞牛能力门控；若做需客户端解码分析（L） | 客户端分析整曲响度代价大；保留现有服务端方案即可 |
| 播放速度 | **无** | `grep -rn "\.rate\b\|playbackRate\|speed"` → 仅注释；无 `player.rate` 赋值 | 适合做（低优先） | Player + UI | **S**：AVPlayer.rate 一行；但音乐场景价值低，且会干扰进度上报/歌词高亮 |
| Last.fm/ListenBrainz scrobble | **无** | `grep -rn "scrobble\|LastFM\|last.fm\|ListenBrainz"` → 0 命中 | 适合做（中优先） | 新 Service（网络）+ Settings + Player 事件 | **M**：需账号/API key 配置、失败静默、隐私说明；与已有上报链路独立 |
| 聆听统计/年度报告 | **部分**（有计数、无统计页） | 本地 `playCount/lastPlayed`：`LocalLibraryState.swift:11-20,497-518`；首页 Top10/最近：`HomeView.swift:280-323`；无统计页（`grep -rn "年度\|统计页"` 0） | 适合做 | State（数据已有）+ 新 Statistics 页 | **M**：本地数据粒度够做 Top 榜/时长/年度；跨设备不可用需说明 |
| 离线下载/缓存（音频级） | **无** | `grep -rn "download\|offline\|Download"` → 0；仅封面内存缓存（`MediaComponents.swift:1-105`）+ 本地元数据 | 适合做（高价值） | Backend.playableSource + 新 DownloadStore（文件缓存） + Player 本地 URL + 设置/库内入口 | **L**：签名 URL 过期、双后端/HLS、存储管理、版权提示；需文件级状态与重试 |
| 歌词逐字（karaoke） | **无** | 增强 LRC 逐字标签被剥离 `FeiniuLyrics.swift:152-163`；`LyricLine` 仅 text/start `MediaModels.swift:280-286`；UI 行级高亮 `NowPlayingView.swift:1170-1238` | 部分适合 | FeiniuLyrics + LyricLine 模型 + NowPlayingView | **M**：依赖服务端歌词是否含逐字；飞牛/ Jellyfin 常规歌词多为行级 |
| 歌词偏移调整 | **部分**（解析有、UI 无） | `[offset:]` 解析 `FeiniuLyrics.swift:30-49,143-150`；无 UI 调节代码 | 适合做 | UI + AppSettings（本地偏好） | **S**：一个滑杆 + 持久化；纯客户端 |
| 歌词编辑 | **无** | 无写歌词接口/无编辑 UI（`grep -rn "lyrics"` 仅拉取/展示） | **不适合** | — | 服务器职责（Jellyfin 歌词插件/文件），客户端无写接口 |
| 歌词搜索 | **无** | 同上一行 | **不适合** | — | 需服务端全文索引；客户端仅本地已加载曲库，成本高收益低 |
| 播客/有声书/文稿 | **无** | `grep -rn "podcast\|audiobook\|Podcast"` → 0 | **不适合（本期）** | — | 产品扩张（书库/章节/断点续听），Jellyfin/飞牛支持度不一致，工作量大 |
| 自动续播电台/相似歌曲 | **无** | `grep -rn "radio\|similar\|recommend\|InstantMix\|autoplay"` → 0；只有随机播放 `MusicPlayerModel.swift:149-184` | 部分适合 | Backend（Jellyfin InstantMix/Radio；飞牛只有 `roam`）+ Home/NowPlaying UI | **M**：Jellyfin 可支撑相似/电台；飞牛 `roam` 只是「服务端随机」不是相似度（`docs/research/fnos-music-api.md:501,873`）→ 需能力门控，飞牛只能做随机续播 |
| 标签编辑/刮削/去重 | **无** | 无编辑 UI；`TrackInfoView` 只读（`TrackInfoView.swift:1-100`） | **不适合** | — | **服务器职责**（Jellyfin 管理端/MusicBrainz 刮削/曲库工具）；客户端写回会破坏多端一致 |
| App Intents / Shortcuts | **无** | `grep -rn "AppIntent\|Shortcuts\|Intents"` → 0 | 适合做 | 新 AppIntents 文件 + AppState/Player 暴露动作 | **S/M**：暴露「播放/暂停/下一曲/搜索」即可；无需改后端 |
| Dock/菜单栏 extra | **无** | `grep -rn "NSStatusItem\|MenuBarExtra\|statusItem"` → 0；仅 `NSApp.setActivationPolicy(.regular)` `JellyfinApp.swift:60` | 适合做 | 新 StatusItem/MenuBarExtra + Player | **S**：迷你控制/当前曲目；注意与主窗口生命周期 |
| 通知 | **无** | `grep -rn "UNUserNotification\|NSUserNotification"` → 0 | 适合做（低优先） | 新 NotificationService + Player/AppState | **S**：播放失败/定时结束/后台续播失败；需权限申请 |
| 小组件（WidgetKit） | **无** | `grep -rn "WidgetKit\|Widget"` → 0 | 适合做（中低） | 新 Widget extension + App Group | **M**：要共享「当前曲目/最近播放」；主 App 需写 App Group 存储 |
| AirPlay/投送 | **无** | `grep -rn "AVRoutePicker\|MPVolumeView\|AirPlay"` → 0；AVPlayer 仅跟随系统输出设备 | 适合做（小） | UI（播放页/播放条放 `AVRoutePickerView`） | **S**：系统输出已有 AirPlay 能力，只是没有应用内入口；无自定义投送 |
| 远程访问/中继 | **有（仅飞牛 FN Connect）** | `FeiniuFNConnect.swift`（定位/候选探测/relay `mode=relay`）、`FeiniuAddress.resolve:97`、`FeiniuBackend.extraCookie`；Jellyfin 无内建中继 | 已具备（Jellyfin 侧不做） | — | Jellyfin 远程访问属网络/反代职责；客户端支持自定义 URL 已够 |
| SMB/WebDAV/本地文件直连 | **无** | `grep -rn "SMB\|WebDAV\|smb\|webdav"` → 0（仅 docs 里作为备选路径评估） | **不适合** | — | 会变成「曲库管理器」（自建库/索引/转码），与双后端流媒体定位冲突；离线缓存可覆盖部分需求 |
| 主题自定义（强调色/自定义配色） | **部分** | 2 皮肤 + 浅/深/系统 + **4 预置强调色**：`AppSettings.swift:64-89`、`SettingsView.swift:209-239`；无自定义 hex/字体/布局；v5 规范未落地 | 部分适合 | Theme + AppSettings + SettingsView | **S**（自定义强调色）/ **L**（v5 整套落地） |
| 自定义快捷键 | **无** | 固定监听 `Components.swift:1517-1610`，无重映射；且 ⌘R/⌘↑⌘↓/⌫ **未接线**（`MainView.swift:614-626`） | 适合做 | 改为 NSMenu commands + 可配置映射 + Settings | **M**：macOS 标准做法是菜单命令；顺带修掉未接线项（S） |
| iCloud/多设备同步 | **无** | `grep -rn "CloudKit\|iCloud\|NSUbiquitous"` → 0；进度/列表靠服务端同步，本地兜底明确不跨设备（`docs/architecture-multibackend.md:99-102`） | **不适合** | — | 本地兜底数据价值低；进度/歌单已由 Jellyfin 服务器承担，引入 CloudKit 徒增隐私/冲突成本 |
| 统计页 | **无** | 无独立统计页面；只有首页 Top10/最近播放（`HomeView.swift:280-323`） | 适合做 | 新 View + State 派生数据 | **M**：与「聆听统计/年度报告」同一件事，建议合并做 |
| 排序/筛选深度（多条件） | **部分** | 排序 4 种 `MediaModels.swift:246-262`；资料库 4 分段 `MainView.swift:49-58`；无流派/年代/多条件筛选；流派仅展示 `MusicAlbumView.swift:130-144` | 适合做 | Backend.items 增加 filter + UI FilterBar | **M**：Jellyfin 可服务端过滤；飞牛无 filter 参数只能本地过滤 → 需能力门控 |
| 队列持久化/跨启动恢复 | **无** | `grep -rn "queue"` + `save/persist/restore` → 0；队列纯内存 `MusicPlayerModel.swift:69` | 适合做 | State（JSON 落盘）+ 启动恢复 | **S**：应用退出/崩溃后恢复队列，风险低 |

> 补充确认（lead 已核对、此处只落证据）：单 AVPlayer `MusicPlayerModel.swift:67`；仅 fade-in 432-455；无 EQ（`grep AVAudioEngine` 0）；无 scrobble（grep 0）；无统计页；无 InstantMix（grep 0）；`MPNowPlayingInfoCenter` 已设置 577-598；`TrackInfoView` 已展示采样率/位深 45-49；无离线下载（grep 0）；无 App Intents/Widget/MenuBar（grep 0）；无歌词偏移 UI/无翻译（`LyricLine` 无字段）。

## 14. 适合做 vs 不该做（结论）

**「确实没有且适合客户端做」（按价值排序）**

1. **离线下载/音频缓存（L）**：NAS 用户最刚需；双后端都能拿直链，需新 `DownloadStore` + 文件级缓存 + 播放器本地 URL 分支。前置：播放失败监听。
2. **EQ/均衡器（L）**：客户端职责明确、用户预期高；但必须重写输出链路（AVAudioEngine + AVAudioUnitEQ），AVPlayer 直接播放无法接 EQ。
3. **真交叉淡化 + gapless（M）**：现有设置项名不副实；做双播放器/AVQueuePlayer 时一并修正设置文案与「暂停淡出」语义。
4. **聆听统计/年度报告 + 统计页（M）**：本地已有 playCount/lastPlayed/续播，纯 State+View，不与服务器冲突；需注明「仅本地统计」。
5. **相似歌曲/自动续播电台（M，飞牛受限）**：Jellyfin InstantMix/Radio 有 API 支撑；飞牛只有 `roam`（服务端随机，不是相似度）→ 飞牛侧只能做「随机续播」，需能力门控。
6. **歌词体验增强（M）**：偏移 UI（S）+ 逐字/翻译（M，取决于服务端歌词）；飞牛歌词接口已返回 LRC，增强 LRC 逐字标签被剥离是现成抓手。
7. **小件打包（S/M）**：App Intents/Shortcuts、菜单栏迷你控制、通知、自定义快捷键、自定义强调色、队列持久化、播放速度——都是低风险客户端能力，可分批做。

**「看起来缺但不该做」**

1. **标签编辑/刮削/去重**：属于服务器/曲库管理（Jellyfin 管理端、MusicBrainz 工具）职责。客户端写回会绕过服务端索引，造成多端不一致与权限问题。
2. **独占模式/采样率切换/DSD**：macOS + AVPlayer 不提供独占与逐曲采样率切换，需 CoreAudio 直出（等于另一个播放器引擎）；DSD 应由转码或专用播放器承担，硬做会拖垮播放链路稳定性。
3. **SMB/WebDAV/本地文件直连**：会让 Overtone 变成「本地曲库管理器」，与 Jellyfin/fnOS 的服务端索引、转码、多端同步定位冲突；离线下载已能覆盖「不联网也要听」的核心诉求。
4. **歌词编辑/歌词搜索、iCloud 多设备同步、Jellyfin 侧远程中继**：分别属于服务器写接口/全文索引、服务器同步（现有 progress/playlist 已承担）、网络层（反代/Tailscale）职责。

## 15. 文档-代码漂移与实施风险（供后续功能排期）

1. **自检数量**：文档写 51，实跑 **78**（README:51、architecture:55）。
2. **播放失败无监听**：无 `AVPlayerItem.status`/`FailedToPlayToEndTime`/`timeControlStatus`；直连失败静默。做 gapless/回退/离线前必须先补（`MusicPlayerModel.swift` 全文无相关观察）。
3. **`transcodeFallback`/`isHLS` 是死字段**：后端已赋值（`FeiniuBackend.swift:456,481`），播放器未消费（`grep` 仅两处赋值）→ 「直连失败回退转码」未实现，HLS 由 loader 靠 m3u8 自行识别。
4. **能力声明两份且不一致**：`MusicBackend.swift:73-85`（`.feiniu.search=false`）vs `FeiniuBackend.swift:941-967`（`search=true`，实际生效）；后者注释自认「分支合并后再决定」。
5. **死设置两项**：语言（无本地化资源）、缓存上限（未执行淘汰；`ImageCache` 固定 400 张内存 LRU，`清除缓存` 只清内存）。
6. **飞牛「音量归一化」空转**：`normalizeVolume` 只被 Jellyfin 转码路径读取；飞牛 UI 未门控，开关无效果。
7. **快捷键表与接线不一致**：⌘R / ⌘↑⌘↓ / ⌫ 在设置里展示但未接线（`MainView.swift:614-626` vs `Components.swift:1528-1531`）。
8. **队列不持久化**：退出/崩溃后队列丢失（`MusicPlayerModel.swift:69`，无落盘）。
9. **交叉淡入语义**：只有换曲淡入 + 睡眠淡出；README:117「暂停淡出」不成立（`togglePlay` 只 pause）。
10. **断点阈值三套说法**：代码 640/860/1100/1420；`Theme.swift:1686` 注释 520/760/1000/1180/1440；v2 规范（内容宽）与 v4 规范（<620/<820）又不同。
11. **本地兜底作用域与架构文档不符**：代码按归一化用户名**跨后端共享**（`AppState.swift:46-56`），文档写「后端+账号」（architecture:37,104-108）。
12. **曲库上限**：首屏 5,000 首/3,000 专辑/3,000 艺人后截断并提示（`MusicDataStore.swift:58-61,296-330`；`MusicLibraryView.swift:136-150`），无真分页懒加载；「播放全部」>1000 首会截断（`MusicLibraryView.swift:222-239`，`limit = 1000`）。

## 16. 现有优势（做新功能时不要重复造）

- **能力声明 + 本地兜底**：UI/状态层只读 `BackendCapabilities` 与领域模型，飞牛缺的三项（进度/统计/专辑艺人收藏）由 `LocalLibraryState` 无感补齐；加第三个后端只需实现协议（architecture §4）。
- **逐请求签名资源加载器**：`MediaResourceLoader` 已处理动态 `authx`、Range 206、HLS m3u8/分片重写与凭据重算——做离线下载/gapless 时可直接复用其请求模型。
- **跨后端内容身份**：`ContentIdentity` 让同一首歌在两个后端共用本地进度/次数/封面缓存（`ArtworkRef.contentCacheKey`）。
- **观察范围隔离**：`PlaybackProgress`/`PlaybackVolume` 独立可观察对象、`MiniPlayerSlot`/`LyricsPane`/`NowPlayingProgressSection` 单独观察，避免进度 tick 重绘整页——加统计/歌词逐字时应沿用该模式。
- **双皮肤令牌体系**：两套令牌同时构造、切换只换引用；新页面必须走 `Theme` 令牌与 `.textStyle(_:)`，否则两套皮肤会不一致。
- **自检 + 命令行诊断**：78 项纯函数断言 + `--fn-resolve`/`--feiniu-validate`，新后端映射/解析逻辑应加断言（`docs/architecture-multibackend.md:118-119` 的约定）。
