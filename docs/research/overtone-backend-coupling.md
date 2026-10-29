# Overtone 后端耦合分析与多后端改造工作量评估

> **目的**：量化「把 Overtone 从只支持 Jellyfin 的单后端客户端，扩成 Jellyfin + 飞牛音乐（飞牛 NAS）双后端」要改哪些地方、各花多少工。
> **方法**：全部结论来自源码实测（`文件:行号` 可核对），不含泛泛而谈。行号基于当前工作树（2026-10-28）。
> **口径**：人日 = 1 名熟悉 SwiftUI 的中级工程师 × 6 小时有效编码；区间分乐观 / 常见 / 悲观三档；置信度分高/中/低。
> **边界**：本文只做分析与方案，不改源码；所有代码块是**草案**，未编译过。

---

## 0. 结论先行（TL;DR）

| 问题 | 结论 |
|---|---|
| **耦合最深的三处** | ① `State/MusicDataStore.swift:213-233` 的「三次请求把整个曲库拉进内存 + 客户端全量派生排序」——它同时假设了**无分页**、**服务端已排序**、**userData 齐全**；② `Player/MusicPlayerModel.swift:453-483` 的播放地址即拼即用（`/Audio/{id}/stream?...&api_key=`，同步返回 `URL`）——飞牛是「逐请求签名 + POST /track/transcode 拿 HLS」，返回值根本不能是裸 URL；③ `Networking/APIClient.swift:77-159` 的认证头 + 全局 PascalCase 解码 + `baseURL/token/user` 单例状态，被 14 个文件直接引用 |
| **UI 层能不能不动** | **不能完全不动，但改动是机械的**。`BaseItemDto` 在 UI 层（Views+Components）出现 **47 次 / 13 文件**，可 UI 真正读到的字段名只有 **10 个 / 9 类语义**，其中 `id/name/album/albumArtist/userData` 五项就占了 212/225 次读取。所以抽象的价值不在「救 UI」，而在**把 `BaseItemDto` 的 30 个 Jellyfin 字段收成一个 ~12 字段的领域模型**，让 UI 从 47 处类型依赖变成 47 处字段改名（不重写布局） |
| **总工作量（完整方案 B）** | 乐观 **21** / 常见 **32.5** / 悲观 **52** 人日（含飞牛后端从零实现）；歌单写延后（M9）后为 **19.5 / 30 / 48**，再减影视字段清理的负工作量（−0.4）≈ 常见 **29.6 人日** |
| **MVP（一周跑通登录+浏览+播放）** | 乐观 **3.0** / 常见 **4.8** / 悲观 **7.0** 人日 —— 只动 **5 个现有文件 + 1 个新文件**，不做领域模型层、不做歌单写、不做歌词 |
| **最大风险** | 飞牛侧 API 的**可控性**，而非 Swift 代码量。签名/HLS 转码会逼出 `AVAssetResourceLoaderDelegate`（+1~2 人日且易踩坑）；若飞牛无公开 API 需逆向，工期不可估 |
| **一个反直觉的发现** | 抽象层（协议 + 领域模型 + 拆 DTO）只占总量的 **约 1/3**；另外 2/3 是「飞牛适配 + 播放链路 + 凭据迁移 + 手测回归」——**先做抽象不能省掉大头，但能决定第二年加第三个后端是 5 人日还是 25 人日** |

---

## 1. 现状架构一页纸

### 1.1 度量基线（实测）

```
$ find Sources -name "*.swift" | xargs wc -l | tail -1
   15850 total                      # 34 个 .swift 文件（任务书写的 12180/23 是旧口径）
$ grep -rho "BaseItemDto" Sources --include=*.swift | wc -l
   110                              # 22 个文件
$ grep -rho "BaseItemDto" Sources/JellyfinMac/Views Sources/JellyfinMac/Components --include=*.swift | wc -l
   47                               # 13 个文件（UI 层）
$ grep -rl "APIClient.shared" Sources --include=*.swift | wc -l
   14                               # 其中 Views/ 层 5 文件 11 行
$ grep -c "testTarget" Package.swift
   0                                # 没有任何测试 target → 回归全靠手测
```

| 目录 | 行数 | 与 Jellyfin 的耦合 |
|---|---:|---|
| `Theme.swift` | 1,809 | **0**（纯设计令牌） |
| `Components/`（5 文件） | 4,142 | `MediaComponents.swift` 14 处 DTO；`Components.swift`（1,638 行）**0 处**；`MiniPlayerBar` 1 处 |
| `Views/`（4 文件） | 3,453 | 11 处 DTO，5 处直连 `APIClient.shared` |
| `Views/Music/`（10 文件） | 3,670 | 20 处 DTO，6 处直连 `APIClient.shared` |
| `State/`（7 文件） | 1,374 | **重灾区**：会话、曲库、歌单同步、设置全在这里 |
| `Player/`（2 文件） | 673 | 播放地址 + 进度上报，全是 Jellyfin 语义 |
| `ViewModels/`（2 文件） | 143 | 直接拼 `/Users/{uid}/Items` 查询 |
| `Models/`（1 文件） | 153 | `BaseItemDto` 本体 |
| `Networking/`（1 文件） | 239 | 认证头 / 解码策略 / 图片 / 收藏 / 歌词 |
| `JellyfinApp.swift` | 194 | 入口，耦合轻 |

> **真正要审的耦合面 = 15,850 − 1,809（Theme）− 1,638（Components.swift）= 12,403 行**。任务书给的「约 12,180 行」应即此口径（差异来自文件数与含注释统计）。

### 1.2 数据流向（现状）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ SwiftUI 视图层                                                                │
│  Views/LoginView  MainView  HomeView  SettingsView                           │
│  Views/Music/{Library,Album,Artist,Playlists,PlaylistDetail,Search,          │
│               NowPlaying,TrackInfo,DiscoverPages,QueuePanel}                  │
│  Components/{MediaComponents, MiniPlayerBar, …}                               │
│                                                                              │
│  ▲ 直接持有 BaseItemDto（47 处 / 13 文件）                                     │
│  ▲ 5 个视图直接发请求：TrackInfoView:154、NowPlayingView:626、                 │
│    MusicArtistView:78、SettingsView:363/388/392、MainView:254/273/320/679     │
└──────────────┬───────────────────────────────────────────┬───────────────────┘
               │ @ObservedObject / @EnvironmentObject        │ 裸 async throws
               ▼                                            ▼
┌────────────────────────────────────┐   ┌─────────────────────────────────────┐
│ State/ 全局单例（@MainActor）        │   │ ViewModels/（143 行）                │
│  AppState        会话 phase/user/库 │   │  MusicArtistViewModel:19-46         │
│  MusicDataStore  曲库 + 派生数据    │   │  MusicAlbumViewModel:61-85          │
│  PlaylistStore   本地歌单 + 持久化  │   │  MusicSearchViewModel:16-56         │
│  PlaylistSyncService 服务器双向同步 │   │  └ 直接拼 /Users/{uid}/Items 查询    │
│  AppSettings     设置（含转码开关） │   └──────────────┬──────────────────────┘
│  KeychainHelper  凭据               │                  │
└──────────────┬─────────────────────┘                  │
               │                                        │
               ▼                                        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Player/                                                                       │
│  MusicPlayerModel(552)  队列 + AVPlayer，streamURL 拼 /Audio/{id}/stream      │
│  PlaybackReporter(121)  /Sessions/Playing{,/Progress,/Stopped}                │
└──────────────┬───────────────────────────────────────────────────────────────┘
               ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Networking/APIClient（239 行，单例）                                           │
│  · 可变全局状态：baseURL / token / user（:29-31）                              │
│  · MediaBrowser Authorization 头（:77-86，含 Client/Device/DeviceId/Version）  │
│  · PascalCase→camelCase 全局解码策略（:135-159）                               │
│  · /Items/{id}/Images（:169-183）·/Users/{uid}/FavoriteItems（:209-216）       │
│  · /Audio/{id}/Lyrics（:219-222）·reset()（:200-204）                          │
└──────────────┬───────────────────────────────────────────────────────────────┘
               ▼
        Jellyfin Server（端点全集见 1.3）
```

### 1.3 依赖的 Jellyfin 端点全集（10 类，逐条已核）

| # | 端点 | 调用点 | 备注 |
|---|---|---|---|
| 1 | `POST /Users/AuthenticateByName` | `State/AppState.swift:42` | 请求体 PascalCase `Username`/`Pw`（`Models/JellyfinModels.swift:6-13`） |
| 2 | `GET /Users/Me` | `State/AppState.swift:75` | token 恢复校验 |
| 3 | `GET /Users/{uid}/Views` | `State/AppState.swift:127` | 返回库列表，按 `collectionType` 白名单过滤（`:128-132`） |
| 4 | `GET /Users/{uid}/Items` | `MusicDataStore.swift:218-229`、`ViewModels/MusicViewModels.swift:23,34,67,71`、`MusicSearchViewModel.swift:33`（`/Items/Search`）、`PlaylistSyncService.swift:34` | 全部靠 `Recursive`/`IncludeItemTypes`/`SortBy`/`Fields` 参数 |
| 5 | `GET /Items/{id}/Images/{Primary\|Backdrop\|Thumb}` | `APIClient.swift:169-183` | `maxWidth`/`quality`/`tag`/`api_key` |
| 6 | `GET /Audio/{id}/Lyrics` | `APIClient.swift:219-222` | Jellyfin 10.9+，无歌词 404 |
| 7 | `POST\|DELETE /Users/{uid}/FavoriteItems/{itemId}` | `APIClient.swift:209-216` | 收藏是**用户维度**资源 |
| 8 | `POST /Sessions/Playing`、`/Progress`、`/Stopped` | `PlaybackReporter.swift:99-119` | body 为 PascalCase（`:11-18`） |
| 9 | `POST /Playlists`、`POST /Playlists/{id}`、`POST\|DELETE /Playlists/{id}/Items`、`DELETE /Items/{id}` | `PlaylistSyncService.swift:97,109,117,120,131,136,154` | `DELETE /Items/{id}` 用于删除歌单（10.10+ 语义） |
| 10 | `GET /Audio/{id}/stream` | `MusicPlayerModel.swift:453-483` | `static=true` 直连 / `static=false&audioCodec=mp3&transcodeContainer=mp3&maxAudioBitrate=` 转码 |

---

## 2. 耦合点清单表

**改动性质**：`删除`＝连逻辑一起去掉；`抽出`＝搬进后端适配器（行为不变）；`抽象`＝升为协议方法；`参数化`＝保留实现但去掉硬编码；`重写`＝结构变化；`文案`＝纯字符串。

### A. 网络与认证（`Networking/`）

| # | 文件:行 | Jellyfin 专属点 | 改动性质 | 影响面 |
|---|---|---|---|---|
| A1 | `Networking/APIClient.swift:77-86` | `Authorization: MediaBrowser Client="…", Device="…", DeviceId="…", Version="…", Token="…"` | 抽象 | 全部请求 |
| A2 | `APIClient.swift:39-43` | 客户端名 `clientName`（登录页「高级选项」写 `UserDefaults["clientName"]`） | 参数化 | 登录/会话 |
| A3 | `APIClient.swift:44-60` | `deviceName = "Mac"`、跨启动稳定 `deviceId`（`UserDefaults["clientDeviceId"]`）、`appVersion` | 抽出 | Jellyfin 会话标识 |
| A4 | `APIClient.swift:29-31` | `var baseURL / token / user: UserDto?` —— **单例可变状态**，14 个文件直接读 | 重写 | 全应用 |
| A5 | `APIClient.swift:135-159` | 全局 `keyDecodingStrategy = .custom(camelize)`（PascalCase→camelCase，`Items`→`items`） | 抽出 | Jellyfin 解码；飞牛用不上 |
| A6 | `APIClient.swift:169-183` | `imageURL(itemId:kind:width:tag:)` → `/Items/{id}/Images/{Primary\|Backdrop/0\|Thumb}?maxWidth=&quality=90[&tag=][&api_key=]` | 抽象 | 所有封面（16 处调用） |
| A7 | `APIClient.swift:186-190` | `primaryImageURL(for:)`：无 `Primary` tag 时回退 `seriesId`（影视语义） | 删除 | 艺人卡（`MediaComponents.swift:500`） |
| A8 | `APIClient.swift:192-198` | `backdropURL(for:)`：`parentBackdropItemId` 回退（影视语义，音乐不用） | 删除 | 详情页头图 |
| A9 | `APIClient.swift:209-216` | `setFavorite` → `/Users/{uid}/FavoriteItems/{id}` | 抽象 | 收藏态（14 处 `userData`） |
| A10 | `APIClient.swift:219-222` | `fetchLyrics` → `/Audio/{id}/Lyrics`，`LyricsResponse.lyrics` | 抽象 | 正在播放歌词 |
| A11 | `APIClient.swift:200-204` | `reset()` 清空三元组（登出） | 重写 | 登出/切服务器 |
| A12 | `APIClient.swift:25-27` | `static let shared` 单例（无后端维度） | 重写 | 全应用 |

### B. 数据模型（`Models/`）

| # | 文件:行 | Jellyfin 专属点 | 改动性质 | 影响面 |
|---|---|---|---|---|
| B1 | `Models/JellyfinModels.swift:27-63` | `BaseItemDto` 30 个字段（`serverId/mediaSources/collectionType/isFolder/childCount/seriesId/seasonId/…` 音乐用不到） | 保留为 Jellyfin DTO + 新增领域模型 | UI 47 处 |
| B2 | `JellyfinModels.swift:70-106` | 扩展：`isMovie/isSeries/isEpisode`、`typeDisplayName` 的电影/剧集/季分支、`runtimeSeconds/resumeSeconds` | 拆分（影视判定删除，时长换算入领域模型） | 组件层 |
| B3 | `JellyfinModels.swift:83-91` | **`artworkURL(width:)` 在数据模型里反向调用 `APIClient.shared`** —— 模型依赖网络单例，多后端时这是死结 | 删除/重写 | 16 处封面调用 |
| B4 | `JellyfinModels.swift:108-114` | `UserDataDto`（`played/playbackPositionTicks/isFavorite/playCount/lastPlayedDate`） | 抽出（映射到领域模型标量字段） | 首页/资料库/组件 |
| B5 | `JellyfinModels.swift:118-130` | `LyricsResponse`/`LyricLine`（`start` 为 100ns ticks，`/10_000_000` 转秒） | 保留歌词类型（改名 + 统一为秒） | 歌词 |
| B6 | `JellyfinModels.swift:132-148` | `MediaSourceInfo`/`MediaStream`（`type == "Audio"` 判定） | 抽出（仅 `TrackInfoView` 用） | 音轨信息页 |
| B7 | `JellyfinModels.swift:150-153` | `QueryResult<T>{items,totalRecordCount}` | 替换为 `Paged<Element>` | 全部列表 |
| B8 | `JellyfinModels.swift:6-18` | `AuthRequest` 的 `Username`/`Pw` PascalCase 编码 + `AuthenticateResponse` | 抽出 | 登录 |
| B9 | `JellyfinModels.swift:20-23` | `UserDto{id,name}` | 替换为领域 `BackendUser` | 会话/侧栏/设置 |

### C. 状态层（`State/`）

| # | 文件:行 | Jellyfin 专属点 | 改动性质 | 影响面 |
|---|---|---|---|---|
| C1 | `State/MusicDataStore.swift:14-20` | `@Published var tracks/artists/albums: [BaseItemDto]`（三份全量数组） | 重写 | 首页/资料库/搜索/歌单 |
| C2 | `MusicDataStore.swift:213-233` | `load()` 三次并发请求全量拉取，**没有 `Limit`/`StartIndex`**（全库单次返回） | 重写（分页） | 大曲库性能/内存 |
| C3 | `MusicDataStore.swift:257-289` | 查询构造：`ParentId`+`IncludeItemTypes=Audio\|MusicArtist\|MusicAlbum`+`Recursive=true`+`SortBy=SortName`+`Fields=Overview[,DateCreated]` | 抽出 | 曲库 |
| C4 | `MusicDataStore.swift:100-122` | 客户端全量派生：收藏过滤、`playCount` 排序、`lastPlayedDate` 解析、续播计算 | 保留（字段来源改为领域模型） | 首页 4 个模块 |
| C5 | `MusicDataStore.swift:125-139` | 续播：`resumeSeconds > 5 && runtimeSeconds > 0`，依赖**服务端 userData 进度** | 改写（能力门控） | 首页「继续播放」 |
| C6 | `MusicDataStore.swift:141-145` | 专辑三排序：`dateCreated`/`name`/`albumArtist` 字符串比较 | 保留 | 资料库专辑 |
| C7 | `MusicDataStore.swift:171-173` | 注释「服务端已按 SortName 返回，无需再排」——**排序契约依赖服务端** | 参数化（能力/契约声明） | 资料库歌曲 |
| C8 | `MusicDataStore.swift:194-202` + `:31` | `libraryId` 来自 `collectionType == "music"`，回退 `libraries.first`（`MainView.swift:691-695`、`SettingsView.swift:299-303` 各复制一遍） | 抽象 | 启动装载 |
| C9 | `AppState.swift:19-26` | `UserDefaults` 键 `"serverURL"/"token"/"username"/"password"` —— **单服务器单用户，无后端维度** | 重写 | 免登录/多服务器 |
| C10 | `AppState.swift:36-60` | `login()`：`normalize` → `AuthenticateByName` → 写 `UserDefaults` + Keychain（account = 用户名） | 重写 | 登录 |
| C11 | `AppState.swift:63-103` | `restoreSession()`：token → `/Users/Me` → 账号密码重登 | 重写 | 启动 |
| C12 | `AppState.swift:124-136` | `loadLibraries()`：`/Users/{uid}/Views` + `collectionType` 白名单（`:128`，含 movies/tvshows 等影视类型） | 抽象 | 侧栏资料库 |
| C13 | `AppState.swift:138-156` | `logout()` 清 4 个 UserDefaults 键 + 2 个 Keychain 账号 | 重写 | 登出 |
| C14 | `State/PlaylistStore.swift:4-19` | `Playlist.serverId: String?` / `itemMap: [String:String]?` —— **服务器绑定只有一维**（无后端/服务器标识） | 参数化 | 歌单同步 |
| C15 | `PlaylistStore.swift:40-44` | 持久化路径 `Application Support/JellyfinMac/playlists.json` | 参数化（**不要改名**，见 R8） | 数据迁移 |
| C16 | `PlaylistStore.swift:126-136,138-161,164-188` | 增删/排序后 `Task { pushAdd/pushRemove/pushRename }` —— 本地变更**无条件**推服务器 | 参数化（能力门控） | 歌单操作 |
| C17 | `PlaylistSyncService.swift:25-91` | `syncAll()`：拉 `/Users/{uid}/Items?IncludeItemTypes=Playlist` → 合并 → 上传未同步 → 智能列表镜像 | 重写 | 启动/刷新 |
| C18 | `PlaylistSyncService.swift:95-158` | 五项写操作全部 Jellyfin 路径（含 `UserId` 查询参数、`EntryIds` 删除语义） | 重写 | 歌单 |
| C19 | `PlaylistSyncService.swift:170-173` | `fetchEntryId` 依赖 `playlistItemId`（Jellyfin 独有的「条目 id ≠ 曲目 id」） | 抽出 | 歌单删条目 |
| C20 | `State/AppSettings.swift:14-40` + `:226-229` | `Quality`→`bitrate`→`requiresTranscode`（**转码是全局假设**，不是后端能力） | 参数化 | 播放音质 |
| C21 | `State/KeychainHelper.swift:5-6` | `service = "com.jellyfin.mac-client"`（Bundle ID 复用，见 `docs/naming.md` 明确「未改」） | 参数化 | 免登录 |
| C22 | `KeychainHelper.swift:12,14-25` | account = 用户名；token 反而存 `UserDefaults`（ad-hoc 签名 + ACL 导致弹框，刻意为之） | 重写（命名空间 + 迁移） | 凭据 |

### D. 播放链路（`Player/`）

| # | 文件:行 | Jellyfin 专属点 | 改动性质 | 影响面 |
|---|---|---|---|---|
| D1 | `Player/MusicPlayerModel.swift:453-483` | `streamURL(for:)`：`/Audio/{id}/stream` + `static=true` 或（`audioCodec=mp3&transcodeContainer=mp3&maxAudioBitrate=&enableAudioNormalization=`）+ `api_key` | **重写为「播放源描述符」** | 播放核心 |
| D2 | `MusicPlayerModel.swift:330-372` | `loadCurrent()` **同步**取 URL → `AVPlayerItem(url:)`（`:340`，无自定义 header） | 重写（async + 资源加载器） | 10 处调用点 |
| D3 | `MusicPlayerModel.swift:346-351` | `PlayMethod = requiresTranscode ? "Transcode" : "DirectPlay"`（字符串，Jellyfin 枚举） | 参数化 | 进度上报 |
| D4 | `MusicPlayerModel.swift:70,87-89` | `queue: [BaseItemDto]`、`currentTrack` | 重写（`Track`） | 全局播放状态 |
| D5 | `MusicPlayerModel.swift:535` | `currentTrack?.artworkURL(width: 512)` 填系统 Now Playing 封面 | 抽象 | 控制中心 |
| D6 | `Player/PlaybackReporter.swift:3-19` | `PlaybackReport` PascalCase body（`ItemId/PositionTicks/PlayMethod/IsPaused/CanSeek`） | 抽出 | 进度同步 |
| D7 | `PlaybackReporter.swift:88-106` | 端点 `Start/Progress/Stopped` 全挂 `/Sessions/Playing` 下 | 抽象 | 进度同步 |
| D8 | `PlaybackReporter.swift:119` | `APIClient.shared.postEmpty(kind.path, …)` 直连单例 | 抽象 | 进度同步 |

### E. ViewModel 与视图层（`ViewModels/` · `Views/` · `Components/`）

| # | 文件:行 | Jellyfin 专属点 | 改动性质 | 影响面 |
|---|---|---|---|---|
| E1 | `ViewModels/MusicViewModels.swift:23-43` | 艺人页：`ParentId`/`ArtistIds` + `IncludeItemTypes=MusicAlbum\|Audio` + `SortBy=SortName` | 抽象 | 艺人页 |
| E2 | `MusicViewModels.swift:67-81` | 专辑页：`/Users/{uid}/Items/{albumId}` + `SortBy=ParentIndexNumber,IndexNumber,SortName`（**碟号/轨号排序靠服务端**） | 抽象 | 专辑页曲序 |
| E3 | `ViewModels/MusicSearchViewModel.swift:33-41` | `/Users/{uid}/Items/Search`+`Limit=60`+`IncludeItemTypes=Audio,MusicAlbum,MusicArtist` | 抽象 | 搜索 |
| E4 | `MusicSearchViewModel.swift:52-56` | 结果按 `type == "Audio"/"MusicArtist"/"MusicAlbum"` 字符串分组 | 重写（领域类型枚举） | 搜索分组 |
| E5 | `Views/Music/TrackInfoView.swift:133-163` | **视图层 ViewModel 直接发请求**：`/Users/{uid}/Items/{itemId}?Fields=MediaSources` | 删除/抽象 | 音轨信息页 |
| E6 | `Views/Music/NowPlayingView.swift:617-639` | 直接调 `APIClient.shared.fetchLyrics` | 抽象 | 歌词 |
| E7 | `Views/Music/MusicArtistView.swift:78` | `APIClient.shared.primaryImageURL(for:)` 生成艺人头像 | 抽象 | 艺人页 |
| E8 | `Views/MainView.swift:17-19` | `ContentPage.artist/album(BaseItemDto)` —— **DTO 被当路由负载** | 重写（`Track`/`Album`/`Artist`） | 导航栈 |
| E9 | `MainView.swift:254,273,320` | `serverHost: APIClient.shared.baseURL?.host` 传给侧栏 | 参数化 | 侧栏 |
| E10 | `MainView.swift:676-701` | `bootstrap()` 轮询 `APIClient.shared.baseURL/user` 就绪（`:678-681`）+ 解析 `collectionType=="music"` + 无条件 `syncAll()`（`:697`） | 重写 | 启动 |
| E11 | `Views/SettingsView.swift:325-396` | 「服务器与账号」组：`serverAddress` 读 `APIClient.shared.baseURL`（`:388`）、`baseURL?.host`（`:363`）、复制地址、切换用户、退出 | 参数化 | 设置页 |
| E12 | `SettingsView.swift:295-309` | `refreshLibrary()` 里 `loadLibraries` + `libraryId` + `reload` + `syncAll` 全 Jellyfin 顺序 | 参数化 | 设置页 |
| E13 | `SettingsView.swift:428` | 关于页文案「原生 macOS Jellyfin 音乐客户端」 | 文案 | 设置页 |
| E14 | `Views/LoginView.swift:16-19` | `serverHost/serverScheme/serverPort/clientName` 全部 `UserDefaults` 直读（**无后端选择**） | 参数化 | 登录页 |
| E15 | `LoginView.swift:406-468` | 「高级选项」= 协议 + 端口 + 客户端名（Jellyfin 专属三段式地址组装，`:473-484`） | 参数化 | 登录页 |
| E16 | `LoginView.swift:486-512` | `connect()` 直接调 `appState.login(server:username:password:)` | 重写（后端分派） | 登录页 |
| E17 | `LoginView.swift:261` | 文案「填写你的 Jellyfin 服务器地址与账号」 | 文案 | 登录页 |
| E18 | `Components/MediaComponents.swift:8-83` | `ImageCache` 以 `url.absoluteString` 为缓存键（`:16`） | 参数化（签名 URL 会击穿，见 R6） | 全部封面 |
| E19 | `MediaComponents.swift:86-122` | `RemoteImage(url:)` 只接受 URL，不支持请求头/签名 | 参数化 | 全部封面 |
| E20 | `MediaComponents.swift:396,489,492-504,552,733,960,1244,1283,1299,1460,1608` | 10 个媒体组件以 `BaseItemDto` 为参数（`PosterCard`/`ArtistCard`/`TrackRowActions`/`PaperTrackRow`/`MusicRow`/`TrackTableRows`/`TrackTable`/`PlaylistCard`/`PlaylistCoverMosaic`） | 抽象（改领域模型） | 组件层 |
| E21 | `MediaComponents.swift:564,881,886,912,1131,1140,1161` | 直接读 `track.userData?.isFavorite` / `playCount` / `runtimeSeconds` | 本轮抽象后变为领域字段 | 行内元信息 |
| E22 | `Views/HomeView.swift:264,319,473,494,535,546` | 最近添加/最常播放 Top10/续播卡，全部读派生数组 + `playCount`/`runtimeSeconds` | 字段改名 | 首页 |
| E23 | `Views/Music/PlaylistsView.swift:448,464-475` | `playlist.serverId == nil ? "仅本地" : "已同步到服务器"` + `store.track(id:)` 反查 | 参数化 | 歌单页 |
| E24 | `Components/Components.swift`（1,638 行） | **0 处** Jellyfin 依赖（纯通用 UI：按钮/分段/骨架/Toast…） | **不动** | 无 |
| E25 | `Theme.swift`（1,809 行） | **0 处** | **不动** | 无 |

**统计**：A 类 12 处、B 类 9 处、C 类 22 处、D 类 8 处、E 类 25 处，合计 **76 个耦合点**，其中需「重写/重写性抽象」的 31 处集中在 `State/`（会话与曲库）与 `Player/`（播放地址）。

---

## 3. MusicBackend 协议草案

### 3.1 先回答「UI 层能不能不动」——用数据说话

```
# 命令（可复跑）
$ grep -rho "BaseItemDto" Sources/JellyfinMac/Views Sources/JellyfinMac/Components | wc -l
47
$ grep -rl "BaseItemDto" Sources/JellyfinMac/Views Sources/JellyfinMac/Components | wc -l
13
$ grep -rho "\.\(id\|name\|album\|albumArtist\|userData\|type\|collectionType\|mediaSources\)\b" \
    Sources/JellyfinMac/Views Sources/JellyfinMac/Components | sort | uniq -c | sort -rn
 83 .id      59 .name      32 .album      24 .albumArtist
 14 .userData  5 .productionYear  3 .serverId  2 .type  2 .collectionType  1 .mediaSources
```

**判断**：DTO 在 UI 层出现 47 次（13 文件），但**语义字段只有 9 类、字段名 10 个**，且 `id/name/album/albumArtist/userData` 占 212/225 次读取。这意味着：

- **不需要**重写任何视图布局、不需要改 1,638 行的 `Components.swift`、不需要碰 `Theme.swift`；
- **需要**把 47 处 `BaseItemDto` 类型标注换成领域类型，另加 16 处封面调用、14 处 `userData`、13 处 `runtimeSeconds` 的字段改名；
- 所以正确描述是「**UI 层 95% 的代码不动，但 13 个文件的签名与字段访问必需改**」——这正是「先建领域模型层」的价值：它把「后端差异」关在 47 个字段访问点之外，而不是让 UI 去理解两个后端的字段拼写。

> 口径说明：先前另有统计口径给出「UI 层 25 处」，与本次实测 47 处不符（按 `grep -rc` 计「命中行数」vs `grep -o` 计「出现次数」，且漏计 `MiniPlayerBar.swift:1`）。本文一律采用 `grep -o` 的出现次数。

### 3.2 类型处置决策：`BaseItemDto`/`UserDto` 怎么办

| 方案 | 做法 | 人日（常见） | 优点 | 缺点 | 建议 |
|---|---|---:|---|---|---|
| **A. 直接复用 DTO** | 飞牛 JSON 映射成 `BaseItemDto` 喂给现有 UI | ≈21 | 最快见效，UI 零改动 | 语义污染（`serverId`/`seriesId` 对飞牛无意义）；`artworkURL`（B3）无法多后端；第三个后端到来时成本再翻一倍；无法做离线缓存模型 | 仅适合**一周 MVP 验证可行性** |
| **B. DTO + 领域模型**（推荐） | `BaseItemDto` 退回 Jellyfin 适配器内部；UI 只认 `Track/Album/Artist` | ≈32.5 | 一次到位；Jellyfin 的影视字段可顺手删除（**负工作量 −0.3~−0.5 人日**，见 `JellyfinModels.swift:70-106`）；可加 `PlayableSource`、`ArtworkRef` 等真正需要的抽象 | 需要改 13 个 UI 文件的签名 | **目标形态** |

**推荐路径：MVP 用 A（但**新代码分层写**，不往 `BaseItemDto` 上继续加字段）→ 跑通后 3 人日切到 B。**不要把 A 当成终态，否则第二年加第三个后端会付双倍。

### 3.3 协议草案（Swift）

```swift
// ============================================================================
// 领域模型层：UI 只认这一层。字段集由「UI 实测读取的 9 类语义」反推（见 3.1）。
// ============================================================================

enum BackendKind: String, Codable, CaseIterable, Identifiable {
    case jellyfin, feiniu
    var id: String { rawValue }
    var displayName: String { self == .jellyfin ? "Jellyfin" : "飞牛音乐" }
}

/// 后端能力声明：UI/数据层用它决定「显示什么、跳过什么」，而不是到处 `if backend == .jellyfin`
struct BackendCapabilities {
    var supportsPaging: Bool          // 曲库是否必须分页（飞牛：真；Jellyfin：可全量）
    var supportsFavorites: Bool       // 收藏（当前 UI 有 14 处依赖）
    var supportsPlayStats: Bool       // playCount / lastPlayedDate（最常/最近播放页依赖）
    var supportsResume: Bool          // 续播进度（首页「继续播放」依赖）
    var supportsLyrics: Bool
    var supportsRemotePlaylists: Bool // 歌单写
    var supportsTranscode: Bool       // 是否支持服务端转码（Quality 设置项是否有意义）
    var serverSideSorting: Set<SortKey>  // 服务端支持哪些排序键
}

struct Track: Identifiable, Hashable {
    let id: String
    let backend: BackendKind
    let title: String
    let artistName: String?
    let albumName: String?
    let albumID: String?
    let duration: Double            // 秒（领域层统一；不要再让 ticks 泄漏）
    let discNumber: Int?            // 碟号/轨号：专辑内排序不再依赖服务端（R5）
    let trackNumber: Int?
    let isFavorite: Bool
    let playCount: Int
    let lastPlayedAt: Date?
    let resumePosition: Double      // 秒，0 表示未播
    let dateAdded: Date?
    let cover: ArtworkRef?
}

struct Album: Identifiable, Hashable {
    let id: String; let backend: BackendKind
    let title: String; let artistName: String?
    let year: Int?; let trackCount: Int?
    let dateAdded: Date?; let isFavorite: Bool
    let cover: ArtworkRef?
}

struct Artist: Identifiable, Hashable {
    let id: String; let backend: BackendKind
    let name: String; let albumCount: Int?; let cover: ArtworkRef?
}

/// 封面引用（**不是 URL**）：签名/尺寸/请求头交给后端实现，缓存键由引用自身决定
enum ArtworkRef: Hashable {
    case track(backend: BackendKind, id: String, tag: String?)
    case album(backend: BackendKind, id: String, tag: String?)
    case artist(backend: BackendKind, id: String, tag: String?)
    /// 稳定的缓存键：不随签名/时间戳变化（避免 ImageCache 击穿，见 R6）
    var cacheKey: String { … }
}

struct LyricLine { let text: String; let start: Double? }   // 秒，nil = 无时间轴

struct Page { let offset: Int; let limit: Int }
struct Paged<Element> { let items: [Element]; let total: Int?; let hasMore: Bool }

struct SearchResults { var tracks: [Track]; var albums: [Album]; var artists: [Artist] }

struct BackendSession {
    let kind: BackendKind
    let serverURL: URL
    let userID: String
    let userName: String
    let token: String
    let deviceID: String
    /// 唯一会话标识：Keychain / UserDefaults 的命名空间（修 C9/C21/C22）
    var scopeID: String { "\(kind.rawValue)@\(serverURL.absoluteString)#\(userID)" }
}

// ============================================================================
// 播放源：**返回值不是 URL**（这是飞牛带来的形状变化，见 3.4）
// ============================================================================

enum PlayableSource {
    /// 直接可播：URL 已带凭据（Jellyfin 的 api_key 走这条）
    case url(URL)
    /// 需要请求头（Authorization 等）：播放器侧用 AVURLAsset + HTTP header
    case urlWithHeaders(URL, headers: [String: String])
    /// 需要逐请求签名 / 自定义协议：播放器侧必须挂 AVAssetResourceLoaderDelegate
    case resourceLoader(URL, auth: RequestAuthorizer)
    /// 需要先建转码会话（POST /track/transcode → HLS）：先 prepare 再播
    case transcodedSession(prepare: () async throws -> PlayableSource, teardown: (() async -> Void)?)
}

protocol RequestAuthorizer: Sendable {
    func authorize(_ request: inout URLRequest) async throws
}

// ============================================================================
// 主协议：必做能力（登录 / 曲库 / 专辑 / 艺人 / 搜索 / 歌词 / 封面 / 播放 / 收藏 / 登出）
// ============================================================================

protocol MusicBackend: AnyObject, Sendable {
    var kind: BackendKind { get }
    var capabilities: BackendCapabilities { get }
    var session: BackendSession? { get }

    // 1) 登录 / 会话 / 登出
    func login(server: URL, username: String, password: String,
               device: DeviceIdentity) async throws -> BackendSession
    func restore(_ session: BackendSession) async throws -> BackendUser   // 校验 token
    func logout() async

    // 2) 媒体库与分页
    func musicLibraries() async throws -> [LibraryRef]
    func tracks(inLibrary id: String, sort: SortKey, page: Page) async throws -> Paged<Track>
    func albums(inLibrary id: String, sort: AlbumSort, page: Page) async throws -> Paged<Album>
    func artists(inLibrary id: String, page: Page) async throws -> Paged<Artist>

    // 3) 详情
    func album(id: String) async throws -> Album
    func tracks(inAlbum id: String) async throws -> [Track]        // 领域层保证按碟/轨排序
    func artist(id: String) async throws -> Artist
    func albums(byArtist id: String) async throws -> [Album]
    func tracks(byArtist id: String) async throws -> [Track]

    // 4) 搜索
    func search(_ term: String, limit: Int) async throws -> SearchResults

    // 5) 封面（同步返回「请求描述 + 缓存键」，异步下载交给 ImageCache）
    func artworkRequest(_ ref: ArtworkRef, width: Int) -> (url: URL, headers: [String: String])?

    // 6) 播放（见 3.4：异步，因为可能要建转码会话）
    func playableSource(for trackID: String, quality: AudioQuality) async throws -> PlayableSource

    // 7) 收藏
    func setFavorite(trackID: String, favorite: Bool) async throws
    func setFavorite(albumID: String, favorite: Bool) async throws

    // 8) 歌词
    func lyrics(for trackID: String) async throws -> [LyricLine]
}

// ============================================================================
// 可选能力：拆成小协议，避免飞牛 MVP 被迫写 8 个空实现
// ============================================================================

protocol PlaybackProgressReporting: AnyObject {
    func report(_ event: PlaybackEvent, trackID: String,
                position: Double, duration: Double, isPaused: Bool) async
}
enum PlaybackEvent { case started, progress, stopped }

protocol RemotePlaylistBackend: AnyObject {
    func remotePlaylists() async throws -> [RemotePlaylist]
    func createPlaylist(name: String, trackIDs: [String]) async throws -> String
    func replacePlaylist(id: String, name: String, trackIDs: [String]) async throws
    func deletePlaylist(id: String) async throws
    func addTrack(_ trackID: String, toPlaylist id: String) async throws
    func removeTrack(_ trackID: String, fromPlaylist id: String, entryID: String?) async throws
}

// ============================================================================
// 注册表：替换 APIClient.shared 的全局可变单例（修 A4）
// ============================================================================

@MainActor
final class BackendRegistry {
    static let shared = BackendRegistry()
    private(set) var active: (any MusicBackend)?
    private var all: [BackendKind: any MusicBackend] = [:]
    func register(_ backend: any MusicBackend)
    func activate(_ kind: BackendKind)                    // 切换后端
    var progressReporting: (any PlaybackProgressReporting)? { active as? PlaybackProgressReporting }
    var remotePlaylists: (any RemotePlaylistBackend)? { active as? RemotePlaylistBackend }
}
```

**草案要点说明**

1. **`playableSource` 是 `async throws`**，而现状 `streamURL` 是同步纯函数（`MusicPlayerModel.swift:453`）。这不是洁癖：飞牛要先 `POST /track/transcode` 才能拿到 HLS 地址，同步签名还给不出来。代价见 4.0（M8）。
2. **`ArtworkRef` 而不是 `URL`**：现状 `artworkURL(width:)` 在模型里拼 URL 并读全局单例（B3），多后端后模型层根本拿不到「当前后端」。改成引用后，`ImageCache` 的键用 `ref.cacheKey`（稳定），而 URL 每次带新签名也不影响缓存。
3. **`duration` 统一为秒**：现状 `runtimeSeconds` 用 `runTimeTicks / 10_000_000`（`JellyfinModels.swift:77`），歌词 `start` 同款（`:129`）。领域层只保留秒，ticks 留在适配器。
4. **`RemotePlaylistBackend` 单拆**：飞牛 MVP 大概率没有歌单写能力，拆开后飞牛可以不实现，`PlaylistSyncService` 用 `remotePlaylists` 是否为 nil 来门控（对应 C16/C17/C18）。
5. **`scopeID`**：一行解决 C9/C21/C22 的「同用户名两台服务器串号」问题。

### 3.4 必须单列的一节：播放源为什么不能是 `URL`

现状（`MusicPlayerModel.swift:453-483`）：

```swift
private func streamURL(for track: BaseItemDto) -> URL? {
    … base.appendingPathComponent("/Audio/\(track.id)/stream")      // :456
    query: static=true | (audioCodec=mp3&transcodeContainer=mp3&maxAudioBitrate=…)  // :463-476
    query.append(("api_key", token))                                 // :478-480
}
…
let playerItem = AVPlayerItem(url: url)                              // :340  ← 无任何请求头
```

`AVPlayerItem(url:)` 意味着**播放器只会发一个裸 GET**。这对 Jellyfin 恰好成立（凭据走 query `api_key`），对飞牛则可能全盘不成立：

| 飞牛侧特征（待其 API 文档确认） | 对 Overtone 的直接后果 |
|---|---|
| 流地址形如 `/api/v1/track/stream?guid=` | `streamURL` 里所有 `static/audioCodec/transcodeContainer/maxAudioBitrate` 参数**全部无意义**——音质设置（`AppSettings.Quality`，`:14-40`）需降级为「后端不支持转码」 |
| 转码是 `POST /track/transcode` → 返回 HLS | 取播放地址变成**两步异步**，且 HLS 天然不支持 `AVPlayerItem` 的单一裸 URL 语义以外的操作；`loadCurrent()`（`:330`）与它的 **10 个调用点**（`:114,138,142,148,151,175,222,411,417,423`）全部要进 async 上下文 |
| **每个请求都要 authx 签名** | `AVPlayerItem(url:)` 拿不到 header/签名 → 必须在 `AVAssetResourceLoaderDelegate` 里拦截 `AVAssetResourceLoadingRequest` 并**逐次重签**（HLS 每个分片一个请求）。这是本项目从未写过的一块代码：+1~2 人日，且调试成本高（播放器错误信息极不友好） |
| 签名/时间戳随请求变化 | `ImageCache`（`MediaComponents.swift:8-83`）以 `url.absoluteString` 为键（`:16`）→ 每次签名不同即**缓存键不同**，LRU 永远命不中、封面反复重下。必须改为按 `ArtworkRef.cacheKey` 缓存（E18/E19） |

**因此协议里播放能力的返回值定为 `PlayableSource`**，四种形态分别对应：Jellyfin 直连（`.url`）、需要 header、需要逐请求签名（`.resourceLoader`）、需要先建会话（`.transcodedSession`）。这样 Jellyfin 的实现是一行 `.url(...)`，飞牛的实现可以在不改动协议的前提下选择最省事的形态。

> 补充判断：若飞牛 API 只能通过签名 header 播放，`.urlWithHeaders` 走 `AVURLAsset(url:options:[AVURLAssetHTTPHeaderFieldsKey: headers])` 最省事，但该键是非公开 API（个人使用可接受，上架不可）。**建议直接按 `.resourceLoader` 设计，别赌。**

---

## 4. 分模块工作量评估

### 4.0 完整方案（方案 B：领域模型 + 双后端）

单位：人日（6h/天）。「新增行/改动行」为净代码量，不含注释与空行。

| # | 模块 | 主要文件 | 新增行 | 改动行 | 乐观 | 常见 | 悲观 | 置信度 | 必做/MVP |
|---|---|---|---:|---:|---:|---:|---:|---|---|
| M1 | 领域模型层（`Track/Album/Artist/ArtworkRef/Paged/SearchResults` + Jellyfin DTO→领域映射；顺手删除影视字段） | 新增 `Models/Domain/`；改 `JellyfinModels.swift` | 380–520 | 120–200 | 2.0 | 3.0 | 4.5 | 高 | 必做（B 方案） |
| M2 | 网络基础设施（`HTTPClient`：URL 组装/超时/错误映射/可插拔 JSON 解码；`AuthHeaderProvider`） | 新增 `Networking/HTTPClient.swift`；改 `APIClient.swift` | 220–300 | 80–150 | 1.0 | 1.5 | 2.5 | 高 | 必做 |
| M3 | `MusicBackend` 协议 + `BackendCapabilities` + `BackendRegistry`/`SessionStore`（替换 14 处 `APIClient.shared`） | 新增 `Backend/`；改 `AppState.swift` | 180–260 | 60–120 | 1.0 | 1.5 | 2.5 | 高 | 必做 |
| M4 | `JellyfinBackend` 适配器（10 类端点从 State/ViewModel/View 搬入；camelize 解码、图片、收藏、歌词、进度上报、歌单） | 新增 `Backend/Jellyfin/`；改 `MusicDataStore.swift`、`PlaylistSyncService.swift`、`PlaybackReporter.swift`、两个 ViewModel、`TrackInfoView.swift`、`NowPlayingView.swift` | 480–650 | 260–400 | 3.0 | 4.5 | 6.5 | 中 | 必做 |
| M5 | `FeiniuBackend`（API 摸清 + 实现：登录/分页/专辑/艺人/搜索/封面/播放源/收藏/歌词） | 新增 `Backend/Feiniu/` | 350–700 | 0–60 | 3.0 | 4.5 | 8.0 | **低** | 必做 |
| M6 | 数据层（`MusicDataStore` 多后端 + 分页接口 + 全量缓存策略 + 派生数据换领域模型 + `musicLibraries()`） | `MusicDataStore.swift` | 200–320 | 120–220 | 2.0 | 3.0 | 4.5 | 中 | 必做 |
| M7 | UI 层 47 处 DTO → 领域模型（13 文件；16 处封面、14 处 userData、13 处时长、60 处 album/albumArtist） | `Views/` 11 文件、`MediaComponents.swift`、`MiniPlayerBar.swift` | 40–80 | 320–520 | 2.0 | 3.0 | 4.5 | 中 | 必做 |
| M8 | 播放链路（`PlayableSource` + `AVURLAsset`/ResourceLoader + reporter 抽象 + `loadCurrent` 异步化 10 处） | `MusicPlayerModel.swift`、`PlaybackReporter.swift`、新增 `Player/ResourceLoader.swift` | 200–330 | 80–160 | 2.0 | 3.0 | 5.0 | 中 | 必做 |
| M9 | 播放列表多后端（`Playlist` 加 `backendID`/`remoteBinding`；`PlaylistSyncService` 走 `RemotePlaylistBackend` + 能力门控） | `PlaylistStore.swift`、`PlaylistSyncService.swift` | 140–220 | 100–180 | 1.5 | 2.5 | 4.0 | 中 | **可延后**（MVP 只做门控） |
| M10 | 登录/设置 UI（后端选择器、按后端切换服务器字段、文案、设置页账号组） | `LoginView.swift`、`SettingsView.swift` | 100–170 | 120–200 | 1.0 | 1.5 | 2.5 | 高 | 必做 |
| M11 | 会话与凭据（Keychain `service` 命名空间 + `scopeID` 账号 + `UserDefaults` 键命名空间 + 老凭据迁移） | `KeychainHelper.swift`、`AppState.swift` | 120–200 | 90–160 | 1.0 | 2.0 | 3.5 | 中 | 必做（单服务器版可缩半） |
| M12 | 联调/回归/打包（**无测试 target**，两后端 × 两视觉风格 × 五档断点全手测） | `scripts/` | 0–50 | 0–50 | 1.5 | 2.5 | 4.0 | 中 | 必做 |
| | **合计** | | **~2,410–3,800** | **~1,350–2,420** | **21.0** | **32.5** | **52.0** | | |
| | 负工作量：删除影视字段与 `backdropURL`/`primaryImageURL` 回退（`JellyfinModels.swift:70-106`、`APIClient.swift:186-198`） | | −30～−60 | −60～−120 | −0.3 | −0.4 | −0.5 | 高 | — |

**必做口径（M9 延后）**：乐观 **19.5** / 常见 **30.0** / 悲观 **48.0** 人日 ≈ 常见 **6 周**（单人）。

### 4.1 可延后项（增量）

| 项 | 增量（乐观/常见/悲观） | 说明 |
|---|---|---|
| 曲库**真分页 + 懒加载**（现有 `load()` 无 `Limit/StartIndex`，`MusicDataStore.swift:213-233`） | +1.5 / +2.0 / +3.5 | 全量拉取在小曲库可先顶住；上万首会 OOM/卡顿 |
| 飞牛侧**歌单写**（M9 完整） | +1.5 / +2.5 / +4.0 | MVP 用能力门控跳过 |
| **多服务器并存**（同时登录两台，侧栏切换） | +2.0 / +3.0 / +5.0 | README「已知限制：仅支持单个服务器」；MVP 只做「切后端即重登」 |
| 封面**落盘缓存 + 离线**（`ImageCache` 只有内存 LRU 400 张） | +2.0 / +3.0 / +5.0 | `AppSettings.imageCacheLimitGB`（`:192`）目前只是设置项文案，未真正生效 |
| 飞牛歌词（若是 LRC 文本而非结构化行） | +0.3 / +0.5 / +1.0 | 需 LRC 解析 |
| 设置页多服务器管理 UI | +1.0 / +1.5 / +2.5 | 目前只有一个「服务器地址」展示位（`SettingsView.swift:336-362`） |

### 4.2 方案 A（复用 `BaseItemDto`）对照

只做「飞牛 JSON → `BaseItemDto`」映射 + 后端分派，不动 UI：

| 模块 | 乐观/常见/悲观 | 备注 |
|---|---|---|
| 飞牛适配（含映射到 DTO） | 3.0 / 4.5 / 8.0 | M5 不变，最大头 |
| 播放链路 | 2.0 / 3.0 / 5.0 | M8 不变（省不掉） |
| 数据层分派 | 1.5 / 2.0 / 3.0 | 比 M6 省一半 |
| 会话/凭据 | 1.0 / 2.0 / 3.5 | M11 不变 |
| 登录 UI | 1.0 / 1.5 / 2.5 | M10 不变 |
| 网络分派（不拆 HTTPClient） | 0.5 / 1.0 / 1.5 | — |
| 联调回归 | 1.5 / 2.5 / 4.0 | M12 不变 |
| DTO 映射层 | 1.0 / 1.5 / 2.5 | 替代 M1+M7 |
| **合计** | **11.5 / 18.0 / 30.0** | 省 ~14.5 人日，但把技术债留给下一次 |

**关键判断**：两个方案差 14.5 人日（常见口径），却相差「第三次加后端要 5 人日还是 25 人日」。若飞牛只是实验性需求 → 走 A；若 Overtone 打算长期多后端 → 走 B，且 B 的 M1/M2/M3 可以**先于飞牛 API 摸清就开工**（不阻塞）。

---

## 5. 风险与隐含依赖（按严重度排序）

**R1 · 播放源不是 URL（高）**
证据：`MusicPlayerModel.swift:340` 的 `AVPlayerItem(url:)` 与 `:453-483` 的同步 `streamURL`。飞牛若需逐请求签名/HLS 转码 → `AVAssetResourceLoaderDelegate` 是新模块（+1~2 人日），且 `loadCurrent()` 要异步化，牵动 **10 个调用点**（`:114,138,142,148,151,175,222,411,417,423`）。缓解：M8 单独排期，先用 `.url` 形态验证飞牛直链是否可用，再决定是否上 ResourceLoader。

**R2 · 飞牛 API 可控性（高，最大不确定源）**
若只有网页端（需 cookie/私有签名）而无稳定 API，M5 的悲观值（8 人日）会失守，且签名算法变更即断。缓解：**先做 0.5 人日 spike**（登录 + 列表 + 一条流地址），再决定是否立项；MVP 阶段把飞牛放在 `Backend` 协议后，失败可整块摘掉不影响 Jellyfin。

**R3 · 「全量入内存 + 客户端派生」假设（高）**
证据：`MusicDataStore.swift:213-233` 三次请求**无 `Limit`/`StartIndex`**；`:100-122` 在客户端对全库做 6 次排序/过滤并缓存；`:171-173` 注释直言「服务端已按 SortName 返回」。飞牛若强制分页（如 100/页），`store.tracks` 不再等于全集 → 首页「最常播放 Top10」「最近添加」「继续播放」、资料库三种排序、智能歌单匹配（`smartTracks` `:246-255`）全部失真。缓解：M6 里把「全量数组」换成「分页窗口 + 按需预取」，但 UI 假定 `tracks` 完整的地方要逐个审（`HomeView:264,319`、`PlaylistsView:468`、`PlaylistDetailView:39`、`PlaylistSyncService:126`）。

**R4 · 服务端 `userData` 缺失 → 功能静默消失（中高）**
证据：收藏 14 处读 `userData?.isFavorite`；「最常播放」依赖 `playCount`（`MusicDataStore.swift:103-108`、`HomeView:494,535,594`）；「最近播放」依赖 `lastPlayedDate`（`:109-117`）；「继续播放」依赖 `playbackPositionTicks`（`:78,125-139`）。飞牛若没有播放统计/续播，这些模块会**空着而不是报错**——用户会以为「坏了」。缓解：`BackendCapabilities.supportsPlayStats/supportsResume` 门控 + 空态文案（首页已有 `EmptyState`，改动小）。

**R5 · 排序契约（中）**
证据：专辑内曲序由服务端 `SortBy=ParentIndexNumber,IndexNumber,SortName` 保证（`MusicViewModels.swift:77`）；曲库排序「服务端已按 SortName」（`MusicDataStore.swift:172`）。飞牛若不支持多维排序 → 专辑内曲目乱序，这是**最刺眼的体验缺陷**。缓解：领域 `Track` 带 `discNumber/trackNumber`，适配器内本地排序兜底（已在 3.3 草案中预留）。

**R6 · 图片 tag 与缓存键（中）**
证据：`ImageCache` 键 = `url.absoluteString`（`MediaComponents.swift:16`）；`imageURL` 带 `tag`（`APIClient.swift:180`）与 `api_key`（`:181`）。Jellyfin 的 `tag` 变化即「图换了」，很合理；但飞牛若 URL 带时间戳签名 → 键每次都变，内存 LRU（400 张）彻底失效，滚动即重下。缓解：`ArtworkRef.cacheKey`（3.3）+ `RemoteImage` 改吃 `ArtworkRef`（E19）。

**R7 · 媒体库概念（中）**
证据：`collectionType == "music"` 在 3 处重复（`MusicDataStore.swift:198`、`MainView.swift:691`、`SettingsView.swift:299`），且请求全靠 `ParentId`（`MusicDataStore.swift:259,270,281`）。飞牛可能**没有「媒体库」这一层**（直接全库曲目）。缓解：协议里 `musicLibraries()` 允许返回单元素数组；`resolveLibraryId` 的三份重复代码合并到一处（顺手修掉）。

**R8 · 多服务器与凭据迁移（中，不可回滚）**
证据：`UserDefaults` 键 `serverURL/token/username` 单值（`AppState.swift:19-26`）；Keychain `service` 写死 `com.jellyfin.mac-client`、account = 用户名（`KeychainHelper.swift:5-6`、`AppState.swift:55`）→ 两台服务器上的**同名用户会互相覆盖**。更麻烦的是 `docs/naming.md` 明确写着 Bundle ID 与数据目录「**未改**，改了要重新登录一次 / 会丢列表」：`Application Support/JellyfinMac/playlists.json`（`PlaylistStore.swift:42`）。缓解：**不要改 Bundle ID 与目录名**，只加命名空间（`scopeID`）+ 一次性迁移；迁移失败必须保留旧键兜底（代码里已有这种谨慎模式可照抄：`AppState.swift:48-57, 105-113`）。

**R9 · 没有测试 target，回归全靠手测（中）**
证据：`Package.swift` 只有 `executableTarget`，`grep -c testTarget` = 0。双后端 × 两视觉风格（glass/paper）× 五档断点（W0–W4）→ 手测矩阵至少 20 组。缓解：M12 按 2.5 人日预留；建议先补 3 个纯函数单测（`formatPlaybackTime`、`camelize`、派生数据排序）作为回归锚点，成本 <0.5 人日。

**R10 · 领域模型反向依赖网络单例（中，必须先断）**
证据：`JellyfinModels.swift:83-91` 的 `artworkURL(width:)` 直接调 `APIClient.shared.imageURL`。任何「模型 + 多后端」的组合都会在这里死锁（模型不知道当前后端是谁）。缓解：这一步必须在 M1 就做掉（改 `ArtworkRef`），否则后面越改越疼。

**R11 · 启动时序（低中）**
证据：`MainView.swift:678-681` 用 100 次 ×100ms 轮询等 `APIClient.shared.baseURL/user` 就绪；`:697` 无条件跑 `syncAll()`；`PlaybackReporter` 在 `loadCurrent` 里就开始上报（`:352`）。飞牛无歌单/无进度上报时，这些路径会**每次启动打一串失败请求**。缓解：能力门控 + 让 `bootstrap` 等 `SessionStore.isReady` 而不是轮询单例字段。

**R12 · 转码假设是全局的（低中）**
证据：`AppSettings.swift:14-40`（`Quality.bitrate`）+ `:226-229`（`requiresTranscode`）→ 直接决定 `MusicPlayerModel.swift:463-476` 的转码参数。飞牛若不支持转码，设置页「音质」四项会变成**点了没反应的假开关**。缓解：按 `capabilities.supportsTranscode` 置灰并给文案。

---

## 6. MVP 建议切片（一周内跑通「登录 + 浏览 + 播放」）

### 6.1 目标与验收

**范围**：双后端可选其一（一次一个），飞牛侧只做「登录 / 曲库列表 / 专辑 / 艺人 / 封面 / 播放」。**不做**领域模型层、不做歌词、不做收藏、不做歌单同步、不做分页、不做多服务器并存。

**验收标准**（可执行）：
1. 登录页能选「Jellyfin / 飞牛音乐」，填地址+账号能登录且重启免登录；
2. 首页能出「最近添加」（若飞牛无入库时间则显示空态而不是崩溃）；
3. 资料库→专辑→点某张专辑→曲目顺序正确→点播；
4. 一首歌能完整播完并自动下一首（顺序播放）；
5. 迷你条 / 正在播放页标题、艺人、封面正确；
6. Jellyfin 侧行为**零回归**（原路径全绿）。

### 6.2 只动这 5 个文件（+1 个新文件）

| 顺序 | 文件 | 改动 | 行数量级 | 人日（常见） |
|---|---|---|---:|---:|
| 1 | **新增** `Networking/FeiniuClient.swift` | 飞牛 HTTP + authx 签名 + JSON→`BaseItemDto` 映射（`id/name/album/albumArtist/runTimeTicks/imageTags` 五个字段就够跑通） | 250–350 | 1.5 |
| 2 | `Networking/APIClient.swift` | 加 `var activeBackend: BackendKind`；`imageURL`/`fetchLyrics`/`setFavorite` 按后端分派；`streamURL` 分派出口（先只支持直链） | +60 / −10 | 0.5 |
| 3 | `State/AppState.swift` | `login()` 按后端走 `FeiniuClient.login`；`loadLibraries()` 对飞牛返回伪造单库（`collectionType="music"`）；`normalize` 复用 | +80 / −20 | 0.9 |
| 4 | `State/MusicDataStore.swift` | `load()` 分派：飞牛走 `FeiniuClient.tracks/albums/artists`（**全量拉取**，先不分页）；`resolveLibraryId` 兜底 | +50 / −15 | 0.6 |
| 5 | `Player/MusicPlayerModel.swift` | `streamURL(for:)` 分派到后端；飞牛侧接受「已签名直链」；若需 header 则临时用 `AVURLAsset` | +40 / −10 | 0.9（含踩坑） |
| 6 | `Views/LoginView.swift` | 顶部加后端 `SegmentedControl`（复用 `Components.swift:488` 的 `SegmentedControl`）；`clientName` 与「高级选项」按后端显隐；文案参数化（`:261`） | +45 / −10 | 0.4 |
| | **合计** | | **≈525 / −65** | **≈4.8** |

**乐观 3.0 / 常见 4.8 / 悲观 7.0 人日**。悲观档超一周的原因只可能是一个：**飞牛的播放链路需要签名 ResourceLoader**（R1）或 API 需逆向（R2）。

### 6.3 建议排期（5 个工作日）

| 日 | 工作 | 出口标准 |
|---|---|---|
| D1 | 飞牛 API spike：登录、曲库列表、封面、一条流地址（0.5 人日上限，超了就上报） | 能手写 curl 拿到 4 样东西 |
| D2 | `FeiniuClient` + `BaseItemDto` 映射 | `swift run` 控制台能打印 20 首曲目 |
| D3 | `AppState` / `MusicDataStore` 分派 + 登录页选择器 | 登录成功进主界面，资料库出专辑 |
| D4 | 播放链路分派 + 封面 | 点一首歌能出声，迷你条信息正确 |
| D5 | 回归 Jellyfin 全路径 + 打包（`scripts/build-app.sh`） | 验收 6 条全绿 |

### 6.4 MVP 之后的第一件事

把 MVP 里「临时塞进 `APIClient` 的分派」换成 `MusicBackend` 协议（M3/M4，约 2 人日），再补领域模型层（M1/M7，约 6 人日）。**顺序不能反**——先协议后实现会让 MVP 卡在抽象设计上，先实现后协议则是一次几乎无风险的机械重构（此时所有调用点都已被 MVP 摸过一遍）。

---

## 7. 附录

### 7.1 测量命令（可复跑）

```bash
# 文件与行数
find Sources -name "*.swift" | xargs wc -l | tail -1
# DTO 泄漏（总 / UI 层 / 文件数）
grep -rho "BaseItemDto" Sources --include=*.swift | wc -l
grep -rho "BaseItemDto" Sources/JellyfinMac/Views Sources/JellyfinMac/Components --include=*.swift | wc -l
grep -rl "BaseItemDto" Sources --include=*.swift | wc -l
# UI 真正读到的字段
grep -rho "\.\(id\|name\|album\|albumArtist\|userData\|type\|collectionType\|mediaSources\)\b" \
  Sources/JellyfinMac/Views Sources/JellyfinMac/Components | sort | uniq -c | sort -rn
# 单例泄漏
grep -rl "APIClient.shared" Sources --include=*.swift | wc -l
# 无测试 target
grep -c "testTarget" Package.swift
# 端点全集
grep -rn '"/\(Items\|Audio\|Users\|Playlists\|Sessions\)' Sources --include=*.swift
```

### 7.2 关键行号索引（便于复核）

| 主题 | 位置 |
|---|---|
| 认证头 | `Networking/APIClient.swift:77-86` |
| PascalCase 解码 | `Networking/APIClient.swift:135-159` |
| 封面 URL | `Networking/APIClient.swift:169-198` |
| 收藏 / 歌词 | `Networking/APIClient.swift:209-222` |
| DTO 本体与影视字段 | `Models/JellyfinModels.swift:27-63, 70-106` |
| 模型反向依赖网络 | `Models/JellyfinModels.swift:83-91` |
| 全量加载（无分页） | `State/MusicDataStore.swift:213-233` |
| 客户端派生排序 | `State/MusicDataStore.swift:100-122, 125-145` |
| 查询构造 | `State/MusicDataStore.swift:257-289` |
| 歌单同步 | `State/PlaylistSyncService.swift:25-178` |
| 歌单持久化 | `State/PlaylistStore.swift:40-44, 237-270` |
| 转码开关 | `State/AppSettings.swift:14-40, 226-229` |
| Keychain service | `State/KeychainHelper.swift:5-6, 12` |
| 播放地址 | `Player/MusicPlayerModel.swift:453-483` |
| 播放器装配 | `Player/MusicPlayerModel.swift:330-372` |
| 进度上报 | `Player/PlaybackReporter.swift:88-120` |
| 登录流程 | `State/AppState.swift:36-103`，`Views/LoginView.swift:486-512` |
| 启动装载 | `Views/MainView.swift:676-701` |
| 设置·服务器与账号 | `Views/SettingsView.swift:325-396` |
| 图片缓存键 | `Components/MediaComponents.swift:8-83` |
| 纯通用 UI（不动） | `Components/Components.swift`（0 处 DTO）、`Theme.swift`（0 处） |

### 7.3 待确认假设（会影响估算，建议立项前先钉死）

1. **飞牛音乐的 API 形态**：是否有稳定 REST + 文档？还是只能抓包/逆向？签名算法是否可以离线复现（HMAC）？
2. **播放是否必须走 HLS + 逐请求签名**？（决定 M8 是 3 还是 5 人日，也是 MVP 能否一周的唯一硬变量）
3. **是否有播放统计/续播/收藏**（`playCount`/`lastPlayedDate`/`playbackPositionTicks` 的等价物）？决定首页 4 个模块是否降级。
4. **是否有「媒体库」概念与多维排序**（决定 R5/R7 的兜底量）。
5. **是否需要真正同时登录两个后端**（README 现在写的是「仅支持单个服务器」；若只需「切后端重登」，M11 与多服务器项可各砍一半）。
6. **产品定位**：飞牛是实验性尝鲜还是长期并列支持？（决定走方案 A 的 21 人日，还是 B 的 32.5 人日）

---

*本文只做分析与方案，不含任何源码改动。行号以当前工作树为准，重构后会漂移，复核请用 §7.1 的命令重新定位。*
