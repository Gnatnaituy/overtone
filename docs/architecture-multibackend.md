# 多后端架构（Jellyfin + 飞牛音乐）

> 状态：**已实施**（2026-10-28）。本文描述改造后的分层、契约与扩展方式。
> 背景与决策过程见 [接入飞牛云 NAS 工作量评估](fnos-integration-assessment.md)；
> 飞牛音乐的协议事实见 [`docs/research/fnos-music-api.md`](research/fnos-music-api.md)。

## 1. 一句话

播放器/界面层只认识**领域模型 `MediaItem`**；Jellyfin 与飞牛音乐各自是一个
`MusicBackend` 适配器，把各自的线上协议翻译成同一套领域模型；
**服务端没有的能力（播放进度、播放次数、专辑/艺人收藏）落在本地存储**，
字段位置不变，UI 不区分数据来源。

```
        ┌─────────────────────── Views / Components（只认 MediaItem） ───────────────────────┐
        │  HomeView · MusicLibraryView · MusicAlbumView · MusicArtistView · NowPlayingView …  │
        └───────────────▲──────────────────────────────────────────────▲─────────────────────┘
                        │ @Published                                   │ ArtworkRef → URL
        ┌───────────────┴───────────────┐              ┌───────────────┴───────────────┐
        │ MusicDataStore（唯一数据源）  │              │ ArtworkResolver / ImageCache  │
        │ · 分页循环加载 + 派生数据     │              │ · 缓存键 = ArtworkRef.cacheKey │
        │ · 本地兜底合并                │              └───────────────▲───────────────┘
        └───────▲───────────────▲───────┘                              │
                │               │                                      │
   ┌────────────┴─────┐  ┌──────┴────────────────┐          ┌──────────┴─────────┐
   │ MusicPlayerModel │  │ MusicBackend（协议）  │◄─────────┤ BackendRegistry    │
   │ · PlayableSource │  │ signIn/items/lyrics/  │          │ 活动后端 + 会话     │
   │ · ResourceLoader │  │ playableSource/report │          └──────────┬─────────┘
   └──────────────────┘  └──────▲────────┬───────┘                     │
                                │        │                    ┌────────┴─────────┐
                  ┌─────────────┴──┐  ┌──┴──────────────┐      │ SessionPersistence│
                  │ JellyfinBackend│  │ FeiniuBackend   │      │ 凭据按后端命名空间 │
                  │ PascalCase JSON│  │ authx + Cookie  │      └──────────────────┘
                  │ MediaBrowser 头│  │ /music/api/v1   │
                  └────────────────┘  └─────────────────┘

  LocalLibraryState（本地兜底）：播放进度 / 播放次数 / 最近播放 / 专辑艺人收藏
  —— 按「后端 + 账号」作用域落盘，飞牛没有的那些字段全靠它。
```

## 2. 分层与文件

| 层 | 文件 | 职责 |
|---|---|---|
| 领域模型 | [`Models/Domain/MediaModels.swift`](../Sources/JellyfinMac/Models/Domain/MediaModels.swift) | `MediaItem` / `MediaKind` / `ArtworkRef` / `MediaUserData` / `Paged` / `MusicLibrary` / `BackendUser` / `LyricLine` / `RemotePlaylist` |
| 后端协议 | [`Backend/MusicBackend.swift`](../Sources/JellyfinMac/Backend/MusicBackend.swift) | `MusicBackend` 协议 + `BackendCapabilities` + `PlayableSource` + `RequestAuthorization` + `PlaybackEvent`；不支持的能力用协议扩展默认抛 `.unsupported` |
| 注册与会话 | [`Backend/BackendRegistry.swift`](../Sources/JellyfinMac/Backend/BackendRegistry.swift) | 活动后端、后端工厂、`SessionPersistence`（UserDefaults 键 `backend.<kind>.*`、钥匙串账号 `<kind>\|<username>`、旧版单后端凭据迁移） |
| 传输层 | [`Networking/HTTPClient.swift`](../Sources/JellyfinMac/Networking/HTTPClient.swift) | URL 组装 / 逐请求凭据注入 / 独立 Cookie 存储 / JSON 解码策略 / 错误映射 |
| 封面 | [`Networking/ArtworkResolver.swift`](../Sources/JellyfinMac/Networking/ArtworkResolver.swift) | `ArtworkRef → URL`（由活动后端解析），UI 不拼 URL |
| Jellyfin 适配 | [`Backend/Jellyfin/`](../Sources/JellyfinMac/Backend/Jellyfin/) | wire DTO + 10 类端点 + `MediaBrowser` 授权头 + PascalCase 解码 |
| 飞牛适配 | [`Backend/Feiniu/`](../Sources/JellyfinMac/Backend/Feiniu/) | `authx` 签名、地址规范化、`{code,msg,data}` 信封、宽容 JSON、LRC 歌词、转码/HLS、27 个端点 |
| 状态层 | `State/AppState.swift`、`State/MusicDataStore.swift` | 会话编排（登录/恢复/切后端/登出）、曲库加载与派生数据、收藏、搜索、歌词 |
| 本地兜底 | [`State/Local/LocalLibraryState.swift`](../Sources/JellyfinMac/State/Local/LocalLibraryState.swift) | 进度/统计/收藏的本地持久化 + `merge` 合并规则 |
| 播放 | `Player/MusicPlayerModel.swift`、[`Player/MediaResourceLoader.swift`](../Sources/JellyfinMac/Player/MediaResourceLoader.swift) | `PlayableSource` → `AVURLAsset`；动态凭据走 `AVAssetResourceLoaderDelegate` 逐请求重签 |
| 自检 | [`Diagnostics/SelfTest.swift`](../Sources/JellyfinMac/Diagnostics/SelfTest.swift) | 51 项纯函数断言（authx / 地址 / 时长 / 歌词 / 合并规则），`./scripts/dev-test.sh` |

## 3. 关键约定

### 3.1 能力声明优先于「后端类型判断」

界面与状态层**不允许**写 `if backend == .feiniu`。需要能力差异时读
`BackendCapabilities`（`MusicDataStore.capabilities` / `AppState.capabilities`）：

| 能力 | Jellyfin | 飞牛音乐 | 关闭时的界面行为 |
|---|---|---|---|
| `playbackProgress` | ✅ | ❌ | 「进度上报间隔」置灰；续播改本地 |
| `playStats` | ✅ | ❌ | 「最常播放」用本地统计，不空态 |
| `albumArtistFavorites` | ✅ | ❌ | 专辑收藏按钮半透明 + tooltip「本地已记住」 |
| `transcode` | ✅ | ✅（Opus/HLS） | 「音质 / 直连优先 / 音量归一化」置灰 |
| `playlistReorder` | ✅ | ❌ | 排序只改本地，不推服务器 |
| `serverPaging` | ❌（也能接受） | ✅（强制） | 加载循环按 `Paged.hasMore` 翻页 |
| `search` | ✅ | ✅（三接口并发） | 关则退化为本地匹配 + 提示条 |

### 3.2 播放源不是 URL

`MusicBackend.playableSource(for:)` 返回 `PlayableSource`：

```swift
struct PlayableSource {
    let url: URL
    var authorization: RequestAuthorization?   // headers(url) + isDynamic
    var isHLS: Bool
    var playMethod: PlayMethod
    var unplayableReason: String?
    var transcodeFallback: URL?
}
```

- `isDynamic == false`：静态头（Cookie / `api_key`），一次塞进 `AVURLAssetHTTPHeaderFieldsKey`；
- `isDynamic == true`：飞牛 `authx` 含 nonce+timestamp，**每个 Range / HLS 分片都要重签** →
  `MediaResourceLoader` 把 scheme 改成 `https-authz`，用 `URLSession` 代取字节并按请求重算头；
  播放器必须持有 loader（`AVAsset` 只弱引用 delegate）：
  `let (asset, loader) = MediaResourceLoader.makeAssetAndLoader(for: source)`。

### 3.2.1 同一首歌只存一份（内容身份）

同一首歌曲可能同时存在于 Jellyfin 与飞牛音乐：条目 id 完全不同，但内容相同。
如果把本地状态按「后端 + 条目 id」存，同一首歌会被记两遍、封面也会下两遍。

`ContentIdentity`（`Models/Domain/ContentIdentity.swift`）用**元数据指纹**算出与后端无关的键：

| 种类 | 键 | 说明 |
|---|---|---|
| 曲目 | `t\|归一化标题\|归一化艺人\|时长秒` | 查表时做 **±2 秒** 探测（两端时长可能差几百毫秒） |
| 专辑 | `a\|归一化专辑名\|归一化专辑艺人` | |
| 艺人 | `r\|归一化艺人名` | |
| 视觉身份 | `v\|t\|标题\|艺人`（曲目，**不含时长**） | 封面缓存跨后端共用 |

归一化：NFKC 折叠（全角→半角）→ 小写 → 只留字母/数字/汉字（去空格、标点、零宽字符）。
**不剥** `(Live)` / `(Remastered)` 后缀 —— 那是不同录音，进度不能共享。

落地：

- 本地用户数据（播放进度 / 播放次数 / 最近播放 / 收藏）按 **账号档案（归一化用户名）+ 内容键** 存
  （`local-state/profile-<sha256>.json`），两个后端共用同一条记录；
  旧格式（`<backend>-<hash>.json`，键是条目 id）在首次看到该条目时按需迁移（`adoptLegacy`）。
- 封面缓存：`ArtworkRef` 带 `visualKey`，`ImageCache` 以 `content|<visualKey>|<width>` 为**别名键** ——
  两个后端要同一张图时只下载一次、只存一份；各后端原本的 `cacheKey` 仍保留（换后端可各自失效）。
- 播放列表**不**跨后端合并（那是各服务端自己的组织方式）。

### 3.3 本地兜底合并规则

`LocalLibraryState.merge(server:local:)`：

- **收藏**：服务端支持收藏则以服务端为准；不支持（飞牛专辑）则取本地（2 参版本取并集，防服务端恒 false 吃掉本地收藏）；
- **播放次数 / 最近播放 / 续播位置**：一律本地优先（飞牛没有这些数据）；
- 写盘：`Application Support/JellyfinMac/local-state/<backend>-<sha256(账号键)>.json`，
  debounce 合并；退出登录与退出应用时 `flushNow()` / `flushNowBlocking()` 兜底。

### 3.4 凭据作用域

- UserDefaults：`backend.<kind>.session`（JSON）、`backend.<kind>.serverURL|username|accessCode`、`backend.active`；
- 钥匙串：service 不变，account = `<kind>|<username>`（旧版直接用用户名的条目会在读取时兜底）；
- 旧版单后端键（`serverURL` / `token` / `username` / 明文 `password`）只在新命名空间为空时**一次性迁移**，迁移成功才删旧数据。

## 4. 怎么加第三个后端

1. 新建 `Backend/<Name>/<Name>Backend.swift`，实现 `MusicBackend`（只实现真有的能力）；
   不支持的用协议扩展默认实现，靠 `BackendCapabilities` 暴露给 UI。
2. 在 `AppState.init` 的工厂里加一行 `case .<name>: return <Name>Backend()`，
   在 `BackendKind` 里加枚举值（`displayName` / `serverPlaceholder`）。
3. 若协议形态特殊（需要签名/特殊头），实现 `RequestAuthorization` 并让
   `playableSource` 声明 `isDynamic`。
4. 若字段语义与领域模型有出入，在 `Backend/<Name>/<Name>Mapping.swift` 里做纯函数映射，
   并到 `SelfTest` 里加断言（这是唯一会被「服务端 401 / 收藏不生效」这类静默错误惩罚的地方）。

界面层**不需要改**：它只读 `MediaItem`、只读能力声明。

## 5. 验证方式

```bash
./scripts/dev-typecheck.sh   # 串行化编译（多人/多 agent 并行改代码时必需）
./scripts/dev-test.sh        # 51 项纯函数断言（不需要 Xcode，也不需要服务器）
./scripts/build-app.sh       # 打包 build/Overtone.app
```

**没有真机服务器时能验证的**：编译、纯函数断言、`--selftest` 退出码。
**必须真机验证的**（飞牛侧，按风险排序）：

1. `authx` 是否强制 + Range 能否 206 —— 决定播放层走静态头还是逐请求签名；
2. 转码产物 Opus-HLS 能否被 AVPlayer 播（决定 APE/DSD/WMA 用户是否有解）；
3. HLS 分片请求是否真的回到 `MediaResourceLoader`（不回到则需 loopback 代理兜底）；
4. `duration` 单位（秒/毫秒）与 `trackGUID` / `trackGuid` 大小写（收藏静默失效风险）；
5. 自签 HTTPS 证书下 AVPlayer 的信任表现。

## 6. FN Connect（远程访问）

给「不在家也想听」准备。`https://fnos.net/{fnId}/music` 只是引导页，**不代理音乐 API**，
所以 `FeiniuAddress.resolve(_:)` 会在三种输入里自动选路：

| 输入 | 行为 |
|---|---|
| `ravooo`（FN ID） | 定位 → 探测 → 取第一个可达基址 |
| `https://fnos.net/ravooo/music` | 取出 FN ID 后同上 |
| `192.168.1.10:5666` | 直接规范化，不走 FN Connect |

实现要点：

- **定位**：`POST https://{host}/api/v1/fn/con`，body `{"fnId":"..."}`。`5ddd.com` 只要 `authx`；
  `fnos.net` 另需 `fn-sign`（`SHA256("trim_connect`{fnId}`{timestamp}`anna")`，与 authx 同一时间戳）。
  **定位 key 与音乐 key 不同**（`zIGtkc3d…` vs `6D5602D4-…`），混用必 401。
- **候选顺序**：内网 IPv4/IPv6 (http) → 内网 https → 公网 IPv6 → 公网 IPv4 → DDNS → relay；
  内网 2s / 公网 5s / relay 10s 超时，按批并发（远端场景不会白等内网超时）。
- **relay**：直接带 `Cookie: mode=relay` 请求（实测无需先握手拿 cookie）；域名必须在
  `*.fnos.net` / `*.5ddd.com` 白名单内（定位结果不可信，防止被当任意 URL 请求）。
- **凭据贯穿**：中继 Cookie 存进 `BackendSession.extraCookie`，API、封面、播放三条链路共用
  （`authorizedImageRequest(for:)` + `RequestAuthorization`）。
- **自签证书**：只对**私网主机**放行（`SelfSignedHostDelegate.isPrivateHost`），relay 与公网仍走系统校验。
- **失效重定位**：会话里存 `fnID`，`validateSession` 失败时自动重新定位一次再校验（中继地址会变）。

验证：`swift run JellyfinMac --fn-resolve <FN ID>` 会打印定位结果、逐个候选探测、最终基址。
本机（2026-10-29，FN ID `ravooo`）实测：内网 IPv4、公网 IPv6、relay 三路可达，公网 IPv4 未做端口映射。

## 7. 现状与已知缺口

已完成（编译与自检绿、`.app` 可打包）：领域模型、双后端、多后端会话与凭据命名空间、
播放链路（含动态签名资源加载器）、本地兜底、登录/设置的后端选择与能力门控、自检。

**未做（明确留白）**：

- ~~飞牛 FN Connect~~ —— **已实现**（`Backend/Feiniu/FeiniuFNConnect.swift`）：FN ID → 定位（`5ddd.com` / `fnos.net`，两种签名）→ 候选排序与探测 → 中继 `mode=relay`；登录页直接填 FN ID 即可。详见 §7。
- 飞牛**转码预热/心跳与 quit**（播放器层未编排，HLS 失败即回退提示不可播）；
- 飞牛 **CUE 整轨**偏移、`accessStatus != 0` 曲目的标灰（目前直接过滤掉）；
- 多服务器**同时在线**（`BackendRegistry` 一次只有一个活动后端；切换即重登）；
- 曲库**真分页懒加载**（当前首屏加载前 5,000 首后提示截断）；
- 播放列表**拖拽排序**（沿用上移/下移 + 全量推送）。
