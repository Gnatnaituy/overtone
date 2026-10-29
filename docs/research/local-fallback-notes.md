# 本地兜底基础设施：`LocalLibraryState` + `MediaResourceLoader`

> **目的**：飞牛音乐（fnOS）没有播放次数 / 最近播放 / 续播位置，且媒体请求要逐请求签名（authx）。
> 这两块能力由本仓的两个新文件兜住，本文记录**公开 API、合并规则取舍、状态层接线点、不支持的场景**。
>
> **边界**：本文对应 task-5；只新增两个源码文件 + 本文档，未改任何现有文件。
> 证据等级：**V** = 本机编译/单测可复现，**S** = 源码直读，**C** = 未实测（见 TODO(C)）。
> 相关文档：`docs/research/fnos-music-api.md`（协议事实档）、`docs/research/overtone-backend-coupling.md`（耦合评估）。

---

## 0. 结论先行

| 文件 | 职责 | 关键约束 |
|---|---|---|
| `Sources/JellyfinMac/State/Local/LocalLibraryState.swift` | 按「后端 + 账号」持久化服务端没有的用户数据（收藏 / 播放次数 / 最近播放 / 续播位置） | `@MainActor` 门面；JSON 落 `Application Support/JellyfinMac/local-state/`；debounce 300ms + 后台编码；坏文件容错为空表 |
| `Sources/JellyfinMac/Player/MediaResourceLoader.swift` | `AVAssetResourceLoaderDelegate`：给 AVPlayer 的每个媒体请求**现算**凭据头 | 动态头 → 自定义 scheme + delegate；固定头 → `AVURLAssetHTTPHeaderFieldsKey`；无头 → 裸 `AVURLAsset`；delegate 不碰 `@MainActor` |

编译状态：`./scripts/dev-typecheck.sh` → **Build complete!**（全仓，2026-10-28）。两个文件无 warning。
验证记录见 §5。

---

## 1. `LocalLibraryState`

### 1.1 公开 API 清单

```swift
@MainActor final class LocalLibraryState {
    static let shared: LocalLibraryState

    // ——— 纯函数（不读单例 / 不碰磁盘，可单测）———
    static func merge(server: MediaUserData, local: MediaUserData?, serverSupportsFavorites: Bool) -> MediaUserData
    static func merge(server: MediaUserData, local: MediaUserData?) -> MediaUserData

    // ——— 读 ———
    func overrides(backend: BackendKind, accountKey: String) -> [String: MediaUserData]
    func userData(itemID: String, backend: BackendKind, accountKey: String) -> MediaUserData?
    func favoriteIDs(backend: BackendKind, accountKey: String) -> Set<String>
    func resumableIDs(backend: BackendKind, accountKey: String, limit: Int) -> [String]

    // ——— 写 ———
    func recordProgress(itemID: String, backend: BackendKind, accountKey: String,
                        position: Double, duration: Double, playedToEnd: Bool)
    func recordPlayStart(itemID: String, backend: BackendKind, accountKey: String)
    func setFavorite(itemID: String, backend: BackendKind, accountKey: String, favorite: Bool)
    func clear(backend: BackendKind, accountKey: String)

    // ——— 落盘时机（App 退出 / 切换账号）———
    func flushNow() async          // 在异步上下文里等写盘完成
    func flushNowBlocking()        // 同步版，给 applicationWillTerminate（不能 await）

    private(set) var revision: Int // 每次变更自增，供调用方做 O(1) 变更检测（同 PlaylistStore.revision）
}
```

配套的磁盘记录类型（`internal`，便于将来独立单测/排查）：

```swift
struct LocalLibraryRecord: Codable, Hashable, Sendable {
    var isFavorite: Bool
    var playCount: Int
    var lastPlayed: Date?
    var resumePosition: Double   // 秒
    var duration: Double         // 秒；0 = 未知（用于「是否听完」判定）
    var isPlayed: Bool
    var updatedAt: Date?
    var userData: MediaUserData  // 换算成领域模型
    var isEmpty: Bool            // 全空记录不落盘
}
```

### 1.2 磁盘布局与格式（V）

```
~/Library/Application Support/JellyfinMac/local-state/
    feiniu-<sha256(accountKey) 前 16 位>.json
    jellyfin-<...>.json
```

- `accountKey` 由调用方传入，当前是 `AppState.accountKey` = `"<serverURL.absoluteString>|<username>"`。
- **文件名只放哈希**：文件名会出现在崩溃日志、截图、备份工具里，不该把「服务器地址 + 用户名」明文写进路径。
- 文件内容带 `backend` / `scopeHash` / `version`，便于人工确认归属与将来迁移：

```json
{
  "backend": "feiniu",
  "scopeHash": "e0700d4cb21f0c8e",
  "version": 1,
  "items": {
    "<trackGUID>": {
      "isFavorite": false,
      "playCount": 3,
      "lastPlayed": "2026-10-28T12:00:00Z",
      "resumePosition": 42.5,
      "duration": 240,
      "isPlayed": true,
      "updatedAt": "2026-10-28T12:00:00Z"
    }
  }
}
```

- 例：`accountKey = "https://nas.example.com:5666/music|ravooo"` → `feiniu-e0700d4cb21f0c8e.json`
  （`e0700d4cb21f0c8e` 已用 `shasum -a 256` 交叉验证，见 §5）。
- 编码：`JSONEncoder`（`.iso8601` 日期、`.sortedKeys`、无缩进）；写入 `.atomic`（临时文件 + rename，不会出现半截文件）。
- SHA-256 是**文件内自带实现**（约 80 行，FIPS 180-4，已用官方测试向量校验），理由：本文件约定只 `import Foundation`，
  不为一个文件名散列引入 CryptoKit；且它不用于任何安全用途。

### 1.3 写入策略：debounce + 后台编码 + 不丢最后一次（V）

```
变更（recordProgress / recordPlayStart / setFavorite）
   └─ MainActor：改内存表 → revision+1 → dirtyScopes.insert(scope)
        └─ 若无 debounce 任务：起一个 300ms 的 Task
             └─ 醒来 → drainDirtyScopes()
                  while !dirtyScopes.isEmpty {          ← 关键
                      取出全部脏作用域 → 逐个 await 写盘
                  }
```

- **为什么 debounce 300ms**：播放器每 0.5s 汇报一次进度；逐次写盘 = 持续的磁盘写放大（`PlaylistStore` 已经踩过同类问题）。
- **为什么不会丢最后一次写**：写盘 `await` 期间（主 actor 让出），新变更会重新进 `dirtyScopes`；
  `while` 循环在每轮结束后再看一次集合 → 一定会再写一遍。这是照 `PlaylistStore` 的 `isWriting/pendingWrite`
  思路，但把「补一次」换成了「循环到干净」，语义更强。
- **后台编码**：`LocalLibraryPersistence.write` 是文件级 `nonisolated async func`，被 `await` 时切到协作线程池
  （SE-0338），JSON 编码与文件 IO 都不在主线程。`JSONEncoder` 每次新建（避免两个 drain 交错时的共享可变状态）。
- **`clear` 与在途写盘的竞态**：`clear` 删内存表 + 删文件 + `clearGenerations[scope] += 1`。
  在途写盘完成后发现 generation 变了 → 若内存里又有新数据就重写，否则再删一次文件 → 不会「clear 之后被旧快照写回来」。
- **`flushNow()` / `flushNowBlocking()`**：debounce 意味着窗口内进程退出会丢那 300ms。
  `flushNow()` 在异步上下文用；`flushNowBlocking()` 在 `applicationWillTerminate`（不能 `await`）里同步写盘，
  并把 generation +1 让在途异步写收敛到最新内存态。

### 1.4 读：懒加载 + 损坏容错（V）

- 每个作用域第一次被访问时才读盘（`ensureLoaded`），之后全部走内存；一次同步小文件读（几十 KB 以内）。
- 文件不存在 → 空表（首次使用，正常，不打日志）。
- 解码失败 / 字段缺失 → **空表 + 一条日志**，不崩溃、不删文件（保留手工捞回的可能）。
  `LocalLibraryRecord` 手写了 `init(from:)`，`decodeIfPresent` 逐字段兜底；`LocalLibraryFile` 亦然。
- 版本号高于当前 → 打日志后仍按已知字段读取（向前兼容，不锁死）。

### 1.5 `merge` 规则与取舍（V，纯函数）

#### 精确版：`merge(server:local:serverSupportsFavorites:)`

| 字段 | 规则 | 理由 |
|---|---|---|
| `isFavorite` | `serverSupportsFavorites == true` → **服务端**；否则 → **本地**（本地无记录时退回服务端） | 支持收藏时服务端是权威（包括「别的设备上取消了」）；飞牛的专辑/艺人只在本地点过，服务端恒 `false` |
| `playCount` | 本地有记录 → **本地** | 飞牛没有播放统计 |
| `lastPlayed` | 本地有记录 → **本地** | 同上 |
| `resumePosition` | 本地有记录 → **本地** | 飞牛没有播放进度 |
| `isPlayed` | 本地有记录 → **本地** | 与 `playCount` 同源，避免「本地播过、服务端说没播」的割裂 |

**契约**：调用方只在「后端缺这项能力」时把本地记录喂进来（当前 `MusicDataStore.applyLocalOverrides` 用
`capabilities.playStats/playbackProgress` 门控，Jellyfin 直接跳过）。若对 Jellyfin 也喂本地记录，
会把服务端更准确的 `playCount` 覆盖成 1 —— 注释里已写明。

#### 兼容版：`merge(server:local:)`（当前状态层调用点用的这个）

现有调用点 `MusicDataStore.applyLocalOverrides` **只传两个参数**，拿不到「该 kind 是否支持收藏」：

- 飞牛**曲目**收藏在服务端（`trackFavorites == true`，本地通常没有 `isFavorite` 记录）；
- 飞牛**专辑/艺人**收藏只在本地（`albumArtistFavorites == false`，服务端恒 `false`）。

若统一「服务端优先」会吃掉专辑收藏，统一「本地优先」又会把曲目服务端的 `true` 冲掉。
所以这个重载取**并集**：`isFavorite = server.isFavorite || local?.isFavorite`。

- 代价：某条目「只存在本地」的收藏，在服务端开始支持收藏后于别处被取消时，陈旧的本地 `true` 会继续生效。
- 出路：① 调用方改用精确重载（传 `capabilities` 对应的布尔值）——**Lead 已确认采纳该策略，未来切精确版**；
  ② 退出登录 / 换账号时 `clear` 掉整个作用域。

#### 「继续播放」阈值（`resumableIDs`）

`resumePosition > 5` 且 `resumePosition < duration - 10`，按 `lastPlayed` 倒序（同刻按 id 升序保证稳定）：

- 前 5 秒不算听过（用户很可能只是滑过去）；
- 最后 10 秒不算续播（继续播没意义，播放器会从头）；
- `duration <= 0` 的记录不参与（无法判断是否听完）。

### 1.6 已知限制（本文件范围）

| 限制 | 影响 | 备注 |
|---|---|---|
| 作用域 = `serverURL|username` | 换服务器地址（IP→域名、加 `/music`）会视为新账号，旧数据不迁移 | 需要迁移的话，按 `username` 扫描旧文件并 rename（TODO，尚未实现） |
| 作用域不含 `userID` | 同服务器同名用户被重建（新 userID）会共用一份兜底数据 | 可接受；严格做法是把 userID 拼进 `accountKey` |
| debounce 300ms | 窗口内 `kill -9` 丢最后一笔 | `flushNowBlocking()` 缓解；正常退出不丢 |
| 单向清理缺失 | 服务端删掉的条目，本地记录会一直留着（几 KB 量级） | TODO：曲库加载完成后按 id 差集清理 |
| 无跨进程锁 | 两个 App 实例同时写同一文件会互相覆盖（原子写不损坏文件） | 单实例应用，实际不会遇到 |
| `recordProgress` 只 clamp 到 `[0, duration]` | 播放器给出离谱位置时会写入边界值而非丢弃 | 由调用方（`MusicDataStore.noteProgress`）负责节流 |
| `lastPlayed` ISO8601 秒精度 | 同一秒多次播放的排序靠 `updatedAt` + id 兜底 | 可接受 |

---

## 2. `MediaResourceLoader`

### 2.1 公开 API 清单

```swift
final class MediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let dynamicSchemeSuffix = "-authz"

    init(authorization: RequestAuthorization, rewritesHLSPlaylists: Bool = true)

    /// 成对返回：asset + 「动态签名场景必须被播放器强引用持有」的 loader（其余场景 nil）
    static func makeAssetAndLoader(for source: PlayableSource) -> (AVURLAsset, MediaResourceLoader?)

    /// 便捷包装（内部丢弃 loader）；无头/固定头场景可用，动态头请用成对 API
    static func makeAsset(for source: PlayableSource) -> AVURLAsset

    /// https/http → https-authz/http-authz（只换 scheme 前缀，其余字节不动）
    static func customSchemeURL(for url: URL) -> URL?

    // AVAssetResourceLoaderDelegate
    func resourceLoader(_:shouldWaitForLoadingOfRequestedResource:) -> Bool
    func resourceLoader(_:didCancel:)
}
```

**Lead 确认项（已核对代码）**：`makeAssetAndLoader` 在返回前已完成
`asset.resourceLoader.setDelegate(loader, queue: loader.workQueue)`（`MediaResourceLoader.swift:74`，
queue 是串行的 `DispatchQueue`）。播放器先拿到 `(asset, loader)`、随后才 `AVPlayerItem(asset:)` +
`replaceCurrentItem` —— 首个资源请求一定发生在 delegate 安装之后（V）。
另外 `RetainingURLAsset` 还会强持一份 loader，作为「只拿 asset、不拿 loader」的误用兜底
（`AVAssetResourceLoader.delegate` 是 weak）。

### 2.2 装配决策树（V）

| 输入 | 产物 | 说明 |
|---|---|---|
| `authorization == nil` | `AVURLAsset(url:)`，loader = `nil` | 无凭据注入需求 |
| `authorization.isDynamic == false` | `AVURLAsset(url:options: [AVURLAssetHTTPHeaderFieldsKey: headers(source.url)])`，loader = `nil` | 固定头一次性交给 AVFoundation；**不再进 delegate** |
| `authorization.isDynamic == true` | 自定义 scheme URL + `RetainingURLAsset` + loader | `<scheme>-authz`：AVFoundation 不认识 → 每请求回调 delegate 现算头 |
| `source.url` 非 http(s) | 裸 `AVURLAsset(url:)` | `file:` 等没有「注入 HTTP 头」的意义 |
| `isDynamic == true` 但 `customSchemeURL` 失败 | 裸 `AVURLAsset(url:)` | 防御性分支，实际不会触发 |

> `AVURLAssetHTTPHeaderFieldsKey` 在本机 SDK 里**没有导出到 Swift**（只剩 C 符号，已验证：直接用常量会
> `cannot find in scope`），所以用字符串字面量。这是固定头场景唯一入口；若未来 AVFoundation 移除该 key，
> 退路是「一律走动态 scheme + loader」。

### 2.3 请求生命周期（V）

```
AVFoundation 发起请求（custom scheme）
  └─ shouldWaitForLoadingOfRequestedResource → return true，workQueue.async 处理
       └─ begin(loadingRequest)
            ├─ 真实 URL = 去掉 "-authz"（逐字节还原）
            ├─ headers = authorization.headers(realURL)     ← 每次现算（authx 时间戳）
            ├─ Range   = 请求头里的 Range，否则由 dataRequest.requestedOffset/Length 拼
            ├─ 只有 contentInformationRequest → 发 "bytes=0-1" 只取响应头（不下载整首）
            └─ URLSession.dataTask → resume
  └─ didReceive response：2xx → 填 contentInformation（contentType / contentLength / Range 支持）
                          + 透传 response（状态码 / Content-Range / Content-Length / Accept-Ranges）
     非 2xx → finishLoading(with: NSError(code=状态码))，completionHandler(.cancel)
  └─ didReceive data：按 [requestedOffset, requestedOffset+length) 与响应体在资源里的区间求交集后 respond
                      收到够 requestedLength 就提前 finish + cancel（避免为一次 seek 下完整首）
  └─ didComplete：正常 → finishLoading()；网络错误 → finishLoading(with:)
  └─ didCancel：cancel 对应 task、摘表（不再 finish —— AVFoundation 已取消）
```

- **200 忽略 Range 的服务端**：`bodyStart = 0`，按 `requestedOffset` 在本地裁剪首个字节块，仍能正确交付；
  `isByteRangeAccessSupported` 取决于 `Accept-Ranges` / 206。
- **`Content-Range` 总长**用于 `contentInformation.contentLength`（206 时 `Content-Length` 只是分片长度，不能当总长）。
- **`allowedContentTypes`**：非空时必须设为其中一个，否则 `finishLoading` 直接抛异常（Apple 文档明确）。
- **持有 loading request**：`pending` 表强引用到 finish 为止（文档要求的生命周期）。
- **重复/并发请求**：同一 delegate 会同时收到多个 loading request（长曲 + seek），每个各自一条 task，互不干扰。

### 2.4 HLS（m3u8 + 分片）（C，见 §2.6）

- 动态头 + HLS：m3u8 同样走自定义 scheme → 被 delegate 拦下。
- **播放列表整体改写**：把 `#EXT-X-STREAM-INF` 后的 URI 行、`#EXT-X-KEY` / `#EXT-X-MAP` / `#EXT-X-MEDIA` 等
  属性里的 `URI="..."` 全部换成 `https-authz://`；相对 URI 先按播放列表真实 URL 解析成绝对 URL。
  这样分片请求才会重新回到 loader，用**分片自己的 path** 重算 authx（飞牛签名含 path）。
- 改写后 `contentInformation.contentLength` 与响应头 `Content-Length` 按改写后的字节数更新，并去掉 `Content-Range`。
- 已有本地功能测试覆盖：相对/绝对分片、`#EXT-X-KEY`、`#EXT-X-MEDIA`、query 里的 `%2F` 原样保留（见 §5）。
- `rewritesHLSPlaylists: false` 是排查开关：关掉后只签名 m3u8 本身，分片按播放列表里的原 URL 直连
  （适用于「分片 URL 自带 token、不需要 authx」的服务端）。

### 2.5 线程与生命周期（V）

- 所有在途状态（`pending` / `pendingByTask` / `cancelledBeforeStart`）与网络回调都收敛到**一条串行 `workQueue`**；
  delegate 方法本身只做 `workQueue.async` 然后立刻返回，**绝不在 delegate 队列上等网络**。
- `RequestAuthorization.headers` 是 `@Sendable`，在 `workQueue` 上调用，**不触碰任何 `@MainActor` 状态**。
- 一个 loader 一个 `URLSession`（ephemeral、无 URL 缓存、不落 cookie）：
  连接复用、凭据只从 headers 来，避免多账号串味。
- `URLSession` 强引用 delegate → 用 `SessionProxy`（只 weak 回指 loader）断开循环；
  loader `deinit` 里 `invalidateAndCancel()` 释放连接池。
- 返回的 loader 由播放器持有（`MusicPlayerModel.resourceLoader`）；asset 内部再强持一份兜底。

### 2.6 不支持 / 未验证的场景

| 场景 | 现状 | 处理 |
|---|---|---|
| **HLS 分片是否真的回到 delegate** | **C（未实测）**：AVFoundation 的 HLS 内部加载路径可能对播放列表内 URI 不完全走 `AVAssetResourceLoader`；若不走，改写后的 `-authz` 分片会取不到数据 | **TODO(C)**：真机抓一次「分片请求是否进 `shouldWaitForLoadingOfRequestedResource`」。若不进 → 回退方案是本地 loopback（127.0.0.1）HTTP 代理，把分片 URL 改写成 localhost（不在本任务范围） |
| **加密 HLS**（`EXT-X-KEY` AES-128 / SAMPLE-AES / FairPlay） | **不支持** | key 请求的内容类型 / 密钥交付协议未实现（FairPlay 需要 `AVContentKeySession` + `skd://` 内容类型）；若飞牛 HLS 加密则播不了。**TODO(C)** |
| **多段 Range（`multipart/byteranges`）** | **不支持** | 我们只发单段 `Range`；若中间代理返回 multipart，解析会当成单段 body → 数据错位。正常直连不会触发 |
| **跨主机重定向（302 → CDN）** | 只跟随，不重签 | `URLSession` 自动跟随，但不会对重定向目标重新调用 `authorization.headers` → 签名 URL 跳 CDN 可能 401。**TODO(C)**：在 `willPerformHTTPRedirection` 里重算头（需要把签名策略暴露成「按 URL 重签」） |
| **416 / 4xx / 5xx** | 直接失败 | `finishLoading(with: NSError(code=状态码))`；不做回退（播放器可换 transcode 源） |
| **超长单请求** | 1 小时上限 | `timeoutIntervalForResource = 3600`，超长有声书可能被截断（常量可调） |
| **磁盘缓存 / 离线** | 无 | 每次 seek 重新请求；不做签名 URL 的本地缓存（避免失效与目录膨胀） |
| **凭据刷新 / token 过期** | 依赖 `authorization.headers` 闭包 | loader 只负责「每个请求问一次头」；token 续期的逻辑在后端（`FeiniuBackend`） |
| **后台 MPRemote / 车机等系统级播放** | 不影响 | 系统仍通过我们的 asset 播放，请求照旧走 delegate |

> 本节所有 `TODO(C)` 在代码里都有对应注释锚点（搜 `TODO(C)`）。Lead 要求「不静默放弃」——这里逐条写明，
> 其中 HLS 分片与加密 HLS 是**真机必测项**，未验证前不要把「飞牛转码 HLS 可播」当已实现能力对外承诺。

---

## 2.7 直连播放（FLAC / 长曲 seek）的具体行为（S + 部分 C）

装配：直连源是**一个带 Range 能力的 URL**，没有 HLS 改写。AVFoundation 的访问序列与我们的响应：

1. **内容信息探测**：`contentInformationRequest` 有、`dataRequest` 为 nil → 我们发 `Range: bytes=0-1`，
   只读响应头（媒体类型 / 总长 / 是否支持 Range），拿到就 `finishLoading` 并 cancel，**不会为探测下载整首**。
2. **若干 Range 请求**：AVFoundation 会读文件头、文件尾（FLAC/MP4 的 metadata 常在尾部）、以及 seek 后从新位置继续。
   每个请求都走一次 `begin()` → **重新调用 `authorization.headers(realURL)`**（authx 时间戳是新的），
   转发 `Range`，206 时把 `Content-Range` / `Content-Length` / `Accept-Ranges` 与状态码透传。
3. **及时收工**：一旦 `delivered >= requestedLength` 就 `finishLoading` + cancel task —— 一次 seek 不会把整首下完。
4. **内存**：收到一块 `Data` 就 `respond`，不缓存整首（内存占用 ≈ 单块大小，几十 KB 级）。

已知行为差异（**真机要验**）：

- 服务端支持 206（正常情况）：FLAC 直接播、seek 快，尾部 metadata 读取正常。
- 服务端忽略 `Range` 回 200：我们在本地按 `requestedOffset` 裁剪，仍能交付正确字节；
  但会把 `isByteRangeAccessSupported = false` 告诉 AVFoundation —— 它可能因此退化为顺序下载，
  **seek 变慢或不可用**（尤其 FLAC 尾部 metadata 读取）。
- `416`（请求起点 ≥ 文件长度）：直接报错，不做回退。
- 超长单文件：`timeoutIntervalForResource = 3600`，超过 1 小时的连续请求会被截断（常量可调）。

## 2.8 真机验证清单（Top 3 风险，按「踩坑代价」排序）

| # | 风险 | 为什么贵 | 怎么验（一条命令/一个断点即可） |
|---|---|---|---|
| 1 | **HLS 分片是否真的回到 delegate**（C，最贵） | 若 AVFoundation 对播放列表内 URI 不走 resource loader，改写后的 `-authz` 分片取不到数据 → 飞牛转码 HLS 全不可播，需要 loopback 代理重做 | 在 `begin()` 里打印 `requestedURL`（或断点），播一首转码曲：应看到 1 次 `preset.m3u8` + N 次 `seg*.ts`；也可以看飞牛服务端访问日志里分片请求的 authx `nonce/timestamp` 是否**每次不同**（逐片重签的证据） |
| 2 | **服务端是否真支持 Range（206 + `Accept-Ranges: bytes`）** | 忽略 Range 时我们把 `isByteRangeAccessSupported` 设为 false，seek 退化；FLAC 尾部 metadata 读取可能变成整首下载 | `curl -s -D- -o /dev/null -H 'Range: bytes=0-1' '<stream-url>'`：看 `206` + `Content-Range: bytes 0-1/<total>` |
| 3 | **固定头路径与凭据时效** | `AVURLAssetHTTPHeaderFieldsKey` 是 Apple 未导出到 Swift 的字符串常量（本机 SDK 已验证：直接用常量 `cannot find in scope`）；且固定头只在 asset 创建时取一次，长曲播放 / 长时间暂停后 cookie 过期**不会刷新** | 飞牛 authx 关闭（`authxEnabled=false`）时播一首长曲并暂停 > token 有效期；若 401 则固定头路径不可用于长会话（authx 开启时逐请求签名，没有这个问题） |

> 补充两条次要风险：① 跨主机 302（签名 URL 跳 CDN）不会重签（§2.6，`// TODO(C)`）；
> ② `contentInformationRequest.allowedContentTypes` 非空时 `contentType` 必须是其一，否则 `finishLoading`
> 会抛异常 —— 代码已按响应 MIME / `allowedContentTypes` 处理，但换后端/代理时值得回归一次。

---

## 3. 状态层接线表（哪个方法调哪个 API）

### 已接（当前代码，S）

| 状态层位置 | 调用 | 语义 |
|---|---|---|
| `MusicPlayerModel.startPlayback(source:track:)` | `MediaResourceLoader.makeAssetAndLoader(for: source)` → `resourceLoader = loader` → `AVPlayerItem(asset:)` | 播放装配；动态签名场景 loader 必须被播放器持有（已确认生效） |
| `MusicDataStore.toggleFavorite(_:)` | `LocalLibraryState.shared.setFavorite(itemID:backend:accountKey:favorite:)` | 只在该 kind **不支持服务端收藏**时写本地（飞牛专辑/艺人） |
| `MusicDataStore.applyLocalOverrides(_:)` | `overrides(backend:accountKey:)` + `merge(server:local:)` | 加载/详情/搜索的条目合并；`capabilities.playStats/playbackProgress` 门控（Jellyfin 跳过） |
| `MusicDataStore.notePlaybackStarted(_:)` | `recordPlayStart(itemID:backend:accountKey:)` | 播放次数 +1、`lastPlayed = now`、`isPlayed = true` |
| `MusicDataStore.noteProgress(_:position:)` | `recordProgress(..., playedToEnd: false)` | 续播位置（`duration <= 0` 时忽略） |
| `MusicDataStore.notePlaybackFinished(_:)` | `recordProgress(..., position: 0, playedToEnd: true)` | 清进度、标记已播完（从「继续播放」移除） |

### 待接（建议由 Lead 在收尾时补，均不改本文件）

| 建议接线点 | 调用 | 目的 |
|---|---|---|
| `AppDelegate.applicationWillTerminate`（`JellyfinApp.swift:53` 的 `AppDelegate`） | `LocalLibraryState.shared.flushNowBlocking()` | 保证退出前把 debounce 中的最后一笔写盘（无需 await） |
| 退出登录 / 切换账号流程（`AppState.signOut` 附近） | 先 `await LocalLibraryState.shared.flushNow()`，必要时 `clear(backend:accountKey:)` | 换账号不串数据；清空时真正删文件 |
| `applyLocalOverrides`（可选升级） | 改用 `merge(server:local:serverSupportsFavorites:)`，按 kind 传 `capabilities.trackFavorites` / `albumArtistFavorites` | 替代并集启发式，消除陈旧本地收藏的影响（Lead 已确认等飞牛收藏事实明确后切换） |
| 「继续播放」发现页（`MusicDataStore.continueEntries` 目前只从已加载 tracks 派生） | `resumableIDs(backend:accountKey:limit:)` | 跨会话 / 未加载进内存的续播条目也能出现（需要按 id 回查后端条目或已加载缓存） |
| 「我的收藏」页（飞牛专辑/艺人收藏） | `favoriteIDs(backend:accountKey:)` | 服务端不支持收藏的后端用本地集合过滤 |
| 播放前取续播位置（`MusicPlayerModel` 目前用 `track.userData.resumePosition`） | `userData(itemID:backend:accountKey:)` | 条目不在已合并列表里时也能拿到本地进度（可选） |
| 本地数据变更后的 UI 刷新 | 读 `LocalLibraryState.revision` | O(1) 变更检测；当前没有订阅者（状态层自己发起写、自己刷新，暂不需要） |

---

## 4. 设计取舍（为什么这样做）

1. **为什么不用 `PlaylistStore` 的「首次立即写 + pendingWrite」而是 debounce？**
   播放进度是高频写（每 0.5s），「首次立即写」会让每次起播都立刻落盘；debounce 把连续进度合并成一笔。
   同时保留「写盘期间的变更不丢」的语义（drain 循环），比 `isWriting/pendingWrite` 更强。
2. **为什么把 `@MainActor` 门面和后台写拆开？**
   数据是 UI 派生数据（收藏/续播直接决定界面），放主 actor 读写最简单且无锁；编码/IO 是纯函数式快照，天然可移出主线程。
3. **为什么文件按账号分而不是一个大 JSON？**
   换账号/删账号只需删一个文件；单账号写入只影响自己的文件；坏文件只损失一个账号的兜底数据。
4. **为什么 ResourceLoader 不直接改 `AVPlayerItem` / 不预取？**
   播放器换曲流程是 `makeAssetAndLoader` → `replaceCurrentItem` → `play()`；loader 只在 AVFoundation 真正要数据时发请求，
   起播前零网络活动（Lead 明确要求「不要提前预取」）。
5. **为什么自定义 scheme 是「真 scheme + 后缀」**？
   保留 `https`/`http` 前缀便于日志排查；后缀让 AVFoundation 认不出 → 必回 delegate。
   同时 URL 改写**只替换 scheme 前缀**（不走 `URLComponents` 往返），避免百分号编码归一化破坏签名 query。

---

## 5. 验证记录（V）

1. **全仓编译**：`cd /Users/ravooo/Code/Github/overtone && ./scripts/dev-typecheck.sh` →
   `Build complete!`（2026-10-28；两个新文件无 error / 无 warning）。
2. **隔离编译**：用与 `MusicBackend.swift` / `MediaModels.swift` 同签名的 stub，单独
   `swiftc -typecheck -swift-version 5 -target arm64-apple-macos13.0` 通过（排除他人文件干扰）。
3. **自带 SHA-256 正确性**：与官方测试向量 + `shasum -a 256` 交叉验证：
   - `""` → `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
   - `"abc"` → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`
   - `"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"` →
     `248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1`
   - `"https://nas.example.com:5666/music|ravooo"` → `e0700d4cb21f0c8e...`（与 `printf | shasum -a 256` 一致）
4. **HLS 播放列表改写**（把播放列表喂给真实实现，`rewrites` 前后对比）：
   - 相对分片 `seg/000.ts` → `https-authz://nas.example.com:5666/music/api/v1/track/seg/000.ts`
   - `#EXT-X-KEY ... URI="keys/k1.bin"` → `https-authz://.../keys/k1.bin`
   - `#EXT-X-MEDIA ... URI="audio.m3u8"` → `https-authz://.../audio.m3u8`
   - 绝对 CDN URL 的 query `?sig=abc%2Fdef` 原样保留
   - scheme 往返（`https` → `https-authz` → `https`）与原 URL **完全相等**（含 `%2F`、`%2B`、`%3D`）
5. **未做**：真机/真服务器联调（需要飞牛 NAS + authx 账号）；HLS 分片路径与加密流见 §2.6 的 TODO(C)。

---

## 6. 遗留清单（按优先级）

| 优先级 | 事项 | 位置 |
|---|---|---|
| P0 | 真机验证 HLS 分片是否进 delegate；决定是否需要 loopback 代理 | `MediaResourceLoader.swift` 的 `TODO(C)` |
| P0 | 退出登录/换账号接 `clear` + `flushNow`；`applicationWillTerminate` 接 `flushNowBlocking` | `AppState` / `AppDelegate`（不属本任务写权限） |
| P1 | `merge` 切换精确版（按 kind 传收藏能力） | `MusicDataStore.applyLocalOverrides` |
| P1 | 「继续播放 / 我的收藏」接 `resumableIDs` / `favoriteIDs`（跨会话、未加载曲库） | 发现页 / 状态层 |
| P2 | 本地记录按曲库 id 差集清理（服务端删条目后不残留） | `LocalLibraryState` 新增维护方法 |
| P2 | 加密 HLS（若飞牛提供）需要 `AVContentKeySession` 方案 | 新文件，不在本任务 |
