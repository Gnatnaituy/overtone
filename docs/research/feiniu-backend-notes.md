# 飞牛音乐后端实现说明（Backend/Feiniu/）

> 读者：接手的工程师 / 做真机验证的人 / 合并前 review 的人。
> 事实来源：`docs/research/fnos-music-api.md`（下称「协议档」）、
> `/tmp/fnresearch/XDORG-N1_FnMusic/lib/app/services/feiniu/*.dart`（下称 [dart]）、
> `/tmp/fnresearch/seasonyuu_FnMusic/api.md`（下称 api.md）。
> 结构风格对齐：`Sources/JellyfinMac/Backend/Jellyfin/JellyfinBackend.swift`。

## 0. 文件结构（每个文件只做一件事）

| 文件 | 职责 | 是否纯函数 |
| --- | --- | --- |
| `FeiniuBackend.swift` | `MusicBackend` 实现（27 个端点）、能力副本、传输层与凭据注入 | 否（@MainActor） |
| `FeiniuWire.swift` | 宽容 JSON 树 `FeiniuJSON`、`{code,msg,data}` 信封、业务码 → `MusicBackendError` | 是 |
| `FeiniuMapping.swift` | wire → 领域模型（`MediaItem` / `MusicLibrary` / `RemotePlaylist` / `ArtworkRef`） | 是 |
| `FeiniuAuthx.swift` | `authx` 签名（MD5、GET query 规范化、签名路径）、Cookie/安全码/authx 头 | 是（nonce/时钟由调用方注入） |
| `FeiniuAddress.swift` | 服务器地址规范化（收敛到 `scheme://host[:port]/music`） | 是 |
| `FeiniuDuration.swift` | `duration` 秒/毫秒归一化、epoch 秒/毫秒归一化 | 是 |
| `FeiniuLyrics.swift` | LRC → `[LyricLine]` 解析 | 是 |
| `FeiniuPlaybackFormat.swift` | 格式 → 能否直连播放（AVPlayer macOS 侧黑白名单） | 是 |

**没有改任何别人的文件**：`MusicBackend.swift` / `MediaModels.swift` / `HTTPClient.swift` /
State / Views / Player 全部未动。能力差异用本目录里的 `BackendCapabilities.feiniuBackend`
副本表达（`search: true`），协议层那份 `BackendCapabilities.feiniu` 保持原样。

## 1. 已实现端点清单（27 个）

基址为 `scheme://host[:port]/music`；下表路径相对基址。证据列写协议档章节 + 参考实现。

### 会话

| # | 方法 | 路径 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| 1 | POST | `/api/v1/user/password-login` | 登录（`password`=SHA256 hex、带 `deviceId`，自己写 `music-token`） | 协议档 §2.2 V；api.md §6.1 V+S |
| 2 | GET | `/api/v1/user/me` | 会话校验（**不能用 `/sys/config`**） | 协议档 §2.6 V |

### 媒体库 / 浏览

| # | 方法 | 路径 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| 3 | GET | `/api/v1/shared-library/list` | 音乐库列表（空则兜一个 `feiniu` 库） | 协议档 §3.1 V+S |
| 4 | GET | `/api/v1/track/list` | 曲目列表（`page`/`size`/`sort`） | §3.2 V+S |
| 5 | GET | `/api/v1/album/list` | 专辑列表 | §3.3 V+S |
| 6 | GET | `/api/v1/artist/list` | 艺人列表（无 `sort` 参数） | §3.3 V+S |
| 7 | GET | `/api/v1/track/album-detail/list` | 专辑曲目（参数 `albumGUID`，防御式翻页） | §3.2 V+S |
| 8 | GET | `/api/v1/album/artist-detail/list` | 艺人专辑（参数 `artistGUID`） | §3.3 V+S |
| 9 | GET | `/api/v1/track/artist-detail/list` | 艺人曲目（参数 `artistGUID`） | §3.2 V+S |
| 10 | GET | `/api/v1/search/track` | 搜索·曲目（参数名是 `q`） | §3.5 V+S |
| 11 | GET | `/api/v1/search/album` | 搜索·专辑 | §3.5 V+S |
| 12 | GET | `/api/v1/search/artist` | 搜索·艺人 | §3.5 V+S |

### 媒体

| # | 方法 | 路径 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| 13 | GET | `/api/v1/static/cover` | 封面（`coverId`+`size`；`size` 由 `maxWidth` 映射 200/400/800） | §3.7 V |
| 14 | GET | `/api/v1/lyric/list` | 歌词（`trackGUID`，返回 LRC 文本 → 本地解析） | §3.7 V+S |
| 15 | GET | `/api/v1/track/stream` | 直连播放地址（`guid`；字节流由播放器读） | §4.1 V |
| 16 | POST | `/api/v1/track/transcode` | 发起转码，读 `data.url` | §4.2 V+S |
| 17 | GET | `/api/v1/track/hls/{guid}/preset.m3u8` | 确定性 HLS 清单（转码回退 / `url` 缺失时兜底） | §4.2 V |

### 写

| # | 方法 | 路径 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| 18 | POST | `/api/v1/favorite-track/create` | 收藏（body `{"trackGUID":…}`） | §5.1 V+A |
| 19 | POST | `/api/v1/favorite-track/delete` | 取消收藏 | §5.1 V+A |
| 20 | POST | `/api/v1/event/report` | 播放事件（**只有 `track_play`**，仅 `.started` 发） | §4.5 V+S |

### 远程歌单

| # | 方法 | 路径 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| 21 | GET | `/api/v1/playlist/list` | 歌单列表 | §3.4 V+S |
| 22 | GET | `/api/v1/track/playlist-detail/list` | 歌单曲目（参数 **`playlistGUID`**） | §3.2 V+S |
| 23 | POST | `/api/v1/playlist/create` | 建单（`{"name":…}`，读 `data.guid`） | §5.2 V+S+A |
| 24 | POST | `/api/v1/playlist/edit` | 改名（**写用 `guid`**，小写） | §5.2 V+S+A |
| 25 | POST | `/api/v1/playlist/add-track` | 批量加曲（`{"guid":…,"trackGUIDs":[…]}`） | §5.2 V+S+A |
| 26 | POST | `/api/v1/playlist/remove-track` | 批量移曲 | §5.2 V+S+A |
| 27 | POST | `/api/v1/playlist/delete` | 删单（不可恢复） | §5.2 V+S+A |

**刻意没做的**（都有明确原因，别当成遗漏）：

- **FN Connect**（`/api/v1/fn/con` 定位 → 选路 → relay 激活 → `Cookie: mode=relay`）：
  协议档 §1.3 评估为独立的 3–5 天工作块。`fnos.net` / `5ddd.com` 地址一律抛
  `.invalidServer("需要填写完整 NAS 地址…")`，代码注释里留了 TODO。
- **转码保活/收尾**（`transcode/heartbeat` 每 10s、`transcode/quit`）：属于播放器生命周期，
  本轮只交付「怎么拿到转码地址」。
- 播放进度、播放统计、专辑/艺人收藏、歌单重排：**飞牛协议里不存在**（协议档 §7.4），
  已通过能力声明关掉，UI 走本地兜底。
- `track/metadata`：映射函数 `FeiniuMapping.trackDetail` 已写好但**未接端点**（列表项已带
  `audioSpec`，暂时用不上）。
- `favorite-track/list`、`play-history/list`、`roam-start/next/previous`、`genre/*`、
  `search/suggest`、`search/playlist`、`playlist/batch-detail`、`playlist/purge-track*`、
  `static/cover/playlist`（封面上传）、`access_code_verify`：本轮未接
  （收藏页/漫游/风格页/封面上传由后续任务接）。

## 2. 与 Jellyfin 后端的结构差异（review 时的对照点）

| 项 | Jellyfin | 飞牛 |
| --- | --- | --- |
| 凭据注入 | `Authorization: MediaBrowser …`（静态） | `Cookie: music-token=…` **+ 可选 `authx`（逐请求签名）** |
| 注入位置 | `HTTPClient.prepare` | 同样 `prepare`，但签名要读 `request.httpBody` |
| 播放器授权 | `authorization = nil`（token 在 query 里） | `RequestAuthorization`：`authxEnabled` 时 `isDynamic = true`（必须走 resource loader）；关掉时 `.fixed` + `isDynamic = false` |
| 分页 | `StartIndex`/`Limit` | `page`/`size`（从 1 开始）+ 防御式翻页 |
| 响应信封 | 直接对象 | `{code,msg,data}`，**HTTP 200 + 非 0 code 是常态**，必须双重判定 |
| 解码 | `PascalCase → camelCase` 策略 | `useDefaultKeys`（camelCase 与大写 GUID 混排，**禁止自动转换**） |
| JSON 解析 | 严格 Codable DTO | 宽容 JSON 树 → 单条坏数据不会拖垮整页 |
| duration | ticks/10⁷ | 秒/毫秒混用，阈值 20000 归一 |
| 错误 | `MusicBackendError` | 同（业务码映射成中文；**不泄漏 URLError**） |

## 3. 留的 TODO（全部带 `TODO(C)` 标记，可 `grep -rn "TODO(C)" Sources/JellyfinMac/Backend/Feiniu`）

1. **`authx` Cookie 编码**：协议档 §2.3 记录 [primuse] 会百分号编码 token，而 [dart]/[ps5]
   原样发。这里跟原样发（两个真机实现）。→ 若「登录成功但立刻 401」，先改成百分号编码。
2. **`[offset:]` 方向**：LRC 全局偏移按「正值=提前」实现（`start = time - offset`）。
   真机若整体偏移 2×offset，改成加法。
3. **`accessStatus != 0` 的曲目被直接丢弃**：`MediaItem` 没有「不可播」字段，而本次边界
   不允许改 `MediaModels.swift`。状态层将来加 `isPlayable` 后应改为标灰而非丢弃。
4. **CUE 整轨未处理**：需要「同 album 同 `audioSpec.path` 按 discNo/trackNo 排序累加偏移 +
   `forwardPlaybackEndTime`」，属播放器层，且 `MediaItem` 拿不到 `audioSpec.path`。
   现在返回整轨流（= 一首超长曲目）。
5. **`updateRemotePlaylist` 是先清空再按序加**：飞牛无重排/批量替换端点，中途失败会留下
   空/半空歌单。协议档 §8#10 把 `playlist/*` 写操作的幂等性列为未解问题 → 状态层应先缓存整单。
6. **转码音质档位无法协商**：不发 `output`（[dart] 的最小契约）。AAC 会返回 `errno 8192`，
   服务端实际只有「原始 / 默认 opus」两档 → `PlaybackPreferences.targetBitrate` 只能决定
   「要不要转码」。
7. **`transcode/heartbeat` + `transcode/quit`** 未接（播放器生命周期，需每 10s 保活）。
8. **`preset.m3u8` 未预热**：直连时的 `transcodeFallback` 直接指向该地址，若 404 说明必须先
   POST `/track/transcode` 预热。
9. **封面 URL 不带凭据**：若真机确认 cover 请求也要 authx/Cookie，取图方必须用
   `mediaRequestAuthorization()` 注入同样的头（图片层不在本任务边界内）。
10. **登出无端点**：只清本地状态；协议档 §8#4 把「主动注销」列为未验证。
11. **业务码表不全**：只映射了 `120001`/`100002`/`100005`/`160001`/`160002`/`99999`；
    其余按「原始 msg + 错误码」透出（中文文案后续补）。
12. **`defaultScheme` 的端口启发式**：`5667`/`443`→https，其余→http；只开 https 的内网域名
    会被猜错（失败信息里提示显式写 `https://`）。
13. **`sort` 字段名**：只有 `createdAt,desc`（track）与 `newTrackAddedAt,desc`（album）是实测值。
14. **FN Connect** 整体未做（见上）。
15. **`track/metadata` 未接**（映射函数已备好）。
16. **新增领域字段留给集成阶段**（Lead 决定）：`MediaItem.genres: [String]`（wire 的
    `genres[].name`）与 `childCount: Int?`（专辑 = `trackCount`、艺人 = `albumCount`）。
    飞牛的 wire 上都有，但映射处已标 `TODO(集成)`，本任务不回头改。
17. **`bitrate` 单位**已按 Lead 的领域口径（bps）核对完毕：**不需要 `*1000`**，
    证据见 §4 表最后一行。

## 4. 只能猜的字段 / 契约（合并或真机时优先怀疑的地方）

| 项 | 我们的取值 | 为什么只能猜 |
| --- | --- | --- |
| 收藏 body | `{"trackGUID":…}`（大写 GUID） | **证据冲突**：协议档/官方 Web 是大写，[dart] 是小写 `trackGuid` |
| 艺人列表的 `albumCount` / `trackCount` | 有就显示「N 张专辑 / N 首歌曲」，没有就不显示 | 列表项字段没有实测样本（[dart] 只解 guid/name/coverId） |
| 封面 `size` 合法取值 | 200 / 400 / 800 三档 | 协议档 §8#12 明确「合法取值未知」，[dart] 默认 300 |
| `isLRC` 缺省值 | `true` | 协议档样例里有该字段但没说缺省语义 |
| 转码 `status` 取值集合 | `ready` / `success` 之外都算失败 | 协议档 §4.2 表格只给了两个值，`errno` 语义未展开 |
| 转码 `url` 的相对基准 | 按 `…/music/api/v1/` 解析（并补尾斜杠） | [dart] 用 API 基址解析，但没有真机样本；也可能是 `/music/` 或绝对路径 |
| `data.guid`（建单返回） | 读 `data.guid` | [dart] 这么读，api.md 未记录该字段 |
| 登录响应 `user.guid` / `user.name` | 读这两个 | [dart] `FnLoginResult` 兼容 `userId`/`nickname`，说明别处见过别名 |
| `deviceId` | 32 位 hex、`UserDefaults` 持久化、全 App 共用 | 协议档 §2.5 是 S 级（实现级证据，非实测）：同 deviceId 只认最后一次登录 |
| `event/report` 幂等 / 去重 | 只发一次（`.started`） | 协议档 §4.5 明说服务端幂等语义 C |
| 播放事件 `payload` | 只有 `trackGUID` | 四个客户端 + 官方 Web 都只发这一种，但没有位置字段可用 |
| `album.releaseDate` → year | **不猜**，只读列表项的 `year` | 协议档 §6.2 明确警告 [ps5] 直接把日期当 int 会得 0 |
| LRC 时间轴单位 | 十进位秒（`[mm:ss.xx]`） | 协议档 §3.7 把「时间轴单位」列为 C |
| `sort=name,asc` | 猜的字段名 | 无任何实测样本 |
| 分页 `total` 为 0 的部署 | 当成「未知」，翻页到空页为止 | 有部署一直回 `total:0`（协议档 §9.2 也提醒「total 可能是 0/缺失」），信它会第一页就停 |
| `audioSpec.bitrate` 单位 | **bps，不换算** | 协议档 §6.5 只写「码率」；[kotlin] 显示时 `/1000` 得 kbps，单测样本 `320000 → "320 kbps"`、FLAC `847806`（`PlaybackQualityTest.kt:11`、`MusicUi.kt:2307`）→ 反推服务端已是 bps。真机若显示成天文数字再改成 `*1000` |

## 5. 真机验证：最该先试的 3 件事

> 目标是把「协议档 §8 未解问题」里影响工期最大的几个一次打掉。每项都有现成 curl。

### ① `authx` 到底是不是必需 —— 顺带验 Range 206

决定播放层工作量是「半天」还是「一周」（协议档 §7.6 结论表）：

```bash
BASE="http://192.168.1.10:5666/music/api/v1"   # 换成你的 NAS
T="<登录拿到的 userToken>"

# A) 不带 authx：只带 Cookie + Range
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Cookie: music-token=$T" -H 'Range: bytes=0-1' \
  "$BASE/track/stream?guid=<trackGuid>"
# 期望 206 → 说明 Cookie 就够，播放器可以走「静态头 + AVURLAssetHTTPHeaderFieldsKey」

# B) 再跑一次同样的请求，但把后端 authxEnabled 设 false 走一遍曲库列表
curl -s -H "Cookie: music-token=$T" "$BASE/track/list?page=1&size=5"
# 期望 {"code":0,...} → 证实「authx 非必需」
```

判读：
- 两次都 OK → `authxEnabled = false` 作为默认值发布，播放层用 `isDynamic = false`（省一周）；
- 不带签名 401/403 / relay 页 → 保留 `authxEnabled = true`，播放层必须走
  `AVAssetResourceLoader`（`RequestAuthorization.isDynamic == true` 已经这么声明了）。

### ② `duration` 的单位（逐接口）

最可能引发「时长错乱 + 进度条乱跳」的字段（协议档 §6.1 / §8#2）。同一首歌对比三个接口的
**原始值**：

```bash
curl -s -H "Cookie: music-token=$T" "$BASE/track/list?page=1&size=1"      | jq '.data.list[0]|{guid,duration,audioSpec}'
curl -s -H "Cookie: music-token=$T" "$BASE/track/album-detail/list?albumGUID=<albumGuid>&page=1&size=1" | jq '.data.list[0]|{guid,duration}'
curl -s -H "Cookie: music-token=$T" "$BASE/track/metadata?guid=<trackGuid>" | jq '.data|{track:.track.duration,spec:.audioSpec.duration}'
```

判读：若某接口给 300 / 另一个给 300000 → 阈值 20000 的归一化是对的（`FeiniuDuration`）；
若两个都给毫秒 → 阈值法在「20 秒以内的短音效」上会误判，需要改成「按接口来源」判定。

### ③ 写接口的小写/大写分裂 —— 先验收藏，再验歌单

收藏是**唯一一处两份证据直接冲突**的地方（大写 `trackGUID` vs 小写 `trackGuid`），
而且写接口最容易「HTTP 200 但其实没生效」：

```bash
# 1) 大写
curl -s -X POST "$BASE/favorite-track/create" -H "Cookie: music-token=$T" \
  -H 'Content-Type: application/json' -d "{\"trackGUID\":\"<trackGuid>\"}"
# 2) 立刻查收藏列表（这是唯一能证实「真的生效」的方式，别只看 code）
curl -s -H "Cookie: music-token=$T" "$BASE/favorite-track/list?page=1&size=20" \
  | jq '[.data.list[].guid] | index("<trackGuid>")'
# 3) 再试小写（若 1) 没生效）
curl -s -X POST "$BASE/favorite-track/create" -H "Cookie: music-token=$T" \
  -H 'Content-Type: application/json' -d "{\"trackGuid\":\"<trackGuid>\"}"
# 记得删除测试收藏，恢复现场
```

同一次会话里顺手验掉两个小项：
- **`size` 是否被静默 cap**：`/track/list?page=1&size=500`，比对 `data.list` 长度与 `total`
  （协议档 §7.2 争议点，决定 `allPages` 是否必要——目前实现是按「会被 cap」写的）；
- **`playlist/*` 参数名**：读用 `playlistGUID`、写用 `guid`（我们已按此硬编码），
  建一个临时歌单跑一遍 create → add-track → remove-track → delete，确认 `data.guid` 字段存在。

## 6. 编译验证状态

- **本目录 8 个文件**：`swiftc -typecheck`（模块内最小依赖集，`-swift-version 5`）
  → **0 error / 0 warning**。
- **全量**：`./scripts/dev-typecheck.sh` → **`Build complete!`**（最终一次真实重编译 40.93 sec；
  期间另有 41.31 / 41.41 / 43.30 sec 三次成功编译）。

  > 说明：中途有两次全量编译失败，原因都在**并行队友的在写文件**上
  > （`Player/MusicPlayerModel.swift` 引用了尚未落地的 `MediaResourceLoader`、
  > `State/PlaylistSyncService.swift` 引用了未定义的 `trackID`）。这两处不在本任务的
  > 写权限内，没有做任何改动；队友落地后同一份代码即通过。
  > 最终这次成功编译里没有任何来自 `Sources/JellyfinMac/Backend/Feiniu/` 的
  > error 或 warning。
