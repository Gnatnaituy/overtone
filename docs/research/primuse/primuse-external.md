# Primuse（猿音）外部公开资料调研

> 调研时间：2026-10-29。范围：官方网站、Mac/iOS App Store 文案与评论、GitHub 仓库与完整 CHANGELOG、GitHub Issues、V2EX 讨论、兄弟产品站点。
> 目的：核实 Primuse 的产品定位、真实深度与版本演进，用于 Overtone 的差距与差异化判断。所有结论均给出来源链接，无法证实的一律标注「未证实」。

---

## 1. 结论摘要

1. **它不是一个"播放器"，而是一个自带曲库管理能力的多源聚合客户端。** 官方定位是「一个音乐库，连接你的所有音乐」——把 NAS、云盘、本地文件、自托管音乐服务器和 Apple Music 汇入同一资料库（[官网](https://soundisle.com/zh-hans/)、[App Store](https://apps.apple.com/cn/app/id6761675450)）。
2. **最关键的结构性差异由开发者自己讲清楚了**："跟 Navidrome 之类的产品不太一样，是直接读取 nas 或者网盘上的音乐。优点是不需要额外部署一个服务，缺点是需要在 app 里面扫描音乐读取标签等，挺耗时间的。"（[V2EX 1216937](https://www.v2ex.com/t/1216937)）。**无服务端 + 端上扫描**是它所有优缺点（首扫慢、发热、耗电、需要标签回填）的根源。
3. **公开度极高，几乎没有信息盲区。** 仓库 MIT 开源、全部代码公开，CHANGELOG 逐版本逐条列出（1.0.0 → 1.12.2），README 把架构、音频管线、依赖、格式矩阵都写明了。这与多数独立 Mac 应用完全不同——**评估它不需要猜**。
4. **迭代速度是它真正的护城河。** 2026-03-28 首发，7 个月内做到 1.12.2（build 118），40+ 个版本，单版本 30–212 项改动，平均 2–4 天一个版本（[CHANGELOG](https://github.com/chenqi92/primuse/blob/main/Docs/CHANGELOG.md)）。这是单人全栈 + 高度流程化的产物，靠"功能宽度"竞争几乎没有胜算。
5. **AI 不是聊天机器人，是"可选增强层"。** 官方口径只有四项：语义曲库搜索、智能场景推荐、听歌识词、曲库以外的新歌；实际还承担 AI 歌单（按提示词选歌）、歌词/一句话翻译、简介补全、智能标签整理、生成文字稿、AI 人声分离。可自带服务商（含 Ollama 本地），也有带月度额度的"内置 AI"。
6. **真正的深度项在歌词与 KTV，不在 AI。** 逐行/逐字/译文/注音/对唱/和声、逐字打轴、字体与颜色、AMLL 社区人工打轴源、人声分离 + 升降调 + 耳返 + 麦克风打分 + iPhone 当 Apple TV 的麦克风——这套组合在同类产品中罕见。
7. **收费：功能本体免费，明确只在"皮肤与 AI"上收费**，且截至 1.12.1 **没有公开价目表**（详见 §7.4）。

---

## 2. 官方定位与功能宣称（带链接）

### 2.1 身份与页面

| 项 | 内容 | 来源 |
|---|---|---|
| App Store 名称 | Primuse-NAS、网盘、navidrome自托管播放器 | [App Store CN](https://apps.apple.com/cn/app/id6761675450) |
| 副标题 | 本地无损音乐、离线有声书与电台 | 同上 |
| 价格 / 评分 | 免费；4.7 分（89 个评分） | 同上 |
| 开发者 / 卖家 | 玉琴 孙；sellerUrl `primuse.welape.com` | 同上 |
| 上架 / 当前版本 | 2026-04-12 / 1.12.1（2026-10-25） | 同上 |
| 平台 | iPhone、iPad、Mac、Apple TV、Apple Watch；iOS 18+ / macOS 15+ / tvOS 17+ | 同上 + [README](https://github.com/chenqi92/primuse) |
| 官方站 | `soundisle.com`（品牌站，含 [更新日志](https://soundisle.com/updates/)） | 官网 |
| 开源仓库 | `github.com/chenqi92/primuse`，MIT，230★ / 40 fork / 22 open issues | [GitHub](https://github.com/chenqi92/primuse) |
| TestFlight | [testflight.apple.com/join/AjbPukaF](https://testflight.apple.com/join/AjbPukaF) | 官网 / README |
| 兄弟产品 | [Viozi](https://viozi.soundisle.com/)：同作者的视频版播放器，开发中，计划免费，页脚版权 `welape.com` | 站点 |

> 品牌线索：`welape` 是开发者自有域名（Viozi 页脚 `© 2026 welape.com`），`soundisle`（"声音之岛"）是品牌站，"Primuse"是产品名，"猿音"是中文名。任务背景里的「普瑞缪斯 / Pro Muse」**在所有官方站点与仓库中均未出现，未证实**。

### 2.2 音乐来源（官方汇总）

- **NAS**：Synology DSM / File Station、QNAP
- **协议**：SMB/CIFS、WebDAV、FTP/FTPS、SFTP、NFS、S3、UPnP/DLNA
- **音乐服务器**：Subsonic/OpenSubsonic、Navidrome、Airsonic、gonic、飞牛音乐、道理鱼、Songloft、群晖 Audio Station；**媒体服务器**：Jellyfin、Emby、Plex
- **云盘**：百度网盘、阿里云盘、115、123、天翼（1.9.4）、光鸭、Drime、InfiniCLOUD（1.11.4）、Google Drive、OneDrive、Dropbox
- **其他**：本地文件、Apple Music / MusicKit、iTunes 资料库、Audiobookshelf（有声书）、Ting Reader（TestFlight）、网络电台
- **明确不支持**：绿联 UGOS、飞牛 fnOS 的系统级文件 API——"仍在等待厂商提供稳定公开接口"，飞牛只做音乐服务直连（[README](https://github.com/chenqi92/primuse)）

### 2.3 AI 到底做什么（官方四项 + 实际范围）

官方"可选智能功能"只有四项：**语义曲库搜索、智能场景推荐、听歌识词、曲库以外的新歌**（[官网](https://soundisle.com/zh-hans/)）。CHANGELOG 展开的实际范围：

- **AI 歌单**：按提示词从最多 100 首候选中挑 25 首，重新生成会换一批（1.12.1）
- **相似歌曲 / 歌曲电台**：混入 Last.fm 相似歌曲与歌手的库内曲目，同专辑同歌手限量错开
- **歌词翻译**：默认走系统 Apple Translation（离线）；AI 翻译为可选，逐行落盘、失败保留已翻部分
- **简介补全**：专辑 / 艺人简介批量补全
- **智能标签整理**：修正曲名、艺人、专辑乱码与不规范写法
- **文字稿生成**：播客 / 有声书，本机离线识别 / 内置 AI / 自填 Google、阿里云百炼
- **AI 人声分离**：卡拉OK 用，本机模型（需较新系统）
- **听歌识词**：音频转写，上传音频需单独授权，可交内置 AI 或自备 Google 密钥

**架构取向**：多厂商可切换（每功能可单独选服务与模型）、支持本地 Ollama、设备专用凭据不走 CloudKit、明文连接仅限私网、可"完全不让 App 联网"。内置 AI 有月度额度 + 套餐 + 活动兑换码——说明它是**成本受控的增值层，不是产品内核**。

### 2.4 歌词 / 逐字 / KTV 深度（真正的长板）

- 读取：内嵌标签、Sidecar（`.lrc/.elrc/.lys/.yrc/.qrc/.vtt/.srt`）、ID3 SYLT、服务端歌词、AMLL TTML DB（社区人工打轴，常带翻译与对唱分声部，1.11.5 起默认开启）
- 显示：逐行 / 逐字、译文、注音、罗马音、对唱分左右、和声、点击跳转、手动浏览后自动跟随、多种换句动效、字体（内置 + 导入自有字体）、颜色渐变
- 编辑：整行 / 单字打轴、整体平移时间轴、回写 Sidecar 或嵌入音频、歌词海报 / 实况照片导出
- **KTV**：人声分离、主唱/对唱声部、升降调 ±6 半音、耳返（需有线耳机）、麦克风打分、录音、单句循环 + 放慢不变调、自动匹配曲库中的伴奏版并沿用原唱歌词、Apple TV 上画面 + iPhone 当麦克风

### 2.5 其余能力（与任务清单逐项对应）

| 能力域 | 官方/仓库口径 |
|---|---|
| 统计与年报 | 听歌统计、年度音乐报告、听歌排行领奖台、音乐性格；可读服务端统计（Navidrome）；小组件展示 |
| 离线 / 缓存 | 离线下载与自动缓存分开管理、可选缓存音质（无损转 AAC）、整源/整专辑/整歌单缓存可中断续传、有声书"始终保持离线" |
| 多设备同步 | CloudKit 分项同步（歌单/智能歌单/来源/凭据/历史/统计/设置/曲库快照）、家庭共享、Apple TV 扫码直传、WatchConnectivity |
| 缓存同步 | `CacheSync`：把本机已有音频缓存**直传另一台 Primuse 设备**（同 Wi-Fi） |
| Wi-Fi 传输 | `WiFiTransfer`：浏览器访问 + **六位访问码**，把文件传进 App 本地目录 |
| EQ / 音质 | 十段均衡器 + 预设 + 自定义预设、空间音频 / 头部跟踪、压缩限幅、混响、ReplayGain（曲目/专辑，M4A 与 Subsonic 服务端增益）、无缝播放、1–12s 交叉淡化、跳过首尾静音、采样率匹配、高保真直通 vs 音效链（直通下 EQ 禁用并给出切换引导）、Mac 独占外接 DAC、DSD（自动/PCM/DoP）、双解码路径（SFBAudioEngine + FFmpeg 8.1）、CUE 分轨、DTS/DTS-CD |
| 系统集成 | CarPlay（布局与歌词可自定义）、Siri / App Intents、Spotlight、多尺寸小组件、锁屏与灵动岛歌词、Live Activity、Apple Watch（1.12.2 起支持离线音乐）、AirPlay、DLNA 投送与接收、媒体键与自定义快捷键、Handoff |
| macOS 专属 | 迷你播放器 / 菜单栏播放器、桌面歌词浮窗（双行/单行/竖排/锁定/点击穿透）、歌词"上岛"、外接屏大封面大字歌词、独立刮削窗口 |

---

## 3. 版本演进时间线

来源：[Docs/CHANGELOG.md](https://github.com/chenqi92/primuse/blob/main/Docs/CHANGELOG.md)、[官网更新日志](https://soundisle.com/updates/)、[iTunes Lookup](https://itunes.apple.com/lookup?bundleId=com.welape.yuanyin&country=cn)

| 日期 | 版本 | 节点 |
|---|---|---|
| 2026-03-28 | 1.0.0 | iPhone/iPad 首发；SFBAudioEngine 播放引擎、多源资料库、刮削、CarPlay |
| 2026-04 | 1.0.1 / macOS 1.0.0 | 均衡器；**macOS 端独立首发**（桌面歌词、菜单栏、三栏界面） |
| 2026-05-01 | 1.1.0 | 百度/Dropbox/阿里云盘/WebDAV/FTP；**自定义刮削源**（JSON 配置） |
| 2026-05-03 | 1.1.1 | CloudKit 同步基础设施 |
| 2026-05-05 | 1.2.0 | Range 边下边播、元数据回填、**歌词离线翻译**、Last.fm/ListenBrainz、听歌统计、重复检测、逐字扫光 |
| 2026-05-10 | 1.3.0 | Apple Watch App、智能歌单、**年度音乐报告** |
| 2026-05-18 | 1.3.1 | Siri/快捷指令、小组件、Handoff、标签编辑器、VoiceOver |
| 2026-05-22 | 1.3.2 | 变速、Hi-Res 徽章、空间音频、拼音与歌词搜索、离线下载、ReplayGain |
| 2026-05-23 | 1.4.0 / 1.5.0 | Apple Music 集成；DLNA Controller、家庭共享、macOS 改版 |
| 2026-06-06 | 1.6.0 | **Apple TV 端加入**；115/123 网盘 |
| 2026-07-18→26 | 1.7.x | 首页模块自定义、混合来源队列、跨源真实删除、持久化搜索索引 |
| 2026-07-28 | 1.8.0 | **CUE 分轨 + DTS + FFmpeg 高保真解码链路** |
| 2026-08-02→06 | 1.8.1–1.8.3 | 道理鱼 / 飞牛音乐源、沉浸歌词、歌词编辑、网络电台、STRM |
| 2026-08-10→14 | 1.9.0–1.9.1 | 多语言界面、Siri 点播、服务端歌单镜像、文件夹浏览 |
| 2026-08-26 | 1.9.2 | **逐字打轴**、三端统一沉浸播放、**智能服务 + 语义搜索** |
| 2026-08-31 | 1.9.3 | 多厂商智能服务、**内置 AI**、智能推荐、音频转写、服务端统计 |
| 2026-09-03/06 | 1.9.4 / 1.9.5 | 端到端加密分享、Smart Mix 节拍过渡、天翼云盘；设备互传 + 网页管理、Songloft |
| 2026-09-21→29 | 1.9.8 / 1.10.x | 有声书与 m4b、Apple TV 电台、音乐源体检、**卡拉OK**、串烧、歌单跨平台导入 |
| 2026-10-03→06 | 1.11.1–1.11.3 | **播客（RSS + Apple 播客目录）**、Audiobookshelf、情景推荐、GBK/Big5 歌词 |
| 2026-10-15/17 | 1.11.4 / 1.11.5 | InfiniCLOUD、Ting Reader、统一限流体系；**AMLL TTML DB 歌词源** |
| 2026-10-18 | 1.12.0 | 全屏动效强度、进度条发光、诊断报告直传 |
| 2026-10-25 | 1.12.1 | 212 项改动：**动态歌词**、pCloud、升/降调 ±6 半音、播放页一键换版式、Spotlight、字体导入 |
| 2026-10-28 | 1.12.2 | 80 项：Watch 离线音乐、有声书跳过片头片尾、歌词来源标注、CarPlay 首页内容可配置 |

**节奏观察**：7 个月 40+ 版本；1.12.1 单版本 212 项改动；版本说明由 CI 从 commit 自动汇总再人工整理。**App Store 线上仍是 1.12.1**，1.12.2 尚在 TestFlight/审核中——说明本地安装的 1.12.1 是当前正式版。

---

## 4. 评测与用户反馈

### 4.1 评分面

App Store 4.7 分（89 个评分），对一款免费、无推广预算的独立应用属高分（[App Store](https://apps.apple.com/cn/app/id6761675450)）。GitHub 230★ / 22 open issues，issue 区活跃，开发者逐条回复（很多 issue 在被提当天/次日修完）。

### 4.2 正面反馈（App Store 评论原文）

- "真免费、高保真直通、导入本地和网络文件、刮削编辑元数据、各种自定义、强大而易用，恰好都是我想要的"
- "终于有了一个适合听有声书的音乐播放器，功能很全很强大"
- 用户主动提出付费意愿："什么时候收费？我需要提前知晓，希望能抢到早鸟价"（开发者回复见 §5）
- GitHub issue 里出现极端正向情绪："没想到能一项项根据建议调整优化，实在是感激涕零"——反映**开发者-用户反馈闭环非常短**，这本身是产品力的一部分。

### 4.3 已知槽点（按来源分）

**App Store 评论（含开发者回复）**
- CarPlay 接电话时**实体按键不能切歌**，8 英寸车机界面未适配（开发者：前者是车机限制，后者下版改）
- 24bit 歌曲抛异常无法播放（开发者：未复现，24bit 默认支持）
- **倍速在 0.8–2.0 都是原速**（开发者承认：高保真下无法调速，准备直接禁用）
- 本地导入 200–300 首时闪退，需分多次导入，残留半成品文件；专辑封面不显示（早期版本）
- **Apple TV 端明显不成熟**（开发者自认"测得比较少"）；刮削准确率不可控且耗电，即使关掉刮削源；希望批量改标签、内建反馈入口

**GitHub Issues（近期）**
- Spotlight 索引不生效（[#346](https://github.com/chenqi92/primuse/issues/346)，13 条讨论）
- Navidrome 专辑曲数 / "最近添加"排序与服务端不一致（[#372](https://github.com/chenqi92/primuse/issues/372)）——**第三方服务器语义对齐是它持续踩的坑**
- 倍速播放声音失真（[#366](https://github.com/chenqi92/primuse/issues/366)）；4–10GB 大视频/播客容器扫描反复失败（[#371](https://github.com/chenqi92/primuse/issues/371)）
- 播客封面点击动画掉帧、长文字稿发热（[#345](https://github.com/chenqi92/primuse/issues/345)、[#349](https://github.com/chenqi92/primuse/issues/349)）；Mac 窗口缩放到某些尺寸时右上角图标重叠（[#350](https://github.com/chenqi92/primuse/issues/350)）
- 歌单缺自动排序（[#344](https://github.com/chenqi92/primuse/issues/344)）；用户明确在催 Apple Watch 离线播放（[#368](https://github.com/chenqi92/primuse/issues/368)，1.12.2 已加）

**开发者自述（V2EX 1209606，2026-04-30，同作者的 my-nas 项目）**
> "主打的就是功能多，bug 多。……现在状态是能用但不易用，功能多但界面丑。"
这句话是理解该产品的钥匙：**宽度换深度**，并持续用高频迭代偿还质量债。

### 4.4 一个敏感点：自定义刮削源与合规

开发者在 V2EX 明说音乐刮削"需要导入 json 实现规避版权问题，可以留邮箱"（[V2EX 1209606](https://www.v2ex.com/t/1209606)）。也就是说，**「导入刮削源」这一被官方文档正面宣传的能力（支持 JS 解析、Cookie、TLS 信任域），在设计上同时承担规避内容合规风险的职能**。这解释了它为什么把这部分做成可插拔、可导入、默认只有 Apple Music/MusicBrainz/LRCLIB 三个"干净"源。

---

## 5. 本地字符串 vs 官方口径核对

> 抽样方法：本地 `/Applications/Primuse.app`（1.12.1）的 `zh-Hans.lproj` 9 个 `.strings` 转 UTF-8 后按域 grep（`Localizable` 6966 行、`CarPlay` 164 处、`podcast` 178 处、`eq_` 32 处、`crossfade` 12 处、`gapless` 7 处、`dsd` 7 处）。全量清单见同目录 `primuse-feature-inventory.md`（task-1）。

| 能力 | 官方口径 | 本地字符串证据 | 判定 |
|---|---|---|---|
| 年度报告 | "年度音乐报告" | `yearly_report_title` = "年度音乐报告"；`yearly_report_entry_title` = "%d 年度音乐报告" | **两者一致** |
| 语义搜索 / AI 歌单 | "语义曲库搜索""智能场景推荐" | `ai_enable_semantic_search` = "语义曲库搜索"；`ai_recommendation_intent_prompt_label` = "AI 提示词" | **一致，且字符串更细**（暴露"提示词作为自定义方向"的实现） |
| 卡拉OK / 人声分离 | "卡拉OK""AI 人声分离" | `karaoke_title`、`karaoke_ai_title` = "AI 人声分离"、`karaoke_part_secondary` = "对唱"、`karaoke_monitor` = "耳返" | **一致** |
| 耳返限制 | 官方未说明 | `karaoke_monitor_needs_wired` = "戴耳机唱评分更准；耳返需要有线耳机" | **仅字符串可见**（实现约束） |
| 逐字歌词源 | "AMLL TTML DB 歌词源" | `scraper_amll_desc` = "社区人工打轴的逐字歌词，常带翻译"；`scraper_sources_footer` 说明"歌词不是逐字时会再问后面最多两个源" | **一致，字符串给出优先级策略** |
| Wi-Fi 传输 | "局域网内传送歌曲与文件夹" | `WiFiTransfer`：`"title"` = "Wi-Fi 传输"、`"subtitle"` = "通过浏览器将音乐传入 Primuse"、`"codeHint"` = "输入 Primuse 中显示的六位访问码" | **一致但官方严重弱化**：实际是浏览器 + 六位码，不是设备间 AirDrop 式传输 |
| 缓存同步 | 仅"缓存同步"四字 | `cache_sync_subtitle` = "将已有音频缓存直接发送到另一台 Primuse 设备"，含"同一 Wi-Fi 或有线网络""可被发现" | **仅字符串可见**（官方四字未解释语义） |
| Apple TV 当麦克风 | "为 Apple TV 当麦克风" | `karaoke_tv_scan_hint` = "用相机扫码。iPhone 负责打分，歌声不经电视播放" | **一致** |
| 诊断上传 | "诊断可直接上传并取得报告编号" | 上传地址为 **Palveni**（CHANGELOG：「诊断报告可以直接传到 Palveni：构建里带了上传密钥就不再经过内置 AI 的中转」） | **官方未提 Palveni**，属实现细节外泄 |
| 播客自动下载 | "自动下载新单集" | `AppShortcuts` 仅 3 处 podcast；`Localizable` 有 178 处 podcast 域 | **一致**（未见反例） |

**结论**：在这批抽样项上，**没有发现"官方宣称而字符串不存在"的情况** —— 这与它完全开源、文档由同一份代码库生成有关，罕见地不存在"宣传泡沫"。反向的缺口更多是**官方文案弱化了实现细节**（Wi-Fi 传输的真实形态、缓存同步的真实语义、耳返的硬件前置条件、Palveni 的中转角色）。

---

## 6. 对 Overtone 的差异化启示

### 6.1 最大的机会：结构性地反打"无服务端"

Primuse 的核心取舍是"不需要部署服务端"，代价是端上扫描、标签读取、回填、发热与耗电——它的 CHANGELOG 里有一大半篇幅在为此还债（"减少重复同步""不再每批重写整个曲库""后台读标签不再发热"）。

Overtone 是真·服务端客户端（Jellyfin / 飞牛），理应用**相反的话术**：
- 「打开就能听，不用先扫一遍库」
- 「曲库变更由服务端负责，客户端只管播」
- 「多用户 / 多库 / 播放上报 / 转码策略交给服务器」

**不要**去补曲库管理（刮削、标签写回、去重、网盘直连、本地扫描）——那是曲库管理器的职责，硬做会把 Overtone 拖进同样的性能债。

### 6.2 功能宽度不是可竞争维度

对手是单人全栈 + 高度自动化的 7 个月 40 版本节奏，覆盖 CarPlay / Watch / tvOS / KTV / AI / 有声书 / 播客 / 电台。**在这个维度上跟跑必输**。应转向"少而深"：
- Jellyfin 原生语义的深度（播放上报、转码/直连策略、多用户与多库切换、服务器端搜索与排序准确性）
- macOS 桌面体验（窗口/菜单栏/桌面歌词/快捷键/Spotlight/多屏）
- 稳定性与性能（Primuse 的 public issue 里大量是卡顿与掉帧，这恰是设计驱动产品的空档）

### 6.3 值得低成本借用的具体点（按性价比排序）

1. **播放页样式可配置**：铺满封面 / 简洁预设 / 一键套用与恢复、按钮图标样式、进度条发光——纯 UI 投入，感知极强
2. **听歌统计 + 年度报告**：低成本高传播，Primuse 从 1.3.0 就有，且年年重做
3. **睡眠定时面板**：自定义时长 + 指定时刻停止 + "到点先播完当前这首"
4. **歌词细节**：字体选择、歌词来源标注、译文/罗马音、逐字高亮、歌词海报导出（无水印）
5. **播放微观体验**：跳过首尾静音、交叉淡化时长、"下一首播放"去重、"上一首先回到开头"开关、随机播放偏好（常听/少听优先）；以及升/降调 ±6 半音（若音频链路允许）与 EQ 预设导入导出
6. **音乐源健康检查**："音乐源体检"逐项探测端口/TLS/路径——对配置 Jellyfin/fnOS 的用户极实用

### 6.4 同类 Jellyfin 客户端格局（简短）

- **Finamp**（Flutter，Android/iOS/桌面）：离线下载 + 转码流播 + ReplayGain(Jellyfin 10.9+) + 歌词 + 无缝播放 + Playback Reporting；**CarPlay 尚未支持**，元数据编辑、多用户/多服务器仍在 planned（[jmshrv/finamp](https://github.com/jmshrv/finamp)）
- **Streamyfin**、**Feishin**、**swiftly-player**（★34）、**JellyJams**、**dionysus-player** 等：多为"播放器"定位，桌面原生做工与视觉设计普遍是短板
- 结论：**Jellyfin 生态里"原生 macOS + 设计驱动 + 桌面深度"仍是空档**，这与 Overtone 的既有取向一致；风险不在竞品，而在 Finamp 这类开源项目对"免费 + 够用"的心理锚定

### 6.5 一句话定位建议

> 不承诺"一个库连所有来源"，而承诺"**你已有的 Jellyfin / 飞牛库，在 Mac 上最好的一次体验**"。

---

## 7. 检索范围、命中情况与不确定性

### 7.1 检索方式（如实说明）

`web_search` 工具后端返回 401（认证失败）不可用，故改用：iTunes Lookup API、App Store 网页、官网抓取、GitHub REST API（repo / issues / search）、V2EX API（sov2ex 全站搜索 + topics/show）、DuckDuckGo HTML（后期触发人机验证）、Bing（中文结果质量差、返回无关内容）。**独立第三方深度评测未能检索到**——这属于检索通道受限，不完全等于"不存在"。

### 7.2 命中情况

- **官方一手资料：极充分**（App Store 全文案与 1.12.1 完整 release notes、官网全站、README、40+ 版本 CHANGELOG、issue 区、开发者自荐帖）
- **第三方独立评测：几乎为零**。V2EX 全站仅 4 条命中，其中 3 条是开发者本人自荐（[1209606](https://www.v2ex.com/t/1209606)、[1209255](https://www.v2ex.com/t/1209255)、[1216937](https://www.v2ex.com/t/1216937)），1 条弱相关（1202088）。未检索到少数派 / 知乎 / B站 / Reddit 的成篇评测
- **运营方式推断**：靠 V2EX 自荐 + App Store 自然流量 + 微信群（Palveni）+ Telegram + TestFlight 公测，**没有媒体投放**
- **Overtone 公开信息**：GitHub 仓库搜索（`overtone+language:Swift`、`jellyfin+macos+swiftui`）未找到本项目的公开仓库或页面；同名仓库 `utkarsh-n/Overtone` 是 iOS 钢琴教学 App，`Gnatnaituy/overtone` 是另一个 macOS Jellyfin 客户端，均非本项目。→ **Overtone 目前是私有/未公开项目，没有任何公开竞品讨论可引用**

### 7.3 缺乏公开来源、需标注不确定的说法

| 说法 | 状态 |
|---|---|
| 订阅 / 买断的具体价格与档位 | **无公开来源**。开发者仅在 App Store 评论回复中给原则（见下），App Store 内购页因 JS 渲染未能抓取。**不要在内部文档中引用任何具体金额** |
| "普瑞缪斯 / Pro Muse" 等旧名 | **未证实**。官方所有渠道均只出现 Primuse / 猿音 |
| 内置 AI 的额度数值、模型清单、套餐层级 | **未见公开文档**；仅有"本月次数""套餐""兑换码"的行为性描述 |
| 用户规模 / 下载量 | **无公开数据**（仅 89 个评分可作弱代理） |
| 1.12.2 是否已过审上架 | **未知**：App Store 线上为 1.12.1（2026-10-25），CHANGELOG 已列 1.12.2（2026-10-28） |
| 第三方评测中的口碑结论 | **无样本**，§4 的结论全部来自 App Store 评论 + GitHub Issues，样本偏向"活跃用户" |

### 7.4 关于收费的唯一一手表述

开发者在 App Store 评论区的公开回复（原文）：

> "功能不会收费哦，收费点只会在后续的皮肤和ai功能，皮肤不一定会出，ai功能是因为我也要花钱😂"

即：**功能本体免费，皮肤与 AI 是唯二预期收费点**，皮肤甚至可能不做。这与"内置 AI 有月度额度与兑换码"的机制互相印证。
