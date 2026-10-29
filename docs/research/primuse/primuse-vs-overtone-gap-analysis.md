# Primuse → Overtone 功能取舍分析

> 目的：回答「Primuse（猿音）有哪些做得好、Overtone 还没有、值得加」。
> 事实来源：`primuse-feature-inventory.md`（本地 1.12.1 资源逆向）、`primuse-external.md`（官网/App Store/开源仓库/CHANGELOG），以及 Overtone 当前工作区源码（含未提交的多后端重构）。
> 结论先行：**Primuse 值得学的不是「多」，而是「把播放器该做的事做完整」——听歌数据、播放衔接、歌词细节、Mac 桌面存在感。它的曲库管理、AI、音频工程、多源生态都不该跟。**

---

## 1. 先看清两者不是一类产品

| | Primuse（猿音） | Overtone（泛音） |
|---|---|---|
| 定位 | **无服务端的全能曲库播放器**：自己扫描 NAS/云盘/本地文件，建立并管理曲库 | **Jellyfin / 飞牛音乐客户端**：曲库在服务器，客户端只管浏览与播放 |
| 曲库来源 | 20+ 种（SMB/NFS/WebDAV/云盘/Subsonic/Navidrome/Emby/Plex/Jellyfin…） | Jellyfin + 飞牛音乐两套后端 |
| 播放内核 | 自带 FFmpeg + SFBAudioEngine，双信号链（高保真直通 / 音效处理） | AVPlayer + 服务器直连/转码 |
| 平台 | iPhone / iPad / Mac / Apple TV / Watch（`.strings` 四端共享） | macOS only |
| 规模 | 7 个月 40+ 版本，单版本最多 212 项改动 | 50 个 Swift 文件、约 2.2 万行 |
| 强项 | 音频工程、歌词/KTV、自建曲库管理、来源广度、AI 平台 | 双后端抽象、原生设计（玻璃/纸墨双风格）、本地兜底、轻 |

由此得到取舍原则（本报告所有建议都按它筛过）：

1. **客户端该做、且不依赖自有曲库的** → 值得加：播放衔接、歌词展示、听歌数据、系统集成、分享。
2. **服务器该做的** → 不加：扫描、刮削、标签写回、去重、歌单导入、目录管理。硬做只会复制 Primuse 的性能债（它 CHANGELOG 一大半在偿还扫描/读数发热）。
3. **平台不对的** → 不加：CarPlay、Apple TV、Watch、iPhone 横屏、桌面小组件全家桶。
4. **要换掉播放内核或引入服务端成本的** → 慎重：EQ/独占/DSD、AI、多源聚合。

---

## 2. 推荐清单（按性价比排序）

| # | 能力 | Primuse 好在哪 | Overtone 现状 | 成本 | 优先级 |
|---|---|---|---|---|---|
| 1 | 听歌统计 + 年度报告 | `stats` 141 + `yearly` 101 条；热力图、时段分布、Top、Wrapped 年度报告与「音乐人格」 | **无统计页**；只有「最常播放」列表（按本地/服务端 playCount 排序） | M | **P0** |
| 2 | Last.fm / ListenBrainz 记录 | `scrobble` 68 条；「听够 50% 或 4 分钟才计入」，含 Now Playing 上报、连通性验证 | **无**；只有 Jellyfin 会话进度上报 | S–M | **P0** |
| 3 | 歌词细节：偏移 / 沉浸式 / 翻译 | `lyrics` 371 条；偏移补偿蓝牙延迟、逐字高亮、四档翻译、全屏歌词、多来源、海报 | 有 LRC 同步歌词与封面/歌词切换；**无偏移、无翻译、无全屏、无来源选择** | S–M | **P0** |
| 4 | 播放页音质与链路徽章 | 「Hi-Res 24/96」、实际输出采样率、直通/音效模式、独占状态 | `TrackInfoView` 已有容器/码率/采样率/位深，但**播放页不显示**；`PlayableSource.playMethod` 未展示 | S | **P0** |
| 5 | 真·交叉淡化 + 下一首预取 | 固定/智能两档、1–12s、未缓存时退化为直切、与无缝互斥 | 设置里的「交叉淡入」**只是换曲淡入**（`startFadeIn`），单 AVPlayer，切轨有间隙 | M（预取）/ M–L（真交叉） | P1 |
| 6 | 队列尾部自动续播（InstantMix） | 歌曲电台/相似推荐，队列快完时接着播 | 队列播完即 `stopAtEnd()`，无续播；Jellyfin 有现成 InstantMix 接口 | S–M | P1 |
| 7 | 场景化「开始听」入口 | 专注/运动/睡前/很久没听/新加的/无损精选，纯规则不依赖 AI | 首页只有继续播放/收藏/最近/最常，没有场景入口 | M | P1 |
| 8 | macOS 桌面存在感：菜单栏迷你播放器（+ 桌面歌词） | 菜单栏歌词、迷你播放器、桌面歌词浮窗、歌词上岛 | 只有标准窗口与系统 Now Playing | M | P1 |
| 9 | 歌词/歌曲海报分享 | 16 种歌词海报模板、导出分享 | **无分享能力** | S–M | P2 |
| 10 | 离线缓存 / 固定离线 | 三级缓存、整专/整歌单离线、断网自愈 | 只有图片缓存，无音频缓存 | L | P2（按需可前移） |
| 11 | 智能歌单规则引擎 | 14 字段 × 7 算子 × AND/OR / 规则组排除 | 只有「按艺术家关键字自动收集」的智能列表 | M–L | P2 |
| 12 | 设置搜索 | 74 条设置搜索，且理解「某设置何时不可用」 | 设置 6 组，暂无搜索 | S | P3 |

---

## 3. 逐项说明

### 3.1 听歌统计 + 年度报告（P0，M）

**Primuse 的做法**：时间范围（本周/本月/本年/全部）、播放次数/总时长/活跃天数/去重曲目、GitHub 风格热力图、听歌日历、时长趋势、按小时时段分布、Top 歌曲/艺术家/专辑，以及独立的「年度音乐报告」（10 个章节、16 种音乐人格）。难能可贵的是它对数据边界很诚实：服务端只给累计次数时就不显示热力图（`stats_server_aggregate_boundary`），只给逐次记录时不显示时长（`stats_server_event_boundary`）。

**Overtone 现状**：没有统计页。已有地基其实不错：
- `LocalLibraryState` 已按账号作用域记录 `playCount`、最近播放时间、续播位置（`Sources/JellyfinMac/State/Local/LocalLibraryState.swift:11-13`、`:497-505`）；
- `MusicDataStore` 已有 `mostPlayedTracks` / `recentlyPlayedTracks` 派生缓存（`Sources/JellyfinMac/State/MusicDataStore.swift:67-69`）；
- Jellyfin 侧还有服务端 `playCount` / `lastPlayedDate` 可作种子。

**建议做法**：
1. 在 `LocalLibraryState` 的本地记录里增加**事件流**（`timestamp / itemID / listenedSeconds`），按天聚合后落盘，只保留最近 24 个月、单文件上限保护；这比一次性引入数据库轻。
2. 新增 `StatsView`：周/月/年/全部 + 播放次数/时长/天数 + Top 歌曲/艺人/专辑 + 热力图 + 时段分布。数据完全本地，不上传。
3. 年度报告做成一次性 sheet：月份分布、年度 Top 3、最常时段、听歌人格（用简单四维：昼夜 × 探索/专精 × 新歌/老歌 × 杂食/专注即可），用 `ImageRenderer` 生成分享图。
4. 若 Jellyfin 服务端能提供更准的历史，则优先服务端、本地补缺；飞牛无服务端数据时纯本地——和现有「本地兜底」口径一致。

**为什么值**：这是把「用过」变成「舍不得离开」的功能，成本远低于它带来的产品记忆点，且不依赖任何新协议。

### 3.2 Last.fm / ListenBrainz 听歌记录（P0，S）

**Primuse 的做法**：`scrobble` 68 条，明确「听够 50% 或 4 分钟才计入」，支持 Last.fm OAuth 与 ListenBrainz 用户令牌、Now Playing 上报、令牌验证、断开连接后保留密钥；串烧不计入是刻意设计。

**Overtone 现状**：完全没有。播放事件只走 `MusicBackend.report(_:)`（Jellyfin 的 `/Sessions/Playing*`），没有外部记录；`KeychainHelper` 已存在，可以直接复用。

**建议做法**：
1. 新增 `State/ScrobbleService.swift`，在 `MusicPlayerModel` 的 `startPlayback` / `handleTime` / `finishCurrentTrack` 三处挂接（已天然有 started/progress/stopped 语义）。
2. 规则照抄业界标准：播放 ≥50% 或 ≥4 分钟；暂停/切歌时结算；手动跳转不计入或按比例结算（先做简单版）。
3. 设置页新增「听歌记录」分组：总开关、服务（Last.fm / ListenBrainz）、凭据（存 Keychain）、验证、失败队列（断网时暂存，恢复后补报）。
4. 注意隐私：默认关闭，开关旁明确「会把歌名、艺人、专辑、时间发送到 xx」。

**为什么值**：3–5 天即可完成，直接命中「重度听歌用户」的核心诉求；Primuse、Finamp 都做了，属于音乐客户端的基础设施型功能。

### 3.3 歌词细节（P0/P1，S–M）

**Primuse 的做法**：偏移补偿（蓝牙耳机几百 ms、内置扬声器约 30 ms）、逐字高亮、翻译四档（系统离线/智能/百度/离线包）、全屏歌词与多种换句动效、按文件/服务源切换歌词、打轴编辑、歌词海报。真正值得拿的是前三项与「沉浸式全屏」，后三项（打轴/写回/海报附在 3.9）属于它的重资产，不必照搬。

**Overtone 现状**：有 LRC 同步歌词、封面/歌词切换，但 `LyricLine` 只有 `text` + `start`（`Sources/JellyfinMac/Models/Domain/MediaModels.swift:280-286`）；当前行选中没有偏移量，也没有翻译；全窗口沉浸式歌词需要新视图。

**建议做法**：
1. **偏移**（1 天）：`AppSettings` 增加 `lyricsOffsetSeconds`（±2s，步进 0.1），在 `NowPlayingView` 计算当前行时叠加；按输出设备分组记忆可作为第二步（可先用系统输出设备名做 key）。
2. **沉浸式歌词**（2–4 天）：新视图，大字号居中、当前行放大、非当前行降透明度、背景用封面取色 + 现有玻璃/纸墨令牌；支持点击歌词跳转（Primuse 的 `player_tap_lyrics_to_seek`）。
3. **翻译**（可选，2–3 天）：macOS 15+ 用系统 `Translation` 框架，`#available` 门控；逐行缓存；macOS 13/14 不显示入口。不要把翻译做成联网服务。
4. **歌词来源**（可选，2–3 天）：Jellyfin 缺歌词时，用用户可配置的 LrcApi 兼容地址或 LRCLIB 兜底，本地缓存；设置里写清会发送 title/artist/album/duration。
5. **不做**：逐字打轴与写回（Jellyfin 歌词 API 不提供逐字时间、也不支持写回），歌词编辑器（流媒体客户端不该承担）。
6. **一个现成抓手**：飞牛的 LRC 解析其实已经处理了 `[offset:±ms]`，只是**把增强逐字标签 `<mm:ss.xx>` 剥掉了**（`Sources/JellyfinMac/Backend/Feiniu/FeiniuLyrics.swift:152-163`）。如果服务端歌词本身带逐字标签，恢复解析就能做逐字；Jellyfin 侧通常没有，所以逐字只作为「有则显示」的增强，不作为目标。

**为什么值**：Overtone 已经有歌词骨架，偏移与全屏是「一晚上就能感受到差别」的增强，成本极低。

### 3.4 播放页音质/链路徽章（P0，S）

**Primuse 的做法**：进度条下展示「Hi-Res 24/96」，点开可看完整规格与实际输出采样率；高保真直通/音效输出模式有明确状态；独占失败会降级并说明。

**Overtone 现状**：`TrackInfoView` 已经展示容器格式、比特率、采样率、位深（`Sources/JellyfinMac/Views/Music/TrackInfoView.swift:32-47`），`MediaItem` 也已有 `format/bitrate/sampleRate/bitDepth/channels`（`Sources/JellyfinMac/Models/Domain/MediaModels.swift:154-172`）；但这些信息只在详情页，播放页看不到。`PlayableSource.playMethod`（直连/转码）也没有暴露到 UI。

**建议做法**：`MusicPlayerModel` 发布 `currentPlayMethod` 与当前曲目规格；`NowPlayingView` 在歌名下加一行细字徽章（如 `FLAC · 24bit/96kHz · 直连` 或 `AAC · 320kbps · 转码`），点开进 `TrackInfoView`。半小时到一天即可，但「烧友」感知极强。

### 3.5 真·交叉淡化 + 下一首预取（P1，M）

**Primuse 的做法**：`crossfade_mode` 固定/智能两档、时长 1–12s；自然播完按时长过渡，手动切歌用约 1 秒短过渡；下一首还没缓存到本机时**直接切换而不是硬淡**。它的无缝播放是「预解码下一首 + 边界票据 + 欠载自愈重建」（二进制日志佐证），不是简单 AVQueuePlayer。

**Overtone 现状**：设置项叫「交叉淡入」，实际只是 `startFadeIn()` 把单播放器音量从 0 拉起来（`Sources/JellyfinMac/Player/MusicPlayerModel.swift:432-455`），`crossfadeSeconds` 语义是淡入时长（`AppSettings.swift:231-233`）。换曲是 `replaceCurrentItem`（`:359-398`），切轨有间隙，没有真正的重叠淡化。

**前置债**：当前没有 `AVPlayerItem.status` / `FailedToPlayToEndTime` / `timeControlStatus` 监听（`overtone-baseline.md` §5），直连失败是静默的；`transcodeFallback`/`isHLS` 后端赋了值但播放器没消费。做预取、回退、离线之前先把这块补上，否则会放大故障面。

**建议做法（分两步，不要一次到位）**：
1. **预取 + 短过渡**（3–5 天）：提前解析下一首 `PlayableSource` 并建好 `AVPlayerItem`，队列最后两首时预取；换曲时先淡出再起播，减少「加载空窗」。这一步就能显著改善听感，且不动播放器结构。
2. **双播放器真交叉**（1–2 周）：A/B 两个 `AVPlayer` 交叉，自然播完按时长重叠，手动切歌用 1s；需要处理进度上报（重叠时以「主播放器」为准）、Now Playing、睡眠定时、转码/HLS 不可预取时退化直切。设置项拆成「换曲淡入」与「交叉淡化」两个语义，避免现在的名不副实。
3. **不做无缝（gapless）**：AVPlayer 对跨格式无缝支持不可靠，真无缝要用 AVAudioEngine + 预解码，属于换内核级别；交叉淡化已经能覆盖大部分「专辑连听」场景。

**为什么值**：这是「播放器」最核心的手感，Primuse 在这块明显更成熟；但要注意别为了对齐而重写播放器。

### 3.6 队列尾部自动续播（P1，S–M）

**Primuse 的做法**：歌曲电台/相似推荐、队列快播完时接着播（`home_similar_to_format`「猜你也喜欢」、`radio` 与 Last.fm 相似源）。

**Overtone 现状**：`handleEnded` 在队列末尾直接 `stopAtEnd()`；后端协议里没有 InstantMix（`Sources/JellyfinMac/Backend/MusicBackend.swift:195-259`）。Jellyfin 本身有 `/Items/{itemId}/InstantMix` 接口，飞牛侧能力未知。

**建议做法**：`MusicBackend` 增加可选能力 `instantMix(seedID:limit:)` + `BackendCapabilities.instantMix`；`MusicPlayerModel` 在倒数第二首开始预取；设置项「队列结束后自动续播」（默认开）。

需要注意两后端的语义差别：
- **Jellyfin** 有 `/Items/{itemId}/InstantMix`，能按种子歌给相似曲目，是真正的「电台」；
- **飞牛**只有 `roam`（服务端随机），不是相似度推荐（`docs/research/fnos-music-api.md:501,873`）→ 飞牛侧只能做「随机续播」，用能力位区分，别把随机包装成「猜你喜欢」。

Primuse 还会在队列下方明确标出「以下为自动续播」（`queue_autoplay_section`），建议照此展示，让用户知道哪些是自动加的。成本 2–3 天，能明显减少「播完就静音」的失落感。

### 3.7 场景化「开始听」入口（P1，M）

**Primuse 的做法**：`listening_intent` 把「专注/运动/睡前/很久没听/新加的/无损精选」做成首页卡片，纯本地规则，不依赖 AI；用户可钉选/排序。

**Overtone 现状**：首页只有继续播放、快速入口（收藏/最近/最常/随机全部）、最近添加、最常播放 Top10（`HomeView.swift:37-45`），没有按场景组织的内容。

**建议做法**：不做 AI，做「规则卡片」：
- 专注/运动/睡前：按流派关键词映射（用户可编辑），服务端用 genre 过滤 + 随机排序；
- 很久没听：按 `lastPlayedDate` 升序取；
- 最近新增：按 `dateAdded` 降序；
- 无损精选：按 `bitrate`/`sampleRate` 过滤。
需要给 `MusicBackend` 增加一个通用筛选查询（或复用 `items(...)` 扩展参数）。注意飞牛分页与 5,000 首截断限制，做能力门控。

成本约一周；价值是把首页从「书架」变成「今天听什么」的入口。

### 3.8 macOS 桌面存在感：菜单栏迷你播放器（+ 桌面歌词）（P1，M）

**Primuse 的做法**：菜单栏歌词/图标、迷你播放器、桌面歌词浮窗（可锁定、点击穿透）、歌词上岛、自定义快捷键。这是它 Mac 版不是 iOS 移植的证明。

**Overtone 现状**：标准窗口 + 系统 Now Playing（`MusicPlayerModel.swift:541-598`），没有菜单栏常驻、没有桌面歌词。

**建议做法**：
1. **菜单栏迷你播放器**（1–2 天）：SwiftUI `MenuBarExtra`（macOS 13+）显示当前封面/歌名/播放控制，点击弹出迷你面板；复用 `MusicPlayerModel`。
2. **桌面歌词浮窗**（3–5 天，可选）：`NSPanel` 无边框置顶、可拖动、可锁定/点击穿透，双行歌词；尊重「减少动态效果」。
3. **Shortcuts / App Intents**（2–3 天，可选）：暴露播放/暂停、下一曲、播放歌单、搜索等动作，Primuse 有 11 条 Siri 短语；Overtone 暂无。
4. 不做「歌词上岛」「13 种全屏特效」这类重特效，也**不必专门做 AirPlay**——AVPlayer 跟随系统输出，系统层面已经可用（`overtone-baseline.md` §13）。

**为什么值**：macOS 用户习惯「音乐在后台」，菜单栏是最轻的常驻入口；成本低、差异化强。

### 3.9 歌词/歌曲海报分享（P2，S–M）

**Primuse 的做法**：16 种歌词海报模板、6 种滤镜、3 种画幅、实况照片导出。

**Overtone 现状**：没有任何分享能力。

**建议做法**：只做 3–5 个克制模板（封面 + 当前歌词 + 品牌），`ImageRenderer` 出 PNG，`ShareLink` 调系统分享。不做模板商店/动图。传播价值高，且能复用现有 Theme。

### 3.10 离线缓存 / 固定离线（P2，L）

**Primuse 的做法**：音频缓存 / 离线固定 / 需完整文件的格式缓存三级；整源/整专辑/整歌单缓存、断网自愈、空间不足暂停、账号失效隔离。这是它最受好评的能力之一，但那是「本地曲库」场景。

**Overtone 现状**：只有图片缓存（`ImageCache` / `imageCacheLimitGB`），音频完全依赖网络。

**建议做法（若做）**：只缓存**直连（`static=true`）**源，按专辑/歌单「固定离线」；Application Support 下的缓存目录 + LRU + 设置上限；播放时优先本地；离线时明确标识不可播曲目。Jellyfin 可用 `/Items/{id}/Download` 或直连 stream URL。转码流/HLS 不缓存。成本 2–3 周，风险在存储管理、凭据失效、两套后端语义差异。

> 审计认为这是「NAS 用户最刚需」的一项（`overtone-baseline.md` §14）：如果 Overtone 的目标用户经常带 Mac 出门/在弱网环境听，这是最值得先做的 L 项，优先级可提到 P1；如果主场景是家里局域网，则 P2 合理。做之前必须先修「缓存上限未执行淘汰」这个死设置（见 §4.5）。

### 3.11 智能歌单规则（P2，M–L）

**Primuse 的做法**：14 个字段 × 7 个算子、AND/OR、规则组与排除、排序与上限、实时更新。

**Overtone 现状**：只有「按艺术家关键字自动收集」的智能列表（`MusicDataStore.smartMatchCache`），没有规则引擎。

**建议做法（若做）**：不要做通用规则引擎；先做 3–5 条预设规则（最近添加/最常播放/很久没听/无损/同流派），以「保存为智能列表」的形式落到 PlaylistStore。服务端筛选优先，飞牛侧降级为本地筛选。成本一周左右，但价值不如前几项直接，建议等统计/场景入口验证后再做。

### 3.12 设置搜索（P3，S）

设置项变多后有用（Primuse 74 条搜索文案，且理解「高保真模式下不可用」这类约束）。Overtone 目前 6 组设置还不算多，等超过 ~30 项再做。

### 3.13 顺手可做的小项（半天级）

这几项不属于「大功能」，但都是 Primuse 有、Overtone 差一点的地方，适合搭车做：

- **睡眠定时增加「播完这首」**：Primuse 有 `sleep_choice_end_of_track`；Overtone 只有 15/30/45/60 分钟 + 最后 5s 淡出。加一个「本曲结束」条件即可。
- **随机播放偏好**：Primuse 有 5 档（完全随机 / 常听歌优先 / 少听歌优先 / 常听歌手优先 / 少听歌手优先，按播放次数加权）。Overtone 的 `shuffle` 是均匀随机；本地 `playCount` 已经够用，实现是「加权抽样」十几行。
- **队列持久化**：Primuse 队列可跨会话；Overtone 队列纯内存、退出即丢（`overtone-baseline.md` §15）。落盘一个 JSON + 启动恢复即可。
- **补上展示了但未接线的快捷键**：⌘R 刷新、⌘↑/⌘↓ 上移/下移、⌫ 删除（`overtone-baseline.md` §10），顺手修掉。
- **播放失败/缓冲监听**：`AVPlayerItem.status`、`FailedToPlayToEndTime`、`timeControlStatus` 目前都没监听，直连失败是静默的；这既是体验问题，也是做预取/离线的前置条件。

---

## 4. 明确不建议照搬（臃肿的来源）

| 类别 | Primuse 的能力 | 为什么不加 |
|---|---|---|
| 音频工程 | 10 段 EQ + 按输出设备切换、独占输出 + 位深协商、DoP DSD、ReplayGain、压缩限幅、混响、空间音频、0.5–2× 变速、±6 半音 | 需要换播放内核：Overtone 走 AVPlayer 流式播放，EQ/独占/DSD 要接 AVAudioEngine + 自定义解码（Primuse 自带 FFmpeg + SFBAudioEngine），等于重写播放器与音频栈，与「轻客户端」定位冲突。**长线若真要做，单独立项，不要混进日常迭代。** |
| 曲库管理 | 扫描、刮削、标签写回、去重、歌单导入、目录管理、音乐源体检 | 服务器职责（Jellyfin/飞牛）。硬做会把 Overtone 拖进 Primuse 同样的性能债（它 CHANGELOG 一大半在修扫描/发热）。 |
| 多源聚合 | SMB/WebDAV/云盘/Subsonic/Navidrome/Emby/Plex 20+ 种 | 战略选项，不是功能小件。若扩后端，优先 OpenSubsonic/Navidrome（协议简单、用户多），按 `docs/architecture-multibackend.md` 加第三后端；不要为对齐 Primuse 而铺开。 |
| 品类扩张 | 播客（RSS/OPML）、有声书、网络电台、文字稿、卡拉 OK、AI 人声分离、串烧 | 每种都是一个独立产品面，维护成本极高，与「音乐播放器」定位无关。 |
| AI 平台 | 语义搜索、AI 歌单、翻译、简介补全、标签整理、24 家服务商 + 内置中转 + 额度/兑换码 | 需要服务端中转、成本模型、隐私合规；Overtone 没有这个商业形态。可保留「用户自备 key」的远期实验，不进入主线。 |
| 视觉大礼包 | 13 种全屏特效、播放页控件深度定制、动态封面、主题取色、桌面歌词岛、播放页版式一键切换 | 设计债与维护债。Overtone 已有玻璃/纸墨两套高完成度皮肤 + 4 个预置强调色，保持克制，最多做 1–2 个沉浸式视图；不建议做取色/主题商城/控件定制。 |
| 多设备生态 | iCloud 同步、家庭共享、WiFi 传输（App 内 HTTP 服务器）、缓存互传、Spotlight、WidgetKit 全家桶、Siri 全量、CarPlay、Apple TV、Watch | 平台不同/成本高。macOS 只挑「菜单栏 + 少量 Shortcuts」即可。 |

> 一句话：**Primuse 的「多」是它的护城河，也是它被你觉得臃肿的原因；Overtone 的机会是「你已有的 Jellyfin / 飞牛库，在 Mac 上最好的一次体验」。**

---

## 4.5 开工前值得先修的接线问题（来自本次审计）

这些不是 Primuse 功能，但会直接影响新功能的成败，建议排在第一个迭代之前（合计 2–4 天）：

1. **播放失败零监听**：没有 `AVPlayerItem.status` / `FailedToPlayToEndTime` / `timeControlStatus`，直连失败对用户是静默的（`overtone-baseline.md` §15-2）。这是预取、回退、离线的前置条件。
2. **`transcodeFallback` / `isHLS` 是死字段**：后端赋了值，播放器没消费 → 所谓的「直连失败自动回退转码」目前不存在（§15-3）。
3. **两项死设置**：语言（无本地化资源，界面全硬编码中文）、缓存上限（`ImageCache` 固定 400 张内存 LRU，上限未执行淘汰，清缓存只清内存）——做离线缓存前必须先修后者。
4. **快捷键速查有 3 项未接线**：⌘R 刷新、⌘↑/⌘↓ 上移/下移、⌫ 删除（§10）。
5. **飞牛「音量归一化」空转**：开关只被 Jellyfin 转码路径读取，飞牛 UI 未门控（§15-6）。
6. **能力声明两份不一致**：`MusicBackend.swift` 与 `FeiniuBackend.swift` 各有一份能力副本且已不同步（§15-4）——新增 `instantMix` 能力时顺手统一，否则门控会失效。

---

## 5. 建议的落地节奏

### 第 0 步（2–4 天）：先修 §4.5 的接线问题
尤其是播放失败监听与缓存淘汰——否则后面做的预取、离线都在沙地上。

### 第一版（1–2 周，低风险高感知）
1. 播放页音质/链路徽章（1 天）
2. Last.fm / ListenBrainz 记录（3–4 天）
3. 歌词偏移 + 沉浸式全屏歌词（3–4 天）
4. 统计页基础版（1 周，与 1–3 可并行）

### 第二版（1 个月）
5. 年度报告 + 分享图
6. 下一首预取 + 短过渡（先改善切轨空窗，不急着做真交叉）
7. InstantMix 自动续播
8. 场景化「开始听」入口

### 第三版（按需）
9. 菜单栏迷你播放器 / 桌面歌词
10. 歌词海报分享
11. 离线缓存（如果「带 Mac 出门」是真实需求）
12. 真·双播放器交叉淡化

### 不做
EQ/独占/DSD/空间音频、刮削/标签/去重、多源聚合、播客/有声书/电台、AI 平台、全屏特效大礼包、多设备生态。

---

## 6. 与现有架构的接入点备忘

- **后端协议**：`Sources/JellyfinMac/Backend/MusicBackend.swift`
  - 新增 `instantMix(seedID:limit:)`、可选筛选查询；能力位加在 `BackendCapabilities`（Jellyfin 实现，飞牛抛 `.unsupported` 走门控）。
- **播放器**：`Sources/JellyfinMac/Player/MusicPlayerModel.swift`
  - 统计/Scrobble 挂在 `startPlayback` / `handleTime` / `finishCurrentTrack`；预取与交叉淡化改 `loadCurrent`/`handleEnded`；音质徽章发布 `currentPlayMethod`。
- **本地数据**：`Sources/JellyfinMac/State/Local/LocalLibraryState.swift`
  - 事件流扩展写在现有 record 旁边，沿用 `AppState.profileKey` + `ContentIdentity` 的**跨后端**作用域（注意 `overtone-baseline.md` §8：代码按归一化用户名共享，架构文档写的「后端 + 账号」已落后，别照文档抄）。
- **设置**：`Sources/JellyfinMac/State/AppSettings.swift` + `Views/SettingsView.swift`
  - 新增「听歌记录」「歌词」「自动续播」分组；`crossfadeSeconds` 建议改名/拆语义。
- **新视图**：`Views/Music/StatsView.swift`、`YearlyRecapView.swift`、`ImmersiveLyricsView.swift`；菜单栏用 `MenuBarExtra` 挂在 `JellyfinApp.swift`。
- **设计**：所有新视图只用 `Theme` 令牌，同时适配玻璃/纸墨两套风格与五档断点。

---

*本报告的 Primuse 证据均可按 `primuse-feature-inventory.md` 中的 key 复现；Overtone 现状均对应当前工作区源码（含未提交重构）。*
