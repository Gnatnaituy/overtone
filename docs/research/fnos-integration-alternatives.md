# 接入飞牛云 NAS 的备选路径评估

> **一句话结论**：把 Jellyfin 装到 fnOS 上，Overtone **零改代码**就能连上——这条路成立，工作量 ≈ 0 人日（只差一份用户安装指南 + 一次真机回归，约 0.5–1 人日）。
> 于是「接入飞牛云」的问题从「怎么实现私有协议」变成「**除了能让用户听歌，飞牛云还能带来什么产品价值**」，详见 §7。
>
> 调研时间 2026-10-28。证据等级：**V** = 本机可实测/源码直读，**S** = 一手页面/仓库静态文件，**A** = 第三方社区实测报道，**U** = 未核实。
> 相关文档：`docs/research/overtone-backend-coupling.md`（Overtone 后端耦合与「自研飞牛协议」工作量）。

---

## 0. 结论先行

| 问题 | 结论 | 证据 |
|---|---|---|
| fnOS 上能装 Jellyfin 吗？ | **能，而且有三条独立通道**：官方应用中心（应用墙已列 Jellyfin）、第三方 `.fpk`（`conversun/fnos-apps`，872★，2026-10-27 刚发 12.4-r1）、Docker Compose（社区教程验证）。三条互为兜底 | §2.1 |
| Overtone 能零改动连上吗？ | **能**。登录页有「协议 / 端口 / 客户端名」高级选项，端口任意填；Jellyfin 侧实现的是标准 API，Overtone 已适配 Jellyfin 12 的 `Authorization` 头 | §2.2 |
| 装好后要填的地址是什么？ | `http://<NAS-IP>:8097`（应用中心 / `.fpk` 版，`service_port=8097`）或 `http://<NAS-IP>:8096`（Docker 版）、或 Jellyfin 自己的 8096/8097/自定义端口。**不是** fnOS 面板的 5666/5667 | §2.2 |
| 飞牛音乐本身有没有通用协议可蹭？ | **没有**。它只暴露私有 `/music/api/v1` + `authx` 签名；DLNA/SMB/WebDAV 都是「文件级或只读」，没有收藏/进度/歌单的读写能力；**未发现任何 Subsonic 兼容层** | §3 |
| 改造成通用 Subsonic 客户端更省吗？ | 比自研飞牛协议省（约 18–24 人日 vs 约 30 人日），抗升级最好；但用户侧要另跑 Navidrome 并**重建一次曲库**，且 macOS 已有成熟 Subsonic 客户端，差异化被吃掉 | §4 |
| 推荐 | **① 立刻做：写「fnOS + Jellyfin」安装指南（0.5–1 人日，0 代码）**；**② 只有在产品战略明确要「飞牛音乐 macOS 原生客户端」这个定位时**，才投入约 30 人日做自研协议，且必须先建回归脚本 | §6、§7 |

---

> **Lead 复核补注（2026-10-28）：本文漏掉了一条真实存在的接入通道——「音桥」。**
> [qianlipp/fn-music-bridge](https://github.com/qianlipp/fn-music-bridge)（Go，AGPL-3.0，★7，2026-08 最后推送）是一个装进 fnOS 的 FPK 应用，把飞牛音乐翻译成 **Jellyfin Audio / OpenSubsonic / Audio Station / Ampache**，监听 `14040`。
> 这意味着本文 §0 的「飞牛音乐没有 Subsonic 兼容层」只对**官方**成立：第三方桥补上了这一层，且 Jellyfin 兼容面覆盖 Overtone 实际调用的绝大多数端点（已按源码逐条核对，见 `docs/fnos-integration-assessment.md` §2.0）。
> 因此「A 自研协议 30 人日 vs B 装 Jellyfin 0 人日」这个二选一**不完整**，中间还有一条「装音桥 → Overtone 零改动（¥0.5~1 人日）→ 与飞牛音乐同一份曲库」的路。限制：x86_64 only、fnOS ≥ 1.2.0300、第三方个人项目维护风险。

---

## 1. 方法与证据边界

- 本机**没有 fnOS NAS**，所有「装好后能否连通」的判断来自：① fnOS 官方站/帮助中心一手页面；② `.fpk` manifest 与打包脚本；③ 社区实测教程；④ **Overtone 源码直读**（这部分是 V 级，可完全确定）。
- 凡是「应用中心里 Jellyfin 的实际条目、版本、端口」这类需要真机点开的，文中一律标 **U（未核实）**，并给出可替代的第三方 `.fpk` / Docker 通道（这两条有静态证据，不依赖真机）。
- 本地只读参考仓库：`/tmp/fnresearch/{seasonyuu_FnMusic, XDORG-N1_FnMusic, javycoder_fnos_music_ext, naye1120_fnmusic-ps5, sscrl_open-fnmusic}`。

---

## 2. 基线方案：fnOS 上装 Jellyfin，Overtone 零改动

### 2.1 三条安装通道（互为兜底）

| 通道 | 证据 | 用户步骤 | 默认端口 | 用户耗时 | 风险 |
|---|---|---|---|---|---|
| **A. 官方应用中心**（首选） | fnOS 官网首页「应用中心，开箱即用」应用墙里**列了 Jellyfin**（图标 `static2.fnnas.com/official/app-icons/jellyfin.png`），同墙还有 Alist、AList小雅、Qbittorrent、DDNS-GO 等；旁边是「请求上架？立即申请」——说明这是一个**含第三方应用的商店 + 上架流程**，不是纯官方内置（[fnnas.com](https://fnnas.com/)） | fnOS 桌面 → 应用中心 → 搜 `Jellyfin` → 安装 → 打开 | **U（未核实）**，社区 `.fpk` 版是可对标的 8097 | 5–10 分钟 | 条目随地区/版本灰度，**未真机核实** |
| **B. 第三方 `.fpk` 手动安装** | [`conversun/fnos-apps`](https://github.com/conversun/fnos-apps) 872★/84 fork，175 款应用，每日同步上游；`apps/jellyfin/fnos/manifest` 明确 `service_port = 8097`（注意：main 分支 manifest 的 `version` 仍是 `10.11.6` 模板值，实际产物以 Release 为准）；Releases 最新为 `jellyfin_12.4-r1_{arm,x86}.fpk`（2026-10-27）；README 写明「访问地址 `http://<NAS-IP>:8097`」「fnOS 应用管理 → 手动安装 → 上传」 | 下载对应架构 `.fpk` → fnOS 应用中心 → 手动安装 | **8097** | 10–20 分钟 | 需选对 x86/arm；升级靠商店或手动 |
| **C. Docker Compose** | [fnOS 论坛实测贴](https://club.fnnas.com/forum.php?mod=viewthread&tid=23753)（2025-04）给出完整 `docker-compose.yml`：`jellyfin/jellyfin:latest`、`ports: 8096:8096`、挂载 `/vol1/1000/...` 到 `/media_resources`、`/dev/dri` 硬解 | 装 Docker → 粘贴 compose → `up -d` | **8096** | 30–60 分钟 | 卷权限、uid/gid、硬解设备、代理 |

> 旁证：fnOS 官方帮助中心有「应用中心」安装应用的说明语境（如 Seek 文档写「进入飞牛应用中心，搜索『飞牛素材库 Seek』安装后即可创建媒体素材库」，见 [fnnas.com/download 的 i18n 文案](https://fnnas.com/download)），以及 `fnos_music_ext` 的安装文档明确使用「应用中心 → 手动安装」装 `.fpk`（[README](https://github.com/javycoder/fnos_music_ext)）。
> **U**：官方应用中心里 Jellyfin 的具体版本与端口未能真机核实；但不影响结论——A 不成立就走 B/C，两者都有静态证据，且都是同一个 Jellyfin。

### 2.2 Overtone 零改动连通性（源码级证据）

| 关心点 | 源码事实 | 结论 |
|---|---|---|
| 能不能填非 8096 端口 | 登录页有「高级选项」：协议 `http/https`、端口输入框（占位文案「8096（留空用默认）」）、客户端名；地址由 `composedServer` 用 `协议 + 主机 + 端口` 拼装（`Sources/JellyfinMac/Views/LoginView.swift:17`、`:406`、`:443`、`:473`） | **8097/8096/任意端口都能连**，不需要改代码 |
| 地址带不带 scheme | 主机里已含 `://` 时以输入为准，否则用协议下拉框拼（`LoginView.swift:473-486`） | `http://192.168.1.10:8097` 或只填 `192.168.1.10` + 端口 `8097` 都行 |
| Jellyfin 12 兼容 | `APIClient.swift:74-85` 注释与实现：Jellyfin 12 起只认标准 `Authorization` 头 | 打包产物最新为 **12.4**（`jellyfin/v12.4-r1`），**版本对得上**；官方应用中心版版本未核实 |
| 请求面有多小 | 全项目用到 19 条 Jellyfin 路径（`/Users/AuthenticateByName`、`/Users/{id}/Items`、`/Audio/{id}/stream`、`/Playlists`、`/Sessions/Playing*` 等），`APIClient` 只有 15 个函数、239 行 | 通用实现，不依赖任何非标扩展 |
| 凭据 | 用户名/密码走 Jellyfin 自己的账号体系 + Keychain 记住会话 | 用户需在 Jellyfin 里**另建账号**（≠ fnOS 账号），这是唯一的「心理成本」 |

**用户实际需要填的东西**（建议原样写进指南）：

```text
服务器地址：192.168.1.10        （不要写 http://，也可写全）
协议：      http
端口：      8097                （应用中心/.fpk 版；Docker 版用 8096）
用户名/密码：Jellyfin 里创建的账号，不是 fnOS 登录账号
```

三个容易踩的坑：

1. **别填 5666/5667**——那是 fnOS 系统面板端口：官方文档《如何修改飞牛系统的端口？》写明「fnOS 从 V0.8.22 版本之后，默认端口修改为 HTTP 5666」（[help.fnnas.com](https://help.fnnas.com/zh-CN/articles/v1/settings/port-customization)）；HTTPS 5667 见社区 Flutter 客户端源码 `XDORG-N1_FnMusic/lib/app/services/feiniu/fn_models.dart:46-50` 的内置默认值。二者都不是 Jellyfin。
2. **端口冲突**：第三方商店里 Emby 也是 8096（[manifest](https://github.com/conversun/fnos-apps/blob/main/apps/emby/fnos/manifest)），所以 Jellyfin 打包方把它挪到了 8097。同装两个时按 8097 连 Jellyfin。
3. **HTTPS/自签证书**：Overtone 用 `URLSession` 默认信任系统根证书；若用户开了 fnOS「强制 HTTPS」或在前面挂了自签反代，需要在 macOS 钥匙串里信任该证书，否则连接失败。**U：未实测**，Docker/`.fpk` 直连 http 场景不存在该问题。

### 2.3 远程访问：FN Connect 帮不上忙

- fnOS 的 FN Connect 只代理**自家应用**：`https://fnos.net/{fnId}/music/` 是引导页，需要 `mode=relay` 握手后跳到真正的音乐服务；`{fnId}/music/api/...` 不会代理业务 API（`/tmp/fnresearch/seasonyuu_FnMusic/api.md` §3.2，V 级实测）。
- 结论：Jellyfin 的异地访问要靠 DDNS / 端口转发 / Tailscale / 反代，**吃不到 fnOS 自带内网穿透的便利**。这是基线方案最大的用户侧摩擦（但也是 Jellyfin 生态的常规做法，不算硬伤）。

### 2.4 基线方案的功能缺口（要如实写进指南）

Jellyfin 的音乐能力是「通」的，但和飞牛音乐不是一套数据：

| 能力 | Jellyfin 侧 | 说明 |
|---|---|---|
| 收藏 | ✅ Jellyfin 收藏 | 不会同步到飞牛音乐的红心 |
| 播放进度同步 | ✅ `/Sessions/Playing/Progress` | 只在 Jellyfin 账号内同步 |
| 歌单 | ✅ `/Playlists` 双向 | 飞牛音乐歌单不会过来 |
| 歌词 | ✅ `/Audio/{id}/Lyrics`（内嵌/插件） | 飞牛音乐的自动刮削歌词不会过来 |
| 转码 | ✅ 内置 jellyfin-ffmpeg（`.fpk` 已带硬解） | 音乐转码可用 |
| 曲库来源 | 只能指向本地磁盘/挂载卷 | **飞牛音乐的「聚合网盘 + 远程设备」能力做不到**（见 §7） |
| 刮削质量 | 中文流行/ACG 元数据一般 | 需额外配元数据插件或用 Overtone 的客户端补全（见 `docs/research/client-scraping-sources.md`） |

### 2.5 基线的量化结论

- **代码工作量：0 人日。** 不需要新增后端、不需要改 `APIClient`、不需要动 `PlaybackReporter`。
- **交付物：0.5–1 人日。** ① 一篇《在 fnOS 上安装 Jellyfin 并连接 Overtone》文档（含上面三条通道与端口表）；② 一次真机回归（登录、浏览、直连播放、转码播放、进度上报、歌单同步）；③ 最多再加一个「服务器地址预填/端口提示」的小优化（可选项，非必需）。
- **对用户的价值：15 分钟内让 Overtone 在飞牛 NAS 上跑起来**（前提是用户愿意在 NAS 上多养一个媒体服务）。

---

## 3. 飞牛音乐自身还暴露了什么通用协议？

| 协议/入口 | 是否真实存在 | 证据 | 对 Overtone 有用吗 |
|---|---|---|---|
| **私有 Web API** `/music/api/v1/*` | ✅ 存在且完整 | `api.md`（43 KB，V 级实测，41 PASS）+ `fnos_music_ext` 源码里 40+ 条可辨识的 `/music/api/v1/...` 路径 | 唯一能拿到「可写曲库」的入口，但无官方契约，见 §5 |
| **DLNA / UPnP** | ⚠️ 系统级服务存在 | 官方帮助文档《DLNA 支持的媒体文件格式》列出 **音频：mp3, flac, wma, m4a, aac, wav, ogg**、播放列表 `m3u/pls`（[help.fnnas.com](https://help.fnnas.com/zh-CN/articles/v1/file-service/dlna)） | ❌ 只读投屏协议，没有收藏/进度/歌单写；且**哪个应用把音乐库暴露成 DLNA 源、是否含飞牛音乐库：U 未核实** |
| **SMB / NFS / WebDAV** | ✅ 系统级文件共享 | 帮助中心「文件共享协议」分栏：SMB 3 多通道、WebDAV 挂载、NFS（[WebDAV](https://help.fnnas.com/zh-CN/articles/v1/file-service/webdav)、[SMB](https://help.fnnas.com/zh-CN/articles/v1/file-service/smb3-multichannel)） | ❌ 文件级，拿不到元数据/歌单/收藏 → 只能走「自建本地库」路线（§4.2） |
| **AList / OpenList 桥接** | ✅ 应用中心有 | fnOS 官网应用墙含「AList小雅」「Alist」；第三方商店 AList 端口 5246、OpenList 5244（[fnos-apps README](https://github.com/conversun/fnos-apps)） | ❌ AList 提供的是 WebDAV/目录列表（文件级），不提供音乐库语义 |
| **Subsonic / Airsonic 兼容层** | ❌ **未发现任何证据** | 私有 API 路径、`authx` 签名、Cookie/Token 体系都与 Subsonic 无关；`api.md` 全文未出现 Subsonic；社区扩展也是接管官方 Unix Socket 而非暴露 Subsonic | 想要 Subsonic 只能**另装 Navidrome**（§4.1） |

**结论**：飞牛音乐是**封闭的私有协议**，没有任何「可写 + 带元数据」的通用协议可以蹭。所谓「通用协议」在这台 NAS 上全部来自**第三方应用**（Navidrome 提供 Subsonic，AList 提供 WebDAV），不是飞牛音乐提供的。

---

## 4. 通用后端对比

### 4.1 Subsonic / Navidrome（把 Overtone 改成通用 Subsonic 客户端）

**Navidrome 在 fnOS 上完全可跑**：第三方商店有 `.fpk`，`version 0.60.3`、`service_port 4533`，manifest 描述「兼容 Subsonic/Airsonic API」（[manifest](https://github.com/conversun/fnos-apps/blob/main/apps/navidrome/fnos/manifest)）；官方文档亦自述「a lightweight Subsonic-API compatible server, that can be used with any Subsonic compatible client」（[navidrome.org](https://www.navidrome.org/docs/overview/)）；协议本身有公开规范（[subsonic.org/pages/api.jsp](https://www.subsonic.org/pages/api.jsp)，HTTP 200）。

**Overtone 改造量**（基于 `overtone-backend-coupling.md` 的度量口径：1 人日 = 6 小时有效编码）：

| 工作项 | 人日 | 说明 |
|---|---|---|
| 后端抽象层（`MusicBackend` 协议 + 领域模型 + 拆分 Jellyfin DTO） | 8–11 | 与「自研飞牛协议」方案**可复用同一层**，不是重复投入 |
| Subsonic 适配器：auth（`u`/`t`/`s`/`v`/`c`/`f=json`）、错误包络、`getArtists`/`getArtist`/`getAlbum`/`getAlbumList2`/`getRandomSongs`/`getSongsByGenre`/`search3`/`getPlaylists`/`getPlaylist`/`createPlaylist`/`updatePlaylist`/`star`/`unstar`/`getStarred2`/`scrobble`/`stream`/`getCoverArt`/`getLyrics`(或 OpenSubsonic `getLyricsBySongId`) | 7–11 | 规范稳定、无签名，比飞牛协议好写得多 |
| UI：登录页加「服务器类型」、能力降级（无转码/无歌词时隐藏入口） | 2–3 | |
| 测试与联调（Navidrome + 官方 demo） | 2–3 | |
| **合计（含抽象层）** | **18–24**（常见 ≈ 20） | 估算值，未做原型；若抽象层已随别的方案落地，增量 **8–14** |

**代价**：用户要在 NAS 上再跑一个 Navidrome、再建一次库（扫描/刮削由 Navidrome 自己做，与飞牛音乐曲库并行、互不同步）；且 macOS 上已有成熟 Subsonic 客户端（「音流」等第三方播放器覆盖 Android/iOS/**macOS**/Windows，属公开可检索事实，但未取得官方产品页，标记 **A/U**），Overtone 在这条赛道上**没有独占价值**。

### 4.2 纯本地 / WebDAV 自建库（Overtone 自己当服务器）

- Overtone 现状：**完全没有本地库能力**——全仓 `grep "WebDAV|SMB|scan|file://"` 无命中，播放地址全部来自服务器 URL（`MusicPlayerModel.swift:453-483`）。
- 要做就得新建：目录扫描、ID3/FLAC/APE 标签解析、封面提取、CUE 整轨、SQLite 库、`*.lrc` 读取、增量索引、文件夹监听……**25–40 人日**，而且从一开始就**没有**跨设备进度、多用户、服务端转码。
- 唯一优势：抗升级（不依赖任何 NAS API），并且能直接吃 SMB/WebDAV 共享（fnOS 这两种协议官方支持）。

### 4.3 Jellyfin 直连（现状）

- 保持不动就是「通用化到 Jellyfin 生态」，已经在跑，工作量 0。
- fnOS 只是「又多了一个能装 Jellyfin 的平台」，见 §2。

### 4.4 三者并排

| | Jellyfin 直连（现状） | + Subsonic 后端 | 自建本地/WebDAV 库 |
|---|---|---|---|
| 增量人日 | 0 | 18–24（复用抽象层后 8–14） | 25–40 |
| 用户要装的服务 | Jellyfin（fnOS 上 5–60 分钟） | Navidrome（fnOS 4533）+ 建库 | 无 |
| 曲库来源 | Jellyfin 媒体库 | Navidrome 曲库 | 直接读 NAS 共享 |
| 抗升级 | 高 | **最高**（公开规范 20 年） | 最高 |
| 独占价值 | 低（Jellyfin 生态竞品多） | 低（音流等已覆盖 macOS） | 中（离线/本地优先人群） |

---

## 5. 生态证据：客户端清单与协议成熟度

### 5.1 官方客户端形态

| 端 | 有没有 | 证据 |
|---|---|---|
| Web（NAS 内 `/music/`） | ✅ | `api.md` §3.1：`https://{nasHost}/music/` 即飞牛音乐 Web 客户端 |
| Android / iOS / 鸿蒙 | ✅ 三端同步上线（2026-09-16） | IT之家：[《飞牛独立音乐 App 正式发布，鸿蒙、iOS、安卓全平台同步上线》](https://www.ithome.com/1/003/244.htm)（2026/9/16 18:17）。功能：独立音乐账号（可脱离 NAS 账号）、中继/公网/P2P 自适应、Opus 转码、DSD/DTS、CUE、LRC、CarPlay、网盘+远程设备聚合、自动刮削 |
| macOS 桌面 | ❌ 官方没有 | 官方下载页只有「飞牛 App / 飞牛影视 / 飞牛 TV / 飞牛音乐（移动三端）/ 飞牛同步（含 macOS）」——[fnnas.com/download](https://fnnas.com/download)；**音乐没有官方桌面端**。⚠️ 但**第三方 macOS 客户端已存在**：`chenqi92/primuse`（猿音，★229，MIT，App Store 已上架）——见 Lead 复核补注 §5.4 |
| TV | ❌（TV 端是影视） | 同上 |
| 公开 API / OpenAPI 文档 | ❌ | 帮助中心 sitemap 的 104 条 URL 里**没有「飞牛音乐」章节**（只有影视/相册/文件/系统）——[sitemap](https://help.fnnas.com/sitemap.xml)；`api.md` 自述「不是飞牛官方 API 文档」；官方无开发者门户 |

### 5.2 非官方/第三方客户端与扩展（GitHub 实测，2026-10-28）

| 项目 | ★ | 最近推送 | 语言 | 形态 | 说明 |
|---|---:|---|---|---|---|
| [javycoder/fnos_music_ext](https://github.com/javycoder/fnos_music_ext) | 488 | 2026-10-27 | Python | fnOS 扩展（`.fpk`） | 接管官方音乐后端 **Unix Socket**，给本地库补在线音源；另有 5 个可检索到的二开/派生仓库（haonanren118 28★、Sanmmz 24★、superxyline 23★、ai2ku 6★、guizhouwudao 5★） |
| [kuilei0926/FeiNiuMusic](https://github.com/kuilei0926/FeiNiuMusic) | 283 | 2026-10-22 | Dart | Android 第三方客户端 | 「通过飞牛 NAS 自带的音乐服务 API」+ FN Connect 自动探测；DLNA 投屏、CUE、DSD 双引擎 |
| [kuilei0926/FnMusicEnhance](https://github.com/kuilei0926/FnMusicEnhance) | 61 | 2026-10-11 | Python | 服务端增强插件 | |
| [XDORG-N1/FnMusic](https://github.com/XDORG-N1/FnMusic) | 26 | 2026-08-30 | Dart/Flutter | Android 15+ | FN ID / FN Connect 登录，内网→公网→中继自动探测；双引擎回退转码；端口默认 5666/5667（`XDORG-N1_FnMusic/lib/app/services/feiniu/fn_models.dart`） |
| [Raduap/FN-Music-Apple](https://github.com/Raduap/FN-Music-Apple) | 16 | 2026-10-04 | JS | **Windows 桌面**客户端（Apple Music 风格） | 说明「桌面端」是真实需求，且社区已用逆向 API 做过一版 |
| [chashaochang/FNMusic_H](https://github.com/chashaochang/FNMusic_H) | 6 | 2026-08-18 | Shell | 鸿蒙版 | 社区鸿蒙客户端（与官方是否有关联：**U 未核实**） |
| [sscrl/open-fnmusic](https://github.com/sscrl/open-fnmusic) | 7 | 2026-09-13 | Kotlin | 独立音乐 App「飞鸟·轻音」 | **与 fnOS 协议无关**（自述「接口不公开」、已从仓库移除网络层），不要当作 fnOS 客户端证据 |
| [naye1120/fnmusic-ps5](https://github.com/naye1120/fnmusic-ps5) | 3 | 2026-10-07 | C++ | PS5 homebrew | 局域网连 fnOS 音乐库，8 个分类栏、歌词页、收藏 |
| [seasonyuu/FnMusic](https://github.com/seasonyuu/FnMusic) | 3 | 2026-09-29 | Kotlin | Android 非官方客户端 | 附带 **`api.md`**：最完整的逆向协议文档（43 KB / 15 节 / 41 PASS 实测） |

### 5.3 由生态反推的协议稳定性判断

**成熟度高**：至少 5 个独立语言/平台（Kotlin、Dart×2、JS、C++、Python）各自实现了同一套 `/music/api/v1`；`api.md` 记录 41 PASS / 0 FAIL 的写生命周期（收藏、歌单增删改、播放事件）；扩展生态用「接管 Unix Socket」这种更脏的手法也能活 → **端点本身相当稳定**。

**契约不存在**：没有官方 OpenAPI、没有版本兼容承诺；`authx` 签名依赖硬编码常量（`AUTHX_PREFIX`、`MUSIC_API_KEY`）**从当前 Web 静态包里提取**，升级即可能变；`api.md` §15 自己列了 5 条「不能视为稳定公共 API」的理由。

**量化推论**：若走自研协议，**每次飞牛音乐大版本升级的回归成本 1–3 人日**（跑 `verify_api.py` 只读探针 + 修签名/字段），且升不升级不由我们决定。这正是 `overtone-backend-coupling.md` 把「飞牛侧 API 可控性」列为最大风险的原因。

### 5.4 Lead 复核补注（2026-10-28）：macOS 不是空白，且已有 MIT 的 Swift 实现

本文与 `overtone-backend-coupling.md` 并行产出，因此我（Lead）在合并阶段补一条两者都没写进的**关键外部事实**：

| 项 | 内容 |
|---|---|
| 项目 | [chenqi92/primuse](https://github.com/chenqi92/primuse)（App Store 名「猿音 / Primuse」，★229，**MIT**，2026-10-27 仍在提交） |
| 形态 | macOS / iOS / tvOS 音乐 App，**App Store 已上架** |
| 已支持的源 | **飞牛音乐**、Jellyfin、Subsonic、Plex、Emby、SMB、WebDAV、网盘 |
| 现成资产（MIT，可对照/适配） | `PrimuseKit/.../FnMusicAPIProtocol.swift`(1,078 行，含 authx 的 Swift 实现与 FN Connect 解析)、`FnMusicLibraryClient.swift`(537)、`FnMusicServiceClient.swift`(924)、`FnMusicStreamResolver.swift`(381)、`FnMusicLyricSelection.swift`(209)、`Primuse/Services/Sources/FnMusicSource.swift`(767)，另加约 2,900 行测试 |

**对本文结论的两处修正**：

1. **§5.1 与 §7 里「macOS 是空白 / 独占位」的推论不成立**——桌面端「听飞牛音乐」已有人做，且是上架产品。Overtone 若走路径 A，卖点必须换成「更好的那一版」（v3 玻璃 / v4 纸墨、五档断点、1,809 行设计令牌的中文界面，以及 Jellyfin + 飞牛双源统一），而不是填补空白。
2. **路径 A 的工期与风险都要下调**：协议层不必从零写，有 ~4,900 行 MIT 生产代码 + 2,900 行测试可对照（尤其 `TVStreamResourceLoader` 这个 400+ 行的 AVPlayer 分片代理，正好覆盖本文 §5 提到的「authx 若强制」的最贵分支）。完整评估见 `docs/fnos-integration-assessment.md` §6。

---

## 6. 结论对比表

> 人日口径：1 人日 = 6 小时有效编码；区间 = 乐观–悲观，括号内为常见值。A 方案数字引用 `overtone-backend-coupling.md`（常见 32.5 人日含双后端，MVP 4.8 人日）。

| # | 路径 | 开发工作量（人日） | 用户侧安装成本 | 抗 fnOS/飞牛音乐升级 | 功能覆盖（收藏/进度/歌单/歌词/转码） | 推荐度 |
|---|---|---|---|---|---|---|
| **B** | **fnOS 装 Jellyfin → Overtone 零改动** | **0 代码**；+0.5–1 文档与回归 | 应用中心 5–10 min／`.fpk` 10–20 min／Docker 30–60 min；**需另建 Jellyfin 库与账号**；异地访问要 DDNS/Tailscale | **高**：Jellyfin 独立于 fnOS，升级不互相牵连；仅 `.fpk` 需随 fnOS 大版本重打包 | ✅/✅/✅/✅/✅（**但全部是 Jellyfin 侧数据，与飞牛音乐不互通**） | ⭐⭐⭐⭐⭐（本周就做） |
| **E** | 只写「fnOS + Jellyfin」用户指南（B 的子集，不含回归） | 0.5 | 同上 | — | — | ⭐⭐⭐⭐⭐（与 B 同批交付） |
| **A** | 自研飞牛音乐私有协议（含后端抽象层） | **30**（乐观 20 / 悲观 50）；MVP 一周 4–7 | 0（用户已有飞牛音乐，什么都不用装） | **低**：签名常量/字段/路径随官方 Web 包变化，每次升级 1–3 人日回归 | ✅/✅/✅/✅/✅（需自己实现，`api.md` 已验证可行） | ⭐⭐（仅当战略明确要做「飞牛音乐 macOS 客户端」） |
| **C** | 通用 Subsonic 后端（fnOS 装 Navidrome 4533） | **18–24**（常见 20；抽象层复用时增量 8–14） | 装 Navidrome 20–40 min + **重建一次曲库**；多一个常驻服务 | **最高**：Subsonic 规范稳定 20 年，Navidrome 独立容器 | ✅/✅/✅/⚠️（歌词需 OpenSubsonic 扩展）/✅（`maxBitRate`） | ⭐⭐⭐（多后端战略可做，作为「接入飞牛」的替代品不划算） |
| **D** | 纯本地 / WebDAV 自建库（Overtone 自己扫库） | **25–40** | 无（直接吃 SMB/WebDAV 共享） | **最高** | ⚠️ 本地收藏 / ❌ 无跨设备进度 / ⚠️ 本地歌单 / ✅ `.lrc` / ❌ 无转码 | ⭐（不推荐） |

**推荐排序与触发条件**

1. **先做 B/E（0–1 人日）**：这是本评估的**基准线**，也是唯一「今天就能交付」的路径。不写代码，写指南 + 真机回归。用户 15 分钟能在飞牛 NAS 上用上 Overtone。
2. **若产品目标 ≠「让用户在 NAS 上听歌」，而是「Overtone 成为飞牛音乐生态的一部分」，才做 A**：预算 30 人日、预留每次升级 1–3 人日回归，并且**先把 `api.md` 的验证脚本改造成 CI 回归**（否则第二次升级就会失联）。
3. **C 不建议作为「接入飞牛云」的答案**，只建议作为「多后端战略」的一步（抽象层与 A 共用，等于给未来买保险）。
4. **D 不推荐**：工程量最大、能力最少，且与「NAS 上已有成熟音乐服务」的现实背道而驰。

---

## 7. 那么「接入飞牛云」在产品层面还剩什么价值？

这是本评估真正的决策问题。如果「NAS 装 Jellyfin → Overtone 零改动」成立，那么路径 B 解决的是**功能**（用户能在 NAS 上听歌），路径 A 解决的是**定位**（Overtone 是飞牛音乐生态的 macOS 客户端）。两者的价值不重叠：

| 价值维度 | 路径 B（Jellyfin） | 路径 A（飞牛音乐协议） |
|---|---|---|
| 用户是否要再装一套服务 | **要**（Jellyfin + 另建库 + 另建账号） | 不要，开箱即用飞牛音乐 |
| 曲库/歌单/收藏/播放记录 | 在 Jellyfin 里，**与家人手机上的飞牛音乐不同步** | 与官方三端 App **同一份数据**，家庭多端一致 |
| 曲库来源 | 只能挂载本地磁盘 | 飞牛音乐支持**聚合 NAS 本地 + 网盘 + 远程设备**（IT之家：v1.0.1 功能说明），Jellyfin 做不到 |
| 刮削/歌词/封面 | 要用户自己配 Jellyfin 元数据 | 飞牛音乐自带自动刮削（官方宣称） |
| macOS 桌面端 | Jellyfin 生态已有跨平台客户端，Overtone 只是其中一个 | 官方未见飞牛音乐 macOS 桌面端（只有 Web + 移动三端 + 飞牛同步），但**第三方已有上架产品**（Primuse/猿音，见 §5.4）→ 不是空白，只能算「更好的那一版」 |
| 品牌叙事 | 「又一个小众 Jellyfin 客户端」 | 「飞牛音乐 macOS 原生客户端」——可直接对接飞牛用户社区（官方论坛/贴吧/FN Connect 用户） |

**所以推荐的产品判断**：

- 如果 Overtone 的定位是**「个人自用 / 技术演示」** → 走 B，0 人日，收工。
- 如果 Overtone 想**获取飞牛生态的用户**（这是「接入飞牛云」这句话背后真正的诉求）→ 必须走 A，因为它卖的是「不用装第二套服务、和手机上的飞牛音乐是同一份曲库」。**B 给不了这个价值**：用户装了 Jellyfin 之后，看到的仍然是另一个库。
- 折中能落地的顺序：**B（本周，0.5 人日）→ 观察用户反馈 → 若确有「不想装 Jellyfin」的声音，再投 A（30 人日）**。不要为了「接入飞牛云」这个命题直接跳到 A，因为 B 已经能证明需求是否存在。

---

## 8. 未核实清单（不要当结论用）

1. **官方应用中心里 Jellyfin 的实际条目**：版本、端口、是否所有地区/机型可见、是否需要 FYGO 授权——均无真机，**U**。官网首页应用墙 +「请求上架」流程只是强证据。
2. **fnOS 的 DLNA 服务到底暴露哪些内容**：官方只给了「支持的媒体文件格式」（含音频），没有说明开关位置、是否包含飞牛音乐曲库、是否包含封面/歌单；**U**。
3. **Jellyfin 12.4 在 fnOS `.fpk` 里的音乐库刮削实测效果**：未真机验证，**U**。
4. **自签证书 / fnOS 强制 HTTPS 下 Overtone 的连接表现**：未实测，**U**（预期需在钥匙串信任）。
5. **飞牛音乐签名常量的跨版本稳定性**：`api.md` 明确标注未验证；本文只能引用其自述风险。
6. 官方三端 App 中**鸿蒙版审核状态**（IT之家原文：鸿蒙客户端正在审核中）——2026-10-28 时点的实际状态未核实。

---

## 9. 证据索引

**fnOS / Jellyfin**
- fnOS 官网首页（应用中心应用墙含 Jellyfin、「请求上架」）— https://fnnas.com/
- fnOS 帮助中心（sitemap 104 条 URL，无飞牛音乐章节）— https://help.fnnas.com/ ；sitemap https://help.fnnas.com/sitemap.xml
- 默认端口 5666（V0.8.22 起）— https://help.fnnas.com/zh-CN/articles/v1/settings/port-customization
- DLNA 支持格式（含音频）— https://help.fnnas.com/zh-CN/articles/v1/file-service/dlna
- WebDAV / SMB3 — https://help.fnnas.com/zh-CN/articles/v1/file-service/webdav 、https://help.fnnas.com/zh-CN/articles/v1/file-service/smb3-multichannel
- 第三方应用商店（872★，175 款，Jellyfin 12.4 / Navidrome 0.60.3）— https://github.com/conversun/fnos-apps
- Jellyfin `.fpk` manifest（`service_port = 8097`）— https://github.com/conversun/fnos-apps/blob/main/apps/jellyfin/fnos/manifest
- Navidrome `.fpk` manifest（`service_port = 4533`，Subsonic 兼容）— https://github.com/conversun/fnos-apps/blob/main/apps/navidrome/fnos/manifest
- Docker Compose 实测（端口 8096）— https://club.fnnas.com/forum.php?mod=viewthread&tid=23753

**飞牛音乐**
- 官方发布（2026-09-16，三端、独立账号、Opus 转码、DSD/CUE、CarPlay、网盘聚合）— https://www.ithome.com/1/003/244.htm
- 独立应用上线前的演进（v1.10.2 加入音乐播放）— https://www.sohu.com/a/876556555_122004016
- 官方下载页（飞牛音乐分栏，无桌面端）— https://fnnas.com/download?key=music
- 非官方 Web API 文档（43 KB，41 PASS）— `/tmp/fnresearch/seasonyuu_FnMusic/api.md`；仓库 https://github.com/seasonyuu/FnMusic
- 官方应用扩展（接管 Unix Socket，暴露 `/music/api/v1` 全量路径）— https://github.com/javycoder/fnos_music_ext
- 第三方客户端清单 — https://github.com/kuilei0926/FeiNiuMusic （283★）、https://github.com/XDORG-N1/FnMusic （26★）、https://github.com/Raduap/FN-Music-Apple （16★，Windows）、https://github.com/chashaochang/FNMusic_H （鸿蒙）、https://github.com/naye1120/fnmusic-ps5 （PS5）

**Subsonic / 协议规范**
- Subsonic API — https://www.subsonic.org/pages/api.jsp
- OpenSubsonic — https://opensubsonic.netlify.app/
- Navidrome 自述 Subsonic 兼容 — https://www.navidrome.org/docs/overview/

**Overtone 源码（本仓库，V 级）**
- 登录页协议/端口/客户端名 — `Sources/JellyfinMac/Views/LoginView.swift:17`、`:406-446`、`:473-486`
- 地址拼接 — 同上 `:473`
- Jellyfin 12 `Authorization` 头适配 — `Sources/JellyfinMac/Networking/APIClient.swift:74-85`
- 请求面（19 条路径）— `grep -rhoE '"/[A-Za-z][^"]*"' Sources/JellyfinMac/`
- 后端耦合与多后端工作量 — `docs/research/overtone-backend-coupling.md`
