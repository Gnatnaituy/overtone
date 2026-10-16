# 客户端歌曲刮削 —— 可行性结论与技术方案

> 状态：**方案待评审**，未动代码。
> 结论口径：服务端权限与端点形态**实测自 `jellyfin/jellyfin` 源码与官方 OpenAPI**；音源行为**实测自真实请求**（2026-10-06）。
> 原始研究记录（含全部引用链接与「未验证」标注）见 [`docs/research/client-scraping-sources.md`](research/client-scraping-sources.md)。

---

## 0. 结论摘要

**全量工作量：约 4–6 周。**

但这个数字可以切成四刀，**第一刀 4–6 天就能拿到绝大部分实际收益**：

| 阶段 | 内容 | 人日 | 服务端权限 |
|---|---|---|---|
| **S1** | 歌词刮削（本地覆盖 + 写回服务器） | 4–6 | `EnableLyricManagement`（可单独授予，非 admin） |
| **S2** | 封面 / 专辑元数据刮削（**仅本地展示**） | 5–8 | **无**（任何用户可用） |
| **S3** | 候选选择器 + 差异预览 + 元数据写回 | 5–8 | 写回需 **admin** |
| **S4** | 批量刮削（队列 / 进度 / 报告） | 5–8 | 同上 |

**建议先做 S1。** 歌词是唯一一条「客户端能自己刮、又能干净写回服务器」的路径；元数据与封面写回都撞管理员墙，且接口本身有损。

---

## 1. 为什么客户端刮削是必要的（而不是重复造轮子）

### 1.1 服务端**根本没有**单曲级刮削 —— 对任何人都不行

- 没有 `POST /Items/RemoteSearch/Audio` 或 `/MusicSong` 端点。
- 没有任何类型实现 `IRemoteMetadataProvider<Audio, SongInfo>`。
- **曲目只能作为专辑的 `AlbumInfo.SongInfos` 子项，在「整张专辑刷新」时被顺带匹配。**

后果：当服务端认不出某张专辑时，**没有任何办法单独修正其中一首歌的元数据**——只能整张重新匹配，或手写全量 DTO。这正是华语/ACG 曲库最常见的痛点。

### 1.2 服务端的音乐元数据 Provider 实际只有一家能用

| 服务端 Provider | 专辑远程搜索 | 艺人远程搜索 |
|---|---|---|
| MusicBrainz | ✅ 真实结果 | ✅ |
| TheAudioDB | ❌ **空实现**（`Enumerable.Empty<RemoteSearchResult>()`） | ✅ |

> **重要澄清（避免误判）**：这**不**代表 MusicBrainz 数据库的华语覆盖差。实测 `artist:周杰伦 AND recording:晴天` 返回 **495 条、score 100**，且带全套 CJK 别名（周杰倫 / ジェイ・チョウ / 주걸륜）——**主流华语流行乐覆盖良好**。
> 真正的问题是**服务端集成层**：专辑匹配实际只有 MusicBrainz 一家，且完全没有单曲级入口。

### 1.3 服务端的写入路径又贵又有损

`POST /Items/{itemId}` 的实测特性：

- **只接受完整 `BaseItemDto`**；`Jellyfin.Api/Controllers` 里**没有任何 `HttpPatch`**。
- `Name` / `Overview` / `IndexNumber` / `ParentIndexNumber` / `ProductionYear` / `CommunityRating` / `PremiereDate` / `OfficialRating` 等字段**无条件赋值** —— 传残缺 DTO 会把这些字段**置空**。
- 编辑 `MusicAlbum` 会把 `OfficialRating` / `Tags` 等**传播到所有子曲目**（除非子项锁字段）。
- 且**必须管理员**。

所以写回只能走 `GET 完整 DTO → 改字段 → POST 回去`，并必须有差异预览兜底。

### 1.4 权限矩阵（决定功能对谁能用）

| 能力 | 端点 | 权限 |
|---|---|---|
| 读歌词 | `GET /Audio/{id}/Lyrics` | 任意用户 |
| **写 / 删歌词** | `POST`·`DELETE /Audio/{id}/Lyrics` | `EnableLyricManagement`（**默认关闭，可单独授予非管理员**） |
| 远程歌词搜索 / 下载 | `GET`·`POST /Audio/{id}/RemoteSearch/Lyrics…` | 同上 |
| 搜索专辑 / 艺人候选 | `POST /Items/RemoteSearch/MusicAlbum`·`MusicArtist` | 任意用户 |
| 触发重新刮削 | `POST /Items/{id}/Refresh` | **仅 admin** |
| 应用候选 | `POST /Items/RemoteSearch/Apply/{id}` | **仅 admin** |
| 手写元数据 | `POST /Items/{id}` | **仅 admin** |
| 上传封面 | `POST /Items/{id}/Images/{type}` | **仅 admin** |
| 整库重扫 | `POST /Library/Refresh` | **仅 admin** |
| **写艺人简介** | **不存在此端点** | —— |

> `RequiresElevation` 的实测定义是 `.RequireClaim(ClaimTypes.Role, UserRoles.Administrator)` —— **字面意义上的管理员角色**，不是可授予的细粒度权限；非管理员一律 403。

**这是最重要的设计约束**：功能必须按「当前账号能做什么」分档降级，不能假设用户是管理员。

---

## 2. 三档写回策略（核心架构决策）

同一个刮削结果有三种归宿。显式分档，才能「先交付无风险的 80%」：

### L1 · 本地覆盖（display-only）
- 刮到的数据**只存本地**，UI 优先显示，**完全不碰服务器**。
- 不需要任何权限，**任何账号可用**，零破坏风险。
- 缺点：只在 Overtone 里可见。

### L2 · 歌词写回
- `POST /Audio/{itemId}/Lyrics?fileName=xxx.lrc`，`Content-Type: text/plain`，body 是**原始 LRC 文本**（注意：**不是** JSON `LyricDto`）。
- 非破坏、可 `DELETE` 撤销、格式简单 —— **唯一一条干净的服务端写入路径**。
- 需要 `EnableLyricManagement`。写回后所有客户端都能看到，价值远高于 L1。

### L3 · 元数据 / 封面写回
- 走 §1.3 的 `GET → 改 → POST` 全量 DTO 流程；封面走 `POST /Items/{id}/Images/Primary`。
- **必须 admin**，且**必须先出差异预览再确认**（字段会被无条件覆盖）。
- 建议提供 `LockedFields` 开关，避免后续服务端刮削冲掉手工修正的值。
- **艺人简介没有写回端点，只能停在 L1。**

> 实现建议：把 **L1 当作统一数据通道**，L2/L3 是它的「推送」动作。这样 S1/S2 只做 L1 + 一个按钮，S3 把按钮换成带预览的流程，代码不白写。

---

## 3. 音源选型（全部实测）

### 3.1 歌词

| 音源 | 实测结果 | 认证 | 中文输入 | 备注 |
|---|---|---|---|---|
| **lrclib.net** | ✅ 首选。`/api/get`（artist+track+album+duration 精确匹配）与 `/api/search?q=` 均通过。周杰伦《晴天》返回**同步 LRC**；李克勤《总有你鼓励》粤语；残酷な天使のテーゼ 日语 | **无需 key** | ✅ 直接可用 | 返回 `plainLyrics` + `syncedLyrics`。**实测 6 次突发请求中有 1 次 `HTTP 503 ServerOverloaded`** → 必须串行化 ~1 req/s 并遵守 `Retry-After` |
| **网易云** | ✅ **无需 weapi/eapi 加密**。`/api/search/get/web?s=&type=1&limit=`；`/api/song/lyric?id=&lv=1&kv=1&tv=-1` | 仅需 `User-Agent` + `Referer: https://music.163.com` | ✅ 直接可用 | 带时间轴 LRC，**且有 `tlyric` 翻译**与 `作词/作曲/编曲` credits。⚠️ 参考实现 [NeteaseCloudMusicApi 已归档](https://github.com/Binaryify/NeteaseCloudMusicApi)（版权压力），属「实践中耐用、但永不稳定」 |
| **QQ 音乐** | ⚠️ **歌词可用、搜索不可用**。歌词 `c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=&nobase64=1` 返回完整 LRC；但 `client_search_cp` 返回空、`musicu.fcg` 返回 `code 2001` | 仅需 `Referer` | 歌词 ✅ | **只能「已知 songmid 取词」，不能用于发现** |
| **酷狗** | ✅ 两步都通过。`songsearch.kugou.com/song_search_v2`（480 条）→ `krcs.kugou.com/search` 拿 `id`+`accesskey` → `krcs.kugou.com/download` 返回 **base64 编码的 LRC** | 无需 | ✅ | 旧的 `mobilecdn.kugou.com` 已死 —— 活生生的接口腐烂案例 |
| 咪咕音乐 | 未单独验证 | —— | —— | 先例项目 Music Tag Web 在用，可作为补充 |

**Musixmatch / Genius：排除。** Musixmatch [API 条款](https://about.musixmatch.com/apiterms) 是硬性阻断：仅限非商业（§1.1）、强制 "powered by Musixmatch" 署名（§2.1.5）、**禁止 AI/ML 用途**（§2.2.14）、终止时须删除全部数据（§7.2.1）。Genius 条款未验证，但长期约束是「只给元数据+回链，不给歌词文本」。

### 3.2 封面 / 专辑元数据

| 音源 | 实测结果 | 中文输入 | 备注 |
|---|---|---|---|
| **网易云** `album.picUrl` / `picId` | ✅ 搜索即可拿到 | ✅ | **华语封面主要靠它**。但 URL 常带时效签名 → **不能当长期缓存 key** |
| **MusicBrainz + Cover Art Archive** | ✅ `coverartarchive.org/release/{mbid}/front-250` 307 跳转后返回真实 JPEG（需跟随重定向） | ✅ 主流华语可用 | 强制描述性 `User-Agent`，**硬性 1 req/s** |
| **iTunes Search** | ✅ 可用，但**必须罗马音输入**：搜 `Jay Chou` 有结果；`country=CN` 搜「周杰伦」返回 **0 条** | ❌ 中文文本 | 封面把 URL 的 `/100x100bb.jpg` 换成 `/600x600bb.jpg`。Apple 美术素材条款**未验证** |
| **Deezer** | ✅ `api.deezer.com/search/album?q=`（`Jay Chou` 65 条） | ❌ 中文文本（`search?q=周杰伦` 返回 `data:[]` 但 `total:156`） | `cover_xl` 可用；缓存条款**未验证** |
| **TheAudioDB** | ⚠️ **免费 key 变了**：老教程的 `2`、`1` 现在返回 `{"Message":"Not found"}`（连 Coldplay 都查不到）；**`123` 可用** | ❌ 需罗马音（`周杰伦` → null，`Jay Chou` → 有，且带 `strArtistAlternate: "周杰倫, 周杰伦"`） | ACG/doujin 覆盖差 |
| 豆瓣音乐 | API 早已停止公开服务 | —— | **排除**，不要围绕它做规划 |

> 封面**必须把图片字节落盘**，不能只存第三方 URL —— 网易云等图 URL 会失效。见 §5。

### 3.3 一个关键规律：官方源要罗马音，非官方源认中文

上表暴露出一条清晰的分界线：

- **官方/西方源**（iTunes、Deezer、TheAudioDB）——中文文本查询基本失效，**必须先把「周杰伦」转成「Jay Chou」**。
- **非官方/华语源**（网易云、QQ、酷狗、lrclib、MusicBrainz）——**直接吃中文**。

**设计后果**：需要在匹配层内置一层 **罗马音 / 别名映射**（艺人别名表 + 简繁转换），否则等于白白放弃 iTunes / Deezer / TheAudioDB 三个源。MusicBrainz 的 `strArtistAlternate` / 别名数据可以给这层做种子。

---

## 4. 匹配算法（真正的技术难点）

音源好找，**匹配准才是难点**。直接取搜索第一条会写错数据（实测：iTunes 搜「周杰伦 稻香」返回 `Rice Field (Piano Version) / Bryan Chi`）。

**直接移植 beets 的默认权重**（`beets/config_default.yaml`，久经考验）：

| 特征 | 权重 |
|---|---|
| `track_title` | 3.0 |
| `artist` | 3.0 |
| `album` | 3.0 |
| `track_artist` | 2.0 |
| **`track_length`** | **2.0** |
| `track_index` | 1.0 |
| `year` | 1.0 |

阈值：`strong_rec_thresh: 0.04`、`medium_rec_thresh: 0.25`、`rec_gap_thresh: 0.25`。
时长容差：**`track_length_grace: 10`（±10s 免费）、`track_length_max: 30`（>30s 直接淘汰）**。

**时长为什么关键**：lrclib 搜《晴天》同时返回 **299s（live）/ 270s（录音室）/ 249s** 三个版本 —— 时长是区分版本的决定性特征。

配套的文本归一化：
1. **简繁统一**（同一首歌两个源可能分别返回简体和繁体，实测存在）。
2. 去括号内容（`(Live)` / `【】` / `feat.`）、大小写、标点、空白。
3. 多艺人分隔符统一（`/` `&` `、` `feat.`）。
4. 罗马音 / 别名映射（§3.3）。
5. **低分不自动应用** —— 交给候选选择器（S3 的价值所在）。

**不推荐声纹指纹**：技术上可行（[ChromaSwift](https://github.com/wallisch/ChromaSwift)，MIT、SPM、Swift 6），但 `AudioFingerprint(from: fileURL)` **要求音频在本地**，得先把整曲从 Jellyfin 下载下来；且 AcoustID 的指纹库恰恰在 CJK/ACG 上最弱——正需要它的地方它最不行。**ROI 太低，跳过。**

---

## 5. 缓存与持久化（含一个已发现的现存问题）

### 5.1 现状：这个 App **没有封面磁盘缓存**

实测：

- `ImageCache`（`MediaComponents.swift:8`）是**纯内存** `[String: NSImage]`，LRU 上限 **400 张**，无任何落盘。
- `RemoteImage` 走 `URLSession.shared.data(from:)`，落盘与否取决于系统默认 `URLCache`，**应用不可控**。
- 设置页「缓存上限」`settings.imageCacheLimitGB`（1–100 GB）**全项目只用于显示**（`SettingsView.swift:468/474` 算进度条比例），**没有任何代码读它做淘汰** —— 这个 Stepper 目前是装饰品，文案「超出后自动淘汰最旧的封面」与实现不符。
- 「缓存占用」测的是 `~/Library/Caches/<bundleId>`（`SettingsView.swift:493`），即系统 URLCache 目录，与内存里的 `ImageCache` 无关。

### 5.2 刮削功能需要的持久化

新建 `~/Library/Application Support/JellyfinMac/scraping/`（沿用 `PlaylistStore` 的 JSON 原子写模式，`PlaylistStore.swift:261-266`）：

```
scraping/
├── overrides.json        # itemId → { fields, source, fetchedAt, confidence }
├── lyrics/<itemId>.lrc   # 歌词原文（保留原文便于重发）
└── covers/<itemId>.jpg   # **图片字节**，不是 URL
```

要点：

- **必须存字节**（§3.2：第三方图 URL 会失效）。
- 覆盖表记 `source` / `fetchedAt` / `confidence`，便于「重新刮削」与排查。
- 每个 Provider 隔离在 protocol 后面，带**健康度统计**；一个全局串行队列 + 分 host 配额（MusicBrainz 1 req/s 是硬约束，lrclib 突发会 503，Last.fm 存储上限 100 MB）。
- **曲库规模到万级时**：单表 JSON 仍在可接受范围（与现有 `PlaylistStore` 一致）；若 S4 批量刮削规模压垮它，再换 SQLite/GRDB。**先不要提前优化。**
- 顺手把 `imageCacheLimitGB` **接上**：让它真正约束这个目录，或把文案改成实话。

---

## 6. 先例：Music Tag Web

[`xhongc/music-tag-web`](https://github.com/xhongc/music-tag-web) 是**架构上最接近的先例** —— 同样是「为**远端服务器上**的音乐做刮削的 sidecar」，同样编辑远程文件，音源是 网易云 / QQ / **咪咕**。

其许可值得注意：**GPL-3.0 + 附加条款**，而附加条款实质上是一份法律警告 —— 仅限非商业，且要求使用者**在 24 小时内清除刮削到的版权数据**。如果 Overtone 要发布这个功能，预期需要同级别的免责声明。

---

## 7. 法务风险（会影响产品决策）

| 事项 | 约束 | 影响 |
|---|---|---|
| **Musixmatch** | 仅非商业、强制署名、**禁止 AI/ML 用途**、终止须删数据 | **硬阻断，不接入** |
| **Last.fm** | 仅非商业（§3.1）、强制 "powered by AudioScrobbler" 链接（§2.7）、**存储上限 100 MB**（§4.3.4）、**美术素材明确排除在授权外**（§5.1.8） | 简介可以，**艺人图片不行**（改用 Deezer / TheAudioDB / Wikipedia） |
| 网易云 / QQ / 酷狗 等非官方接口 | **完全没有授权** | 仅个人使用；不内置 key、不代理分发内容；默认走 lrclib 这类开放源 |
| Apple / Deezer 美术条款 | 未验证 | 待补 |

---

## 8. UI 工作量（本项目特有的成本）

UI 标准高（v3 规范、Liquid Glass、44pt 热区、可访问性、窄窗五档），而所需的三类 UI **全是净新增**：

| 需要的东西 | 现状 | 成本 |
|---|---|---|
| 候选选择 sheet | **全项目零处 `.sheet(` / `.popover(`** | 首次引入 sheet，要按 v3 规范做玻璃/暗色/键盘/无障碍 |
| 差异预览（改前 → 改后） | 无 | 新组件，L3 的安全前提 |
| 批量多选 | **无任何多选**（`selection` 只用于单选分段） | 选择模型 + 全选/反选 + 与 hover 操作列共存 |
| 异步进度对话框 | `DialogCenter` 只有同步「是/否」（`Components.swift:765`） | 需要「进行中 / 可取消 / 结果汇总」的新状态机 |

可全量复用的现成设施（零成本）：`ToastCenter`、`DialogCenter`、`TokenMenu`、`IconButton`、三种按钮样式、`SettingsRow`/`SettingsGroupCard`、`RemoteImage`、`APIClient.get/post/postEmpty/deleteEmpty`。

**插入点**：`MusicAlbumView.albumMenu`（`MusicAlbumView.swift:171`）、`TrackRowActions.overflowMenu`（`MediaComponents.swift:532`）、`MusicArtistView`、`SettingsView.libraryGroup`（`SettingsView.swift:213`）。

---

## 9. 必须先处理的前置问题

1. **`UserDto` 丢了 `Policy`**（`JellyfinModels.swift:20` 只解 `id` 和 `name`）。
   L3 的能力全是 admin 专属，客户端现在**判断不出当前用户是不是管理员**，会把 403 直接甩给用户。补 `policy.isAdministrator` + `policy.enableLyricManagement` —— **2 行改动，但是所有降级逻辑的前提**。

2. **不要往全量曲库查询里加字段**。
   `MusicDataStore` 一次拉全部曲目（`MusicDataStore.swift:213`），bulk 只请求 `Fields=Overview`，注释明确按「上万条曲库」做过优化。刮削需要的 `ProviderIds` / `Genres` / `Tags` / `Artists` **必须**像 `TrackInfoViewModel`（`TrackInfoView.swift:124`）那样按条目懒加载。

3. **单曲级 UI 要说清「改的是专辑」**。
   由 §1.1，服务端没有单曲刮削。界面上对单曲的刮削操作，语义上是「重新匹配它所属的专辑」，措辞要诚实。

---

## 10. 分阶段实施计划

### S1 · 歌词刮削（4–6 人日）—— **建议先做这个**
- 音源：lrclib（主，开放、无需 key）+ 网易云（备，带翻译与 credits）。
- 匹配：时长硬门槛（±10s 免费 / >30s 淘汰）+ 曲名/艺人归一化 + 简繁统一。
- 限流：全局串行 ~1 req/s，遵守 `Retry-After`（lrclib 实测会 503）。
- 落盘：`lyrics/<itemId>.lrc`。
- UI：在现有歌词面板（`NowPlayingView.swift` 的 `LyricsPane`）加「搜索歌词 / 换一份 / 保存到服务器」。
- 写回：`POST /Audio/{id}/Lyrics?fileName=x.lrc`；无权限时降级为仅本地。
- **验收**：找 10 首服务端无歌词的华语歌，≥8 首刮到并正确显示；有权限时写回后 Jellyfin 网页端也能看到。

### S2 · 封面 + 专辑元数据（5–8 人日，仅 L1）
- 音源：网易云专辑 `picUrl`（华语主源）；MusicBrainz/CAA + iTunes（罗马音）兜底。
- 落盘：`covers/<itemId>.jpg` + `overrides.json`。
- UI：专辑详情页显示「已用本地刮削数据」角标 + 一键还原。
- **验收**：重启后仍显示（证明真的落盘），断网也显示。

### S3 · 候选选择器 + 写回（5–8 人日）
- 引入第一个 sheet：候选卡片（封面/年份/曲目数/来源/匹配分）+ 差异预览 + 应用到服务器。
- 权限降级：非 admin 时按钮置灰并解释「需要管理员」。
- **验收**：非管理员账号下不出现可点的 403 按钮。

### S4 · 批量刮削（5–8 人日）
- 多选、队列、分 host 限流、可取消、失败汇总报告。

---

## 11. 风险清单（按严重度排序）

| # | 风险 | 缓解 |
|---|---|---|
| 1 | **非官方 CJK 接口随时失效** —— 酷狗旧 CDN 已死、网易云参考实现被归档，都是活证据 | 每个 Provider 隔离在 protocol 后 + 健康度统计；解析失败降级而非崩溃 |
| 2 | **ToS / 版权** —— 非官方源不提供任何授权 | 默认走 lrclib；非官方源做成可选；随包附免责声明（参照 Music Tag Web 的 24 小时条款） |
| 3 | **限流** —— MusicBrainz 1 req/s 是硬性契约、lrclib 突发 503、Last.fm 存储 100 MB 上限 | 全局串行队列 + 分 host 配额 + 指数退避 + 尊重 429/`Retry-After` |
| 4 | **写回覆盖服务端字段**（§1.3） | L3 强制差异预览 + 写入前 GET 完整 DTO + `LockedFields` |
| 5 | **简繁/别名匹配错配** | 时长硬门槛 + 低分不自动应用 + 候选选择器兜底 |

---

## 12. 待确认的决策

1. **是否接受非官方音源**（网易云/QQ/酷狗/咪咕）？只用 lrclib + MusicBrainz + CAA 的话合规性最好，但华语封面基本没戏（iTunes/Deezer 在中文输入下不可用）。
2. **默认走 L1（仅本地）还是 L2（写回服务器）**？写回价值高，但需要用户在服务端开权限。
3. **艺人简介是否要做**？（只能 L1，无写回端点；且 Last.fm 禁止存图）
4. **S1 是否直接开做**？

---

## 附：一次性回答最初的问题

> 「给应用添加歌曲刮削功能工作量大吗？」

**做成完整功能：4–6 周。但收益的大部分集中在第一条 4–6 天的歌词切片上。**

这个功能**不是重复造轮子**：服务端对单曲级刮削的支持是**零**（对管理员也是零），服务端音乐 Provider 实际只有 MusicBrainz 一家专辑源可用。客户端刮削补的是真实的能力空缺。

必须接受的设计现实是：**写回服务器基本都要管理员权限，所以「本地覆盖」必须是第一等公民，而不是降级方案。**
