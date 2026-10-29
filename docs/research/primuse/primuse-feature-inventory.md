# Primuse（猿音）功能清单 · 只读逆向挖掘

> **目的**：从本机已安装的 `/Applications/Primuse.app` 只读提取「用户可见能力」全貌，供与 Overtone 做差距对比。
> **方法**：`zh-Hans.lproj` / `en.lproj` 的 9 类 `.strings`（UTF-16LE → UTF-8，转到 `/tmp/primuse-research/`）逐域通读 + `Resources/EQPresets.json` + `Frameworks/` + `Info.plist` + entitlements + `codesign` + 主二进制 `strings` + 扩展（Widget / Karaoke 模型下载器）。
> **口径**：每条能力都给 1–3 条中文 key + 原文作证据，并注明出处文件/段落。**未在资源或二进制中找到佐证的一律标「未确认」**，不做推测性补全。
> **约束**：全程只读；未修改 `/Applications/Primuse.app`，未修改 Overtone 源码。

---

## 0. 一句话定位

**Primuse（中文名「猿音」，旧名「普瑞缪斯」，`com.welape.yuanyin` v1.12.1）是一个「本地/NAS/云盘多源聚合 + 发烧级音频管线 + AI 增强」的重量级原生 macOS 音乐播放器**，不是流媒体客户端：它自己就是曲库管理器（扫描、刮削、标签写回、去重、缓存、局域网互传），并且把播放器本身做成了可定制的作品（10 段 EQ、高保真直通、DSD/独占输出、逐字歌词、卡拉OK、全屏视觉化、年度报告）。

---

## 1. 信息来源与硬证据

### 1.1 版本与包结构

| 项 | 值 | 来源 |
|---|---|---|
| Bundle ID / 版本 | `com.welape.yuanyin` / `1.12.1`（build 115） | `Contents/Info.plist` |
| 最低系统 | macOS 15.0 | `LSMinimumSystemVersion` |
| Siri 别名 | 「猿音」「普瑞缪斯」「Pro Muse」 | `INAlternativeAppNames` |
| 类别 | `public.app-category.music` | `LSApplicationCategoryType` |
| 主二进制 | 137.6 MB（Swift，单一可执行） | `Contents/MacOS/Primuse` |
| App 扩展 | `PrimuseWidgetExtension.appex`（`com.apple.widgetkit-extension`）、`PrimuseKaraokeModelDownloader.appex`（`com.apple.background-asset-downloader-extension`） | `Contents/PlugIns`、`Contents/Extensions` |
| 本地化 | **16 个 `.lproj`**（zh-Hans / zh-Hant / ja / ko / ar / th / tr / ru / uk / pl / fr / de / es-MX / pt-BR / hi / en） | `Contents/Resources` |

### 1.2 字符串规模（功能广度的量化指标）

| 文件 | key 数 | 说明 |
|---|---|---|
| `Localizable.strings` | **6627** | 主体功能面 |
| `WiFiTransfer.strings` | 155 | 浏览器/局域网互传 |
| `SettingsSearch.strings` | 74 | 设置项搜索 + Shortcuts 设置动作 |
| `CacheSync.strings` | 69 | 多设备缓存同步 |
| `AppShortcuts.strings` | 48 条（plist） | Siri/快捷指令短语 |
| `HomeDiscovery.strings` | 35 | 首页发现（目录收藏 / 听歌排行） |
| `PlayMedia.strings` | 30 | App Intents 播放媒体实体 |
| `MetadataReading.strings` | 15 | 标签读取速度档位 |
| `InfoPlist.strings` | 7 | 权限用途说明（**信息量很大**，见 1.4） |

`Localizable` 前 40 个一级前缀（实测 `grep -o '^"[a-z0-9_]*"'` 归一）：

```
ai 409 · lyrics 371 · player 264 · library 216 · source 200 · transcript 199
playlist 171 · carplay 160 · radio 153 · podcast 149 · stats 141 · tag 120
smart 119 · home 114 · server 106 · karaoke 102 · yearly 101 · metadata 95
spoken 84 · listening 84 · lyric 73 · tv 70 · relay 69 · scrobble 68
immersive 67 · onboarding 65 · local 61 · search 58 · baidu 56 · cloud 51
scrape 50 · apple 47 · album 47 · playback 46 · intent 45 · fullscreen 45
diagnostics 45 · batch 45 · dup 44 · scraper 41 · offline 41 · sleep 36 · theme 35
```

二级前缀里信号最强的几个：`playlist_import 119`、`transcript_reader 94`、`source_diag 86`、`library_insight 86`、`spoken_word 84`、`lyrics_translation 82`、`player_controls 78`、`tag_editor 76`、`lyrics_editor 74`、`transcript_generation 73`、`lyric_poster 73`、`metadata_status 65`、`ai_recommendation 63`、`lyrics_romanization 61`。

### 1.3 音频/网络底层框架（18 个）

`Contents/Frameworks/`：

- **解码**：`libavcodec` / `libavformat` / `libavutil` / `libswresample`（FFmpeg 全家桶）、`FLAC`、`mpg123`（MP3）、`mpc`（Musepack）、`ogg`、`opus`、`vorbis`、`wavpack`、`tta-cpp`（TTA）、`sndfile`（libsndfile）、`lame`（MP3 编码）
- **基础设施**：`GRDB-dynamic`（SQLite ORM）、`AMSMB2`（SMB/CIFS 客户端）、`PrimuseKit`（自有模块）、`libswiftCompatibilitySpan.dylib`

> **含义**：这不是「AVPlayer 套壳」。自带 FFmpeg + 一堆独立解码器，说明要覆盖 AVFoundation 不支持的格式（APE/WMA/DSD/TTA/MPC/WavPack 等），并能**重编码**（lame、libswresample）——这是卡拉OK 人声消除、串烧、片段导出、DoP 封装的技术前提。

### 1.4 权限与 entitlements（透露了功能边界）

`InfoPlist.strings` 的权限用途说明是全仓库信息密度最高的 7 行：

| Key | 原文 |
|---|---|
| `NSLocalNetworkUsageDescription` | 「Primuse 需要访问本地网络以发现和连接您的 NAS 设备、媒体服务器及其他音乐源。」 |
| `NSMicrophoneUsageDescription` | 「Primuse 在卡拉OK模式下使用麦克风为你的演唱打分、在耳机中播放你的声音，并在本机录下你的演唱。」 |
| `NSMotionUsageDescription` | 「Primuse 会使用支持的耳机运动数据，让空间音频在您转动头部时保持稳定定位。」 |
| `NSSpeechRecognitionUsageDescription` | 「Primuse 使用本机语音识别为播客单集和有声书生成文稿，音频不会离开这台设备。」 |
| `NSAppleMusicUsageDescription` | 「…以将本机音乐导入为播放源。」 |
| `NSSiriUsageDescription` | 「用 Siri 语音点播、控制 Primuse 播放。」 |

Entitlements（`codesign -d --entitlements`）：App Sandbox = true；`network.client` + `network.server`；`com.apple.developer.networking.multicast`（Bonjour 多播）；`device.audio-input`；`assets.music.read-only`；`files.user-selected.read-write` + `files.bookmarks.app-scope`（沙盒外文件夹持久授权）；`aps-environment=production`（推送）；**iCloud CloudKit**（`iCloud.com.welape.yuanyin`）+ `ubiquity-kvstore`；`keychain-access-groups` + `application-groups group.com.welape.yuanyin`。

Bonjour 声明（`NSBonjourServices`，12 项）直接泄漏了协议支持面：

```
_primuse-xfer._tcp  _primuse-cache._tcp  _smb._tcp  _webdav._tcp  _webdavs._tcp
_ftp._tcp  _sftp-ssh._tcp  _nfs._tcp  _diskstation._tcp  _synology-dsm._tcp
_http._tcp  _https._tcp
```

此外 `NSAppTransportSecurity.NSAllowsArbitraryLoads = true`（允许明文 HTTP，用于局域网 NAS）；`BAHasManagedAssetPacks = true`（卡拉OK AI 模型走 Background Assets 按需下载）。

### 1.5 一个重要前提：字符串表是**多平台共享**的

macOS 包内出现大量明显属于 iOS/iPadOS/tvOS 的文案，例如：

- `player_landscape_fullscreen_title` = 「横屏时进入全屏 / 在播放页把手机横过来」、`player_orientation_button_title`、`player_controls_duo_footer`（「iPhone Duo 的侧边竖栏」）
- `carplay_*`（160 条）、`tv_*`（70 条，含 `tv_remote_siri`、`tv_output_sr_matching_desc` = 「需 tvOS 27 与 Apple TV 4K」）
- `karaoke_tv_*`（「用 iPhone 当麦克风」）、`settings_relay_*`（「允许 Apple TV 经本机播放」）

**结论与限制**：这套 `.strings` 来自一个 macOS/iOS/tvOS 共享代码库。因此凡是「iPhone/Apple TV/CarPlay 专属」的条目，**macOS 端是否真的呈现，本文一律标「未确认」**，不能直接算作 Mac 版能力。反之，带有 `_mac` 后缀的 key（`onboarding_mac_*`、`stats_mac_*`、`dup_mac_*`、`scrobble_mac_*`、`smart_mac_*`、`player_audio_info_mac_hint`、`radio_mac_*`、`desktop_*`、`menu_bar_*`、`lyrics_island_*`）是**明确的 Mac 专属**证据。

### 1.6 OAuth 接入方（`Info.plist` 内置凭据）

百度网盘（`PrimuseBaiduClientID`）、Dropbox、Google Drive（`PrimuseGoogleClientID` + 反查 scheme）、光鸭云盘（`PrimuseGuangYaClientID/ProjectID/SignSecret`）、InfiniCloud（`PrimuseInfiniCloudAPIKey`）、OneDrive（`PrimuseOneDriveClientID`）、123 云盘（`PrimusePan123ClientID/Secret`）、pCloud（`PrimusePCloudClientID`）、115（`PrimuseU115ClientID` 为空 = 预留未启用）、Palveni（`PrimusePalveniUploadKey`）。

二进制里可直接读到的云盘 API 端点（`strings -a` 实测）：`openapi.alipan.com/adrive/v1.0/openFile/*`、`pan.baidu.com/rest/2.0/xpan/{file,multimedia,nas}`、`proapi.115.com/open/ufile/*`、`yun.123pan.com/auth`、`www.googleapis.com/drive/v3/files`、`www.dropbox.com/oauth2/authorize`、`ws.audioscrobbler.com/2.0/`（Last.fm）、`primuse.yzs.ai`（内置 AI/额度中转）、`share.soundisle.com`（分享中继）、`welape.com`（官网）。

---

## 2. 按功能域的能力清单

### 2.1 播放器与音频管线（最强的一域）

#### 输出模式：两条完全不同的信号链

| Key | 原文 |
|---|---|
| `output_mode_high_fidelity` | 「高保真直通」 |
| `output_mode_high_fidelity_desc` | 「使用最短信号路径，**绕过均衡器、动态处理、混响、空间音频、回放增益、变速与淡入淡出，并自动匹配采样率**。音量仍可调节，DSD 直通时除外。」 |
| `output_mode_effects_desc` | 「使用完整处理链，支持均衡器、动态处理、混响、空间音频、回放增益、变速、淡入淡出、应用音量与可视化。」 |

这是**全局互斥开关**：一个模式下的所有 DSP 功能在另一模式下会被显式禁用，并有大量专门的「不可用」说明，例如 `player_controls_unavailable_speed_high_fidelity` =「高保真直通把音频原样送到输出设备，不能变速。切换到音效输出后就能调速。」、`eq_high_fidelity_alert_title` =「高保真直通时均衡器不生效」。`SettingsSearch.strings` 里还有两条通用限制文案：`"Unavailable in High Fidelity mode. Change the output mode in %@."` / `"Available only in High Fidelity mode...."` —— 说明**设置搜索本身理解功能间的可用性约束**。

#### 10 段均衡器 + 按输出设备自动切换

`Resources/EQPresets.json` 实测 10 个内置预设、**每预设 10 个 band**（-2..+6 dB，增益单位为 dB）：`flat / bass / treble / vocal / jazz / rock / dance / classical / hiphop / latenight`。另有 `"10-Band Equalizer" = "10 段均衡器"` 佐证段数。

超出普通 EQ 的部分：

- **用户预设**：`eq_save_preset_message` =「给当前曲线起个名字，之后一点就能换上，**也可以绑到某台输出设备**。」
- **按输出设备自动换预设**：`eq_device_section_hint` =「给耳机、蓝牙设备或外接解码器选一个预设，**连上时自动换上，断开后换回原来的曲线**。」
- **设备分类**：`eq_device_kind_builtin` 内置扬声器 / `headphones` 有线耳机 / `bluetooth` 蓝牙 / `usb` USB 音频 / `car` 车载音响 / `other`。
- **自动 headroom**：`eq_headroom_note %@` =「整体音量已调低 %@ dB，避免提升的频段让声音失真。」

#### 高保真 / 采样率 / 位深 / DSD / 独占

| Key | 原文 |
|---|---|
| `audio_output_mode` / `output_mode_high_fidelity` | 输出模式 → 高保真直通 |
| `exclusive_output_active` / `exclusive_output_active_bit_depth %lld` | 「独占」「正在独占这台设备 · %lldbit」 |
| `exclusive_output_held_by_other_app` | 「另一个 App 正在独占这台设备，已改为共享输出」 |
| `exclusive_output_unsupported` / `exclusive_output_failed` | 「这台设备不支持独占，已改为共享输出」 |
| `dsd_playback_mode` / `dsd_mode_auto` / `dsd_mode_pcm` / `dsd_mode_dop` | 「DSD 播放」→ 自动 / 转换为 PCM / **优先 DoP** |
| `volume_high_fidelity_system_hint` | 「高保真直通使用单位增益，请使用系统音量调节。」 |
| `player_audio_info_footer` | 「显示在进度条下方，例如 Hi-Res 24/96。轻点可查看完整规格和输出设备实际使用的采样率。」 |
| `now_playing_audio_output_matched` / `resampled` | 「输出 %@ · 与源一致」/「输出 %@ · 已重采样」 |
| `sample_rate_label` / `bit_depth_label` | 采样率 / 位深 |

二进制侧偶证：`Exclusive output bit depth device=`、`DSD output: DoP `、`DoP carrier `、`Failed to rebuild PCM output after DoP error:`。**结论：真的在做独占模式（Hog Mode）+ 位深协商 + DSD64/128 走 DoP，而不只是标签。**

#### 无缝播放 / 交叉淡化 / 音量均衡 / 音效链

| Key | 原文 |
|---|---|
| `gapless_desc` | 「曲目之间无缝衔接，消除静音间隙。」 |
| `gapless_not_available` | 「无缝播放已可用于队列曲目；开启淡入淡出会自动关闭它。」 |
| `crossfade_mode` / `_fixed` / `_smart` | 转场模式 → **固定 / 智能** |
| `crossfade_footer` | 「歌曲自然播完时按上面的时长过渡；手动切到上一首、下一首时用约 1 秒的短过渡。要播放的歌曲还没缓存到本机时会直接切换。不能与无缝播放同时开启。」 |
| `replay_gain_desc` | 「根据音频文件中嵌入的 **ReplayGain** 标签自动调整音量。」 |
| `compressor_limiter` | 「压缩器 / 限制器」，含 `threshold` 阈值 / `headroom` 余量 / `attack` / `release` / `gain` 增益补偿 |
| `compressor_desc` | 「减小音频动态范围，使安静和响亮的部分音量更均匀。**也可用于响度标准化**。」 |
| `reverb_*` | 混响：`small_room / medium_room / large_room / medium_hall / large_hall / cathedral / plate` + 干湿比 |
| `spatial_audio_desc` | 「通过 Apple 的空间音频渲染器，把播放声场放在前方的虚拟舞台中。」 |
| `spatial_head_tracking_desc` | 「使用支持的 AirPods 时，转动头部也能保持声场锚定。」（配合 `NSMotionUsageDescription`） |

二进制侧：`ReplayGain ` 多次出现；`dropped duplicate gapless boundary ticket=`、`auto-advance handoff trigger=gapless-boundary generation=`、`decoded-audio underflow: attempt=%d enginePlaying=%d queued=%.3fs/%dB/%d buffers at %.2fs; rebuilding` —— **说明无缝播放是「预解码下一首 + 边界票据」式实现，并且有专门的欠载自愈逻辑**，不是简单 `AVQueuePlayer`。

#### 变速变调 / 播放时间段 / 高潮检测

- **变速不变调**：`playback_rate_desc` =「0.5×–2.0×。保持音调不变，适合播客或慢速学习。」
- **变调不变速**：`playback_pitch_desc` =「按半音升高或降低歌曲的调，速度不变。有声书和播客保持原声。」
- **播放时间段（A-B 段）**：`playback_range_footer` =「打开后，这首歌从开始时间播起，播到结束时间就算播完，接着播下一首；单曲循环会反复播放这一段。」支持 ±1 秒微调、试听开头/结尾。
- **自动高潮检测**：`playback_range_highlight` =「定位到高潮」、`_running` =「正在找高潮…」、`_none` =「没找到明显的高潮，可以拖动把手自己选。」

#### 其他播放行为

- 音频缓存与上限：`audio_cache_desc`、`audio_cache_limit`、`audio_cache_quarantine`（「旧账号的缓存」= 换账号/换目录后的失效缓存，可清理）
- 混播：`playback_mix_with_others_desc`（「播放时不打断其他 App 的声音…连上 CarPlay 时自动恢复原来的方式」，iOS 专属，Mac 未确认）
- 播放记录口径：`playback_history_note` =「仅统计播放进度达到 %1$d 秒的记录」
- 睡眠定时：`sleep_choice_15/30/45/60/90`、`sleep_choice_end_of_track`、`sleep_choice_end_of_chapter`；`sleep_timer_fade_footer` =「到点前最后 30 秒音量会慢慢降低。」
- 串烧：`medley_settings_footer` =「串烧会找出每首歌的高潮（有带时间轴的歌词时按重复最多的段落，否则分析音频），在高潮前淡入、唱完再淡出接下一首…**串烧不计入收听记录，也不会上报 Scrobble**。」
- 片段导出：`clip_export_audio_mac` =「存储这段音频…」、`clip_export_fades`（首尾淡入淡出）、导出 M4A/AAC

### 2.2 歌词（371 + 73 key，深得反常）

#### 逐字 / KTV

- `lyrics_word_level_badge` =「逐字」、`lyrics_word_level_hint` =「支持逐字歌词」
- `karaoke_ai_word_timing` =「逐字时间由 AI 推断」
- 间奏提示：`player_lyrics_interlude_dots_description` =「第一句之前的前奏和两句之间较长的间奏里显示三个点，跟着时间依次点亮，下一句开唱前轻轻跳两下」

#### 歌词来源（7 种文件格式 + 自定义服务 + 站点）

- 文件：`lyrics_sources_empty_message` =「把和歌曲同名的 **.lrc、.ttml、.elrc、.lys、.yrc、.qrc、.vtt 或 .srt** 文件放进歌曲所在的文件夹，这里就会列出来。」
- **多来源切换**：`lyrics_sources_footer` =「点一行就改用这个文件里的歌词…换来源只改变 Primuse 读哪个文件，不会改动、合并或删除任何文件。」支持逐字/逐行/纯文本/带译文轨四种状态徽标。
- **自建歌词服务（LrcApi 兼容）**：`lyrics_server_protocol_footer` =「应用会向地址发送 GET 请求，附带 title、artist、album、duration 参数，接口返回 LRC 文本或 JSON 即可，**与 LrcApi 的歌词接口格式兼容**。按列表顺序依次尝试，找到即停止。」支持自定义 `Authorization` 头、行内测试。
- 内置歌词源（`scraper_*_desc`）：**LRCLIB**（「开放同步歌词数据库」）、**AMLL TTML DB**（「社区人工打轴的逐字歌词，常带翻译」，默认开启但只用于找歌词）

#### 编辑与打轴（`lyrics_editor`, 74 条 —— 这是一整套 DAW 式工具）

- 双模式：`lyrics_editor_mode_structured`「逐行」 / `_lrc_text`「LRC 文本」；另有 `_mode_timing`「打轴」/ `_mode_text`「文本」
- 边听边打轴：`lyrics_editor_tap_sync`「边听边打轴」、`lyrics_editor_tap_sync`→`lyrics_editor_timing_hint`「听到这句就按 · 自动跳下一句」、撤回/重做一句
- 单句级操作：±0.1 秒微调、`lyrics_editor_stamp_now`「用当前播放时间打点」、整体偏移、按时间排序、修正时间顺序（`lyrics_editor_timing_conflict`「第 %lld 行的时间早于第 %lld 行」）
- **逐字打点**：`lyrics_editor_timing_stamp_word %lld` =「第 %lld 字」
- 粘贴智能解析：`lyrics_editor_paste_parsed %lld` / `_merged_blanks` 合并空行 / `_dropped_credits` 去掉制作信息
- 结构保护：`lyrics_editor_source_text_unavailable_message` =「这份歌词带有逐字时间、译文、和声或 TTML 结构，写成 LRC 文本会丢掉这些内容。」

#### 翻译 / 罗马音 / 格式转换

- **翻译四档**：`lyrics_translation_mode_system`（Apple 翻译框架）/ `_intelligent`（智能翻译，自动回退）/ `_baidu`（百度翻译，用户自备 APP ID）/ `_offline`（离线翻译包）
- 离线翻译包：英↔波斯语、英↔中日韩、CJK 桥接包，可下载/移除，明确写「在本机翻译，不联网」
- 跳过语种：`lyrics_translation_skipped_languages_footer` =「勾选的语言保持原文，其他语言照常翻译。」
- **罗马音**：日语 / 韩语 / 中文（「带声调的汉语拼音」）/ 其他文字（俄乌希泰印阿以）；三种生成方式：本机 / 智能功能 / Google Cloud（要求服务账号 JSON 密钥，存钥匙串）
- **格式转换器**：`lyrics_converter_subtitle` =「在 **LRC、TTML 与纯文本**之间转换」，TTML 兼容 Apple Music，逐字时间保留为增强 LRC，全程本机、4 MB 上限

#### 歌词回写与嵌入

- `lyrics_embed_mode_alongside` =「歌词文件并嵌入音频」/ `_embed_only` =「只嵌入音频文件」
- `lyrics_embed_confirm_message` 风险披露极完整：「每次保存都要把整首歌下载、改写后重新上传…写入前会确认文件没被别处改过，写完会回读核对」
- 支持格式：MP3 / FLAC / M4A

#### 歌词海报（`lyric_poster`, 73 条）

16 种风格（极光玻璃 / 渐变引句 / 杂志 / 黑胶 / 电影 / 霓虹 / 拍立得 / 磁带 / 信笺 / 聚光 / 歌词卡 …）、6 种滤镜、5 种动效（浮动歌词 / 专辑缩放 / 粒子飘散 / 声波律动）、3 种画幅、**实况照片导出**、分步向导（选词 → 写评语 → 选风格 → 导出）。

#### 其他

- 歌词偏移（补偿蓝牙延迟）：`lyrics_offset_desc` =「用来补偿音频输出延迟（蓝牙耳机几百毫秒、内置扬声器约 30 ms）」
- 桌面歌词 / 菜单栏歌词 / 歌词上岛（Mac 专属）：`desktop_lyrics_island` =「在屏幕顶部显示歌词，悬停展开播放控制」；`menu_bar_lyrics_description` =「在菜单栏 Primuse 图标旁显示正在唱的那一行」
- 听歌识词（音频→歌词）：`lyrics_audio_tools_footer` =「听歌识词会生成可编辑的时间轴歌词草稿；校对并确认前不会保存。」

### 2.3 曲库管理与元数据（自己就是曲库管理器）

#### 多源扫描 + 体检

- 三种导入语义：`local_import_folder_title`「引用文件夹」/ `_files_title`「引用文件」/ `_copy_title`「复制到 Primuse」
- **音乐源体检**（`source_diag`, 86 条）：配置 / 凭据 / 连接 / 目录访问 / 扫描就绪 五段检查，每种失败都给「原因 + 建议」，含超时、网络不可达、证书、限流、OAuth 过期、SMB 共享未固定、NFS 导出路径、S3 bucket 缺失等
- **标签读取性能管理**（`MetadataReading.strings` 全文 15 条）：自动 / 全速 / 节能 / 已暂停 / 优先保障播放 / 低电量模式 / 正在降速散热 / 等待设备降温后继续，附警告：「尽快完成标签读取，可能增加发热、耗电和界面卡顿。温度偏高、低电量或播放音乐时仍会自动降速」
- 高性能模式：`metadata_backfill_fast_mode_footer` =「默认关闭，以单线程小批次温和读取标签。开启后，前台扫描最多使用 **3 路并发且不做请求节流**」

#### 刮削（`scrape/scraper`, 91 条）

内置源：**MusicBrainz**（元数据+封面）、**LRCLIB**（歌词）、**AMLL TTML DB**（逐字+翻译）、**iTunes Search API**（元数据+高清封面）、**自定义歌词 API 服务**。支持拖拽排序、遇到结果即停、**歌词不是逐字时再问后面最多两个源**（`scraper_sources_footer`）。

**可导入自定义刮削源（带 JS 沙箱）**：`scraper_review_footer` =「导入后，该刮削源在查询元数据时将可**运行其 JavaScript 并连接上述域名**。」导入前有安全预览：能力、请求、端点、网络域名、TLS 信任域名、请求头、Cookie、密钥（`scraper_review_*`）。

#### 标签编辑与写回（`tag_editor`, 76 条 + `metadata_writeback`）

- 字段：标题/艺术家/专辑/流派/年份/曲目号/碟片号 + 封面 + 歌词
- **写回策略四档**：`metadata_writeback_checking` → `_embedded`「标签和封面将写入源音频文件；保存前会检查版本，保存后会重新下载并校验文件与内嵌元数据」/ `_server_api`「通过媒体服务器 API 写回」/ `_sidecar_only`「标签只保存在 Primuse，选中的封面会写入源端旁路文件并回读校验」/ `_local_only`「只读音乐源」
- **五阶段写回流水线**：检查源文件版本 → 下载源文件 → 写入并校验标签 → 替换源文件 → 回读校验（`metadata_writeback_stage_*`）
- 冲突与损坏保护：`metadata_writeback_error_conflict`「源文件在编辑期间已发生变化。为避免覆盖其他修改，请重新扫描后再试。」、`_remote_verification`、`_missing_revision`
- 编码修复：`tag_editor_encoding_fix` =「修正乱码…」
- 艺术家名拆分：`artist_name_settings_intro` =「拆分曲目中拼接的多位艺术家，不改写原始标签或专辑艺术家」，可配分隔符（默认半角/全角分号、斜杠、顿号）、**受保护名单**（如 `AC/DC`）、展示连接符

#### 去重（`dup`, 44 条）

- Mac 版：`dup_mac_match_hint_format` =「按**指纹 (acoustid)** + 标题/艺术家匹配 · 可回收 %@」
- 通用版：`dup_summary_footer` =「按标题 + 艺术家 + 时长±1s 分组，标记最高音质版本为推荐保留。清理重复项只删冗余音频；同名歌词/封面仍被保留版本使用时不会删除。」
- 保留策略：最高码率 / 最大文件 / 最新加入；「一键智能保留」；删除走「最近删除」可恢复；前 100 组渐进展示

#### 评分与评论 / 收藏

`library_review_feature_description`「在歌曲、专辑、歌单和流派页面显示个人星级与评论。**此功能默认关闭**」；`library_favorite_filter`「只看收藏的」

#### 歌单导入（`playlist_import`, 119 条 —— 单一子域里最大的一块）

`playlist_import_intro_desc` =「收到的歌单文件（m3u、json，或者 **Apple Music、Spotify 导出工具、foobar2000、VLC、Windows Media Player** 导出的 csv / txt / xml / pls / xspf / wpl）会按文件名和歌名歌手匹配你库里的歌曲。」

- 三种匹配：ID 匹配 / 文件名 / 模糊（`playlist_import_kind_*`）
- 导入前预览 + 未匹配条目导出 CSV + **手动匹配**（搜索资料库）
- 目标：新建歌单 / 加入「我喜欢」/ **合并到已有歌单**（只加不重排，跨源同名视为同一首）

#### 其他

- 目录管理（`HomeDiscovery.strings`）：收藏目录、目录用作歌单、首页目录排行（播放冠军/上升最快/聆听最久/新上榜）
- 列表/紧凑/网格三种视图，可选列：格式/采样率、评分、比特率
- 最近删除（`recently_deleted`）

### 2.4 智能歌单 / 场景推荐 / 智能提示

- **规则引擎**（`smart`, 119 条）：14 个字段（歌名/艺术家/专辑/流派/年份/格式/添加时间/时长/文件大小/码率/音乐源/播放次数/最近播放/**属于歌单**）× 7 个算子（等于/不等于/包含/不包含/大于/小于/介于），AND/OR 组合，**支持「规则组」+ 组级排除**（`smart_rule_group_footer`「多个规则组之间会同时生效；开启排除后，该组命中的歌曲会被排除」），排序字段 8 个 + 数量上限 + 实时更新
- **智能提示**（`smart_nudge`，本机判断，不打断播放）：常听的歌加入我喜欢 / 循环听时推荐相似 / 常跳过的「我喜欢」问要不要取消 / 队列快播完时接着播推荐 / **深夜提醒设置睡眠定时** / 有声书听完提议接着放之前的音乐 / **询问没有标签的长音频是不是有声书**
- 「开始听」的意图页：`listening_intent_pin` 钉选、按曲库自动出现

### 2.5 统计与年度报告（`stats` 141 + `yearly` 101）

#### 统计

- 维度：播放次数 / 总时长 / 活跃天数 / 听过的曲目 / 覆盖率；时间范围 本周·本月·本年·全部
- 图表：**GitHub 风格热力图**（7×N，`stats_heatmap_style_title`）、听歌日历、时长趋势（按天/按月）、**播放时段分布（按小时）**、Top 歌曲/艺术家/专辑
- 较真处：与上期对比（`stats_previous_week/month/year`）、`stats_heavy_rotation`、`stats_spoken_word_time`「听书时长」
- **双数据源**：本机 vs **服务端权威快照**（`stats_server_authoritative`「以服务端为准」），并诚实标注各服务端能力边界，例如 `stats_server_navidrome_history_boundary` =「图表和分时段统计来自 Navidrome 保留的逐次播放历史…服务端未提供实际听歌时长」、`stats_server_aggregate_boundary`、`stats_server_event_boundary`；缓存过期策略：`stats_server_stale_expired`「已超过 24 小时」/ `_clock`「设备时间与快照时间不一致」/ `_backup`「已从最近有效备份恢复」
- 隐私：`stats_privacy_footer`「听歌记录仅保存在本设备本地，不会上传到云端」——但与 `stats_recap_privacy_footer`「开启 iCloud 同步时也会在你自己的设备之间同步」并列，口径是按是否开同步
- **AI 心情解读**：`stats_recap_mood_consent_message` =「会把最近 30 天的听歌时长、常听的时段，以及常听的艺人、歌名和风格发给你选择的 AI 服务，换回一小段解读。」9 种状态卡（单曲循环中 / 夜里的听众 / 四处寻新 / 沉浸其中 / 越听越多 / 偶尔听听 / 往回听 / 稳稳的节奏）
- 8 个「听歌人格」标签：白天听/夜里听、爱探索/专精、长情/追新歌、风格杂食/爱老歌

#### 年度报告（`Primuse Wrapped`）

- 10 个章节：第一首歌 / 年度艺人 / 年度歌曲 / 你的口味 / 听歌的时间 / 高光时刻 / 你的音乐月 / 音乐从哪来 / 音乐人格 / 谢幕
- **16 种音乐人格**（2×2×2×2 矩阵：e/l × o/f × n/v × d/m），例如 `yearly_personality_eonm_name` =「夜行探险家」、`lovm` =「月下守夜人」、`lfvd` =「复古铁粉」
- 年内实时模式：`yearly_cover_lead_in_progress_format` =「从1月1日到%@，你和音乐一起度过了这么久」、`yearly_closing_in_progress_title_format`「%@ 还在继续」、`yearly_this_year_needs_more_format`「再听 %d 首歌，就有今年的报告了」
- 5 个时段分档：清晨 / 上午 / 下午 / 傍晚 / 深夜

### 2.6 AI／智能功能（`ai` 409 key，+ `ai_consent` 32 —— 全库最大域）

#### 服务层（这是「AI 平台」而不是「一个 AI 按钮」）

- **多服务管理**：可添加任意多个 AI 服务，排序、默认服务、**按功能路由到不同模型**（`ai_models_routing_footer`「多加几个模型，就能在「功能」里把不同功能分给不同模型，比如翻译用快的、简介用强的。」）、失败自动降级（`ai_fallback_enabled`）
- **26 个服务预设**（另有「自定义」）：OpenAI / Anthropic / DeepSeek（OpenAI 格式 & Anthropic 格式）/ Google Gemini / 通义千问 / 智谱 GLM / 小米 MiMo / Kimi / MiniMax / 火山引擎方舟 / 腾讯云 TokenHub / 百度千帆 / 阶跃星辰 / 硅基流动 / 商汤日日新 / Agnes AI（含国内版）/ OpenRouter / NVIDIA NIM / xAI / Mistral / Groq / Together / Fireworks
- **4 种协议兼容**：OpenAI Responses API / OpenAI Chat Completions / Anthropic Messages（原生）/ Gemini generateContent（原生）；可指定 API 路径策略（自动 / 按填写 / 自动补 `/v1`）与鉴权方式（自动 / Bearer / `x-api-key`）
- 模型发现：`ai_models_footer`「使用基础 URL 的 `/models` 接口获取模型」
- **内置 AI 中转**（免费额度）：`ai_primuse_relay_footer` 明确声明「是 Primuse 提供的免费体验通道…不适合长期依赖…可能会下线，或改为单独收取 AI 调用费用」；**App Attest 设备验证**（`ai_primuse_relay_unsupported`「此设备无法通过 App Attest 验证内置 AI 访问」），降级为 StoreKit 交易验证
- **额度/计费**：`ai_quota_*`（免费/内测/订阅/赠送四来源、按设备或按 Apple 账号合计、请求失败不扣次数）、**兑换码**（`ai_redeem_code_format` =「PRM-XXXX-XXXX-XXXX」）

#### 10 项 AI 能力

| 能力 | Key | 说明 |
|---|---|---|
| 语义曲库搜索 | `ai_enable_semantic_search` | 「将『钢琴纯音乐』等描述性搜索扩展为相关概念，再在本地曲库中匹配」 |
| 场景推荐 | `ai_recommendation_scene_*` | 此刻/驾车/专注/运动/放松/睡前，只**重排本地候选**，不上传曲库 |
| 选歌方向（意图） | `ai_recommendation_intent_*` | 常听延续/相似发现/流派探索/年代回顾/近年作品 + 自定义提示词 |
| AI 智能歌单 | `ai_playlist_prompt_placeholder` | 「例如：适合夜跑的高能电子乐，少一点人声」→ 从资料库挑歌 |
| 曲库以外的新歌 | `ai_song_discovery_*` | 按口味推荐**曲库里还没有的 20 首**，可拷贝歌名 |
| 专辑/艺人简介 | `ai_feature_library_insight` | 按需生成 |
| 标签整理建议 | `ai_feature_tag_cleanup` | 发送「歌名、艺人、专辑等标签和文件名，不含文件夹路径」 |
| 歌词翻译 | `ai_settings` 路由 | 与歌词域共享开关 |
| 听歌状态解读 | `ai_feature_listening_mood` | 近 30 天统计 → 一段解读，最多每周一次 |
| 听歌识词 / 文字稿 | `ai_audio_transcription_*` | 音频上传生成时间轴歌词 |

#### 隐私模型（做得非常正式）

`ai_consent_*` 独立成章：分「打开功能后自动发送」vs「你点了才发送」两组列出**每项功能具体发什么**（`ai_consent_data_*`，9 条），声明「Primuse 的服务器只转交、不保存这些内容，只记下用了哪项功能、用了几次」、可随时撤回、同意状态 iCloud 同步。另有独立开关 `ai_allow_insecure_local_http`（仅局域网 HTTP 需单独允许）、`ai_error_public_http`「公网服务必须使用 HTTPS。」

### 2.7 离线 / 缓存 / 多设备

#### 三级缓存

1. **音频缓存**（播放缓存）：`audio_cache_desc`、上限可设、可清；
2. **离线下载 / 固定离线可用**：`offline_keep_cached`「固定为离线可用」、整源批量缓存 `source_cache_all_*`（含预计体积、跳过已缓存、失败原因分类：连不上/鉴权失效/无权限/空间不足/服务器报错）；
3. **音乐源文件缓存**：`source_file_cache_footer`「播放 WMA、APE 这类需要完整文件的格式时从音乐源整首下载的文件…**不计入音频缓存上限**」

断电/断网自愈：`source_cache_stopped_storage_format`「手机剩余空间不够，剩下的先停下了」、`_network`「网络断开超过 10 分钟」、`_auth`「账号或密码已失效」、`source_cache_waiting_network`「网络已断开，恢复后会接着缓存」。

#### 多设备缓存同步（`CacheSync.strings` 69 条 —— 罕见功能）

`cache_sync_subtitle` =「将已有音频缓存直接发送到另一台 Primuse 设备」

- 局域网 Bonjour 发现（`_primuse-cache._tcp`）+ **连接码直连兜底**（6 位）
- **只传目标端缺失的文件**：`cache_sync_encrypted_footer`「加密直传 · 仅安装目标端缺失的文件」
- 明确不做重新下载：`cache_sync_local_network_footer`「缓存文件仅通过局域网直传；同步过程不会从媒体服务器重新下载音频」
- 不污染曲库：`cache_sync_matching_library_hint`「此功能只补齐音频缓存，保留原有歌曲身份，不会将其导入为本地音乐」
- 先试传 3 个文件验证链路、失败原因细分（本地网络权限 / Bonjour NoAuth / 缺 Info.plist 声明 / 网络不可用 / 连接码无效）

#### 局域网传输（`WiFiTransfer.strings` 155 条）

双通道：

1. **浏览器访问**：`wifi_subtitle`「通过浏览器将音乐传入 Primuse」——内置 HTTP 服务 + 六位访问码 + 网页端文件管理（上传/新建文件夹/删除/搜索），单文件 8 GB 上限、防目录穿越、错误码化（`invalidPath/conflict/tooManyAttempts/notEnoughSpace`…）
2. **设备直传**：`nativeSubtitle`「在同一局域网内，将音乐、歌词和文件夹发送到另一台 Primuse 设备」，接收端需确认、支持从曲库选歌发送（**自动准备完整音频 + 歌词 + 封面**，每次最多 3000 首），明确排除项：`libraryProtected`「Apple Music 订阅歌曲无法导出为音频文件」、`libraryCue`（CUE 虚拟单曲）、`libraryStream`（实时流 / STRM）

### 2.8 来源接入（最广的一域：**一次性聚合 20+ 种后端**）

onboarding 原文（`onboarding_sources_*`）是最完整的官方枚举：

| 组别 | 原文 |
|---|---|
| NAS | 「群晖、威联通 NAS 与 SMB / NFS 共享，以及 Audio Station、飞牛音乐等 NAS 音乐服务」 |
| 云盘 | 「123 云盘、百度网盘、阿里云盘等云端音乐」 |
| 网络服务 | 「Navidrome、Jellyfin、Emby、WebDAV、SFTP、UPnP / DLNA 等服务」 |
| 文件协议 | 「WebDAV、FTP、SFTP，支持加密验证」 |
| DLNA | 「局域网内的 UPnP / DLNA 媒体服务器」 |
| Apple | 「可选连接 Apple Music，一并浏览订阅资料库」 |

结合指纹统计与 Info.plist 凭据，可确认的接入类型：

- **媒体服务器**：Jellyfin、Emby、Navidrome / OpenSubsonic、Plex（`plex_signin`、`metadata_writeback_plex_*` 证明有写回）、Audiobookshelf（`audiobookshelf_credentials_hint`，支持 API Key）
- **NAS 原生协议**：Synology DSM（含 **QuickConnect**：`synology_quickconnect_hint`「只需输入 DSM 控制面板中的 QuickConnect ID；Primuse 会自动选择直连、Smart DNS 或中继」）、**Synology Audio Station**（`audio_station_error_*` 一整套错误码，含两步验证）、飞牛音乐、SMB/CIFS（AMSMB2）、NFS（可选版本）、SFTP、FTP（含 EPSV/PASV/PORT 三种数据连接策略）
- **WebDAV**
- **云盘**：百度网盘、阿里云盘、123 云盘、115（预留）、光鸭云盘、Drime、InfiniCloud、Google Drive（`gdrive_scope`, 请求完整云端硬盘权限）、OneDrive、Dropbox、pCloud
- **对象存储**：S3（`source_diag_config_missing_bucket`）
- **其他**：本地文件 / iCloud Drive、Apple Music、AList（3 处指纹）、UPnP/DLNA

深度细节：
- 多地址容灾：`source_card_unreachable_add_route_hint`「这个音乐源只填了内网地址。编辑它并添加公网地址后，离开内网也能播放。」（内外网双地址）
- 云盘按需读标签头：`song_details_loading_message`「正在从云盘下载这首歌的**标签头（约 256 KB）**，用来解析时长、封面和艺术家」（不整首下载即可入库）
- 云盘扫描节流：`cloud_scan_wifi_only_footer`「扫描云盘时只读取文件名，详情会在后台分批加载…遇到蜂窝网络会自动暂停」
- 直连失败分级诊断：`webdav`/`smb`/`ftp` 各自错误文案（`smb_error_auth/not_found/refused/unreachable/timeout`）

### 2.9 播客 / 有声书 / 电台 / 文字稿

#### 播客（`podcast` 149）

- RSS 订阅（先读取预览再决定订阅）、目录搜索、热门榜、**OPML 导入/导出**
- 单集管理：自动下载新单集（仅 Wi-Fi）、听完删除下载、标记已播/未播、批量「之前的都标为已播放」
- 播放顺序：自动（最新在前）/ 自动（从第一集开始）/ 最新 / 最早 / 按文件顺序
- 章节、连续播放、筛选（已下载 / 听到一半 / 未播放）

#### 有声书（`spoken` 84 + `spoken_word` 84）

`karaoke_tv_*` 之外，`settings_push_to_tv` 提及「从 iPhone 传入曲库」；`intent_book_*`（Siri「继续听书」）；播放控件为有声书单独做了一整套版面（`player_controls_spoken_*`，含「上一章 / 下一章」「自动」位）——**值说明：有声书被当作一等公民，而不是播客的子集**。

#### 文字稿（`transcript` 199，含 `transcript_reader` 94 / `transcript_generation` 73）

- 生成引擎三选：**本机识别**（`transcript_generation_engine_on_device_detail`「用 Apple 的语音识别在这台设备上离线识别，免费，音频不离开设备，**再长也行**」）/ 内置 AI（分段上传，每段 ≤10 分钟）/ 自己的 Google 密钥
- 阅读器：字体排版、全屏阅读、**时间轴偏移**（可按这一集 / 这本书 / 所有文字稿三级叠加，专为车载蓝牙延迟设计）
- 长文翻译策略：`lyrics_translation_spoken_word_timing_footer`「播客和有声书的文字稿往往很长。选『点了再翻译』后，换到新的一集或一章时先不翻译」

#### 电台（`radio` 153）

- 手动添加 HTTP(S) 直播流、台标（<750 KB）、**试播验证**（「会短暂建立静音连接」）
- **批量三种入口**：粘贴（支持「名字, 地址」）、`.m3u/.m3u8/.pls` 清单、在线目录搜索 **radio-browser.info**
- 文件夹分组、置顶、优先级排序（影响首页 / 上下一台 / CarPlay / 电视）、导出
- 技术上限：`error_radio_unsupported_format`「该直播流不是受支持的 **FLAC 或 Ogg FLAC** 格式」+ 三条 `radio_flac_error_*` → 说明能解 FLAC 直播流

### 2.10 系统集成

| 类别 | 能力 | 证据 |
|---|---|---|
| **App Intents / Shortcuts** | 播放媒体（歌曲/专辑/歌单/艺人/流派/相似歌曲/播客/有声书/电台）、播放速度、队列位置、循环/随机、睡眠定时、搜索、**刮削**（`intent_scrape_*`，含「Primuse 进入前台后会开始刮削」）、**设置读写**（Open/Get/Set Setting + `Set Audio Output Mode`） | `PlayMedia.strings`、`SettingsSearch.strings`、`intent_*`；`Resources/Metadata.appintents` |
| **Siri** | 11 条 AppShortcuts 短语；`siri_spoken_names_detail`「说中文时，『猿音』最不容易被听错」；自定义口令教学 | `AppShortcuts.strings`、`siri_*` |
| **Spotlight** | 系统搜索索引曲库（歌/专辑/艺人/歌单），可选封面、可限流（「曲库超过 N 首时，只收录最近放过、喜欢的和最新加入的」）、后台续建、过热/低电量暂停 | `spotlight_*`；`CoreSpotlightContinuation: true` |
| **小组件** | WidgetKit 扩展；数据范围可选（`"WidgetKit still manages the system widget gallery; checked items control which data Primuse pushes."`）、颜色风格（取自封面/单色） | `PlugIns/PrimuseWidgetExtension.appex`、`widget_*` |
| **桌面（macOS）** | 桌面小组件同步、**桌面歌词（可锁定，⌘⇧L）**、**歌词上岛**（含耳机/音量/充电状态提示）、菜单栏歌词 / 菜单栏图标、迷你播放器 | `desktop_*`、`menu_bar_*`、`mini_player` |
| **键盘快捷键** | 自定义录制器，分「播放控制」「窗口与导航」两组，冲突检测/替换/恢复默认，区分 macOS 保留键 | `keyboard_shortcuts_*` |
| **通知/推送** | APNs entitlement（`aps-environment: production`）；具体通知类型**未确认**（未找到专门 key） | entitlements |
| **分享** | 系统分享歌曲信息；**创建播放链接**（自动选择音乐服务器或 Primuse 中继）；**私有中继分享**（短码 6 位 / 高熵永久安全链接、有效期、访问密码、自建服务） | `share_*`、`relay_share_*` |
| **DLNA 接收（作为被投送端）** | `settings_dlna_footer`「同 Wi-Fi 下的其它设备(VLC、群晖音频中心、Plex、Hi-Fi Cast 等)可以发现 Primuse 并把音频推过来播放。」含后台 keepalive 与实时活动日志 | `settings_dlna_*` |
| **投送到 TV** | `settings_push_to_tv_footer`（Apple TV 同 iCloud 账号）+ 「Apple TV 中继」让 ATV 经 Mac 播放本地文件 | `settings_relay_*`；`_primuse-xfer` |
| **CarPlay** | 6 个 tab（最近/专辑/艺人/歌曲/歌单/搜索）、3 种布局预设（快捷播放/封面浏览/专注播放）、即将播放 | `carplay_*`；**macOS 端不可能呈现，仅证明代码库能力** |
| **Apple Music** | 授权后同步订阅资料库并作为播放源；明确边界：`apple_music_now_playing_hint`「Apple Music 在系统侧播放，**刮削 / 标签编辑 / 均衡器等 Primuse 功能不适用**」；`apple_music_lyrics_unavailable`「Apple Music 的同步歌词不开放给第三方应用」 | `apple_music_*` |
| **iCloud 同步** | 歌单/我喜欢/音乐源/播放历史/设置；**凭据走 iCloud 钥匙串**（`icloud_sync_footer`、`keychain_sync_hint_body`「端到端加密同步」）；AI 设置与同意状态也同步 | `icloud_sync_footer`、`ai_key_sync_footer` |
| **家庭共享** | 共享歌单/智能歌单/NAS·云盘·Apple Music 源配置；「我喜欢」、听歌历史、年度报告、个人偏好保持私有 | `family_sharing_*` |
| **诊断** | MetricKit + 崩溃日志、内存/CPU(播放)/崩溃(30天)指标、实时日志、诊断模式（「24 小时会多记一些排查用的信息…到时自动关闭」）、导出/邮件发送 | `diagnostics_*` |
| **更新检查** | 自建更新提示，且**明确区分 macOS/iOS 版本线**（`update_policy_macos_app_store_id`） | `update_*` |
| **开源许可页** | 组件 + 全文许可 + 版本说明 | `"Open-Source Licenses"` 段 |
| **Easy mode / 极简模式** | `library_sections_settings_footer`「分类的显示、隐藏和顺序同时应用于资料库、侧栏与**极简模式**标签」 | 同上 |

### 2.11 视觉与个性化

- **主题色**：跟随封面自动取色 / 固定色（青蓝、松石绿、森林绿、蓝、靛蓝、紫、玫红、品红、红…）
- **播放页深度定制**（`player_style_*`）：2 种一键预设（简洁 / Primuse 默认）+ 恢复套用前、按钮位（歌名旁 / 播放键两侧 / 底部排 / 功能块）、播放键 5 种样式、跳转键 5 种样式、3 种进度条（默认 / 波浪 / 细线圆点）+ 发光、音量条 2 种、控件着色（跟随主题/单色）、封面样式（卡片/铺满）、6 种背景（封面取色 Mesh/经典、流动色彩、声音律动、模糊封面、专辑封底、我的图片）+ 轮播、封面下歌词（1–3 行/自动 + 字号）
- **全屏效果**：**13 种**（原生、流动封面墙、流动声纹、环形声谱、黑胶唱机、星夜极光、声场地平线、星尘律动、封面流、克拉尼沙画、萤火同步、神经共鸣、动态歌词），实时频谱驱动、帧率策略（30/60/跟随屏幕，支持 120 Hz）、动效强度 4 档、自动轮换、低电量/过热自动降级
- **动态封面**：GIF / APNG / 动态 WebP，`player_animated_artwork_unmetered_only`「仅通过 Wi-Fi 下载原始封面」
- **无障碍**：`a11y_*` 一整套（播放/暂停/上下一首/随机/循环/队列/歌词/喜欢/更多操作的中文标签）
- **简化动态**：多处尊重「减弱动态效果」、低电量、过热（`player_lyrics_motion_description`、`immersive_power_lowered_*`、`spotlight_index_held`）

---

## 3. 十个最具辨识度的能力

| # | 能力 | 为什么辨识度高 | 核心证据 |
|---|---|---|---|
| 1 | **双信号链输出模式**（高保真直通 ↔ 音效处理） | 大多数播放器只有一条链；这里是**全局互斥架构**，并让设置搜索理解跨功能可用性约束 | `output_mode_high_fidelity_desc`「绕过均衡器、动态处理、混响、空间音频…自动匹配采样率」 |
| 2 | **独占输出 + DoP DSD + 位深协商** | 真正在跟 CoreAudio Hog Mode 打交道，有完整的失败降级话术 | `exclusive_output_active_bit_depth %lld`「正在独占这台设备 · %lldbit」、`dsd_mode_dop` |
| 3 | **EQ 按输出设备自动切换 + 自动 headroom** | 把「设备感知」做进 EQ，连上耳机自动换曲线 | `eq_device_section_hint`、`eq_headroom_note %@` |
| 4 | **多设备缓存同步（局域网直传，只补缺失）** | 罕见的跨设备缓存搬运，且刻意不重新下载、不污染曲库 | `cache_sync_subtitle`、`cache_sync_encrypted_footer`、`cache_sync_matching_library_hint` |
| 5 | **卡拉OK：AI 人声分离 + 打分 + 录音 + 耳返 + 电视当麦克风** | 完整 KTV 产品，含专用 Background Assets 模型下载扩展 | `karaoke_ai_title`、`karaoke_score`、`karaoke_monitor_needs_wired`、`karaoke_tv_scan_title`；`PrimuseKaraokeModelDownloader.appex` |
| 6 | **歌词打轴工作台**（边听边打 / 逐字打点 / 时间冲突修正 / 多源切换 / 回写与嵌入音频） | 把「歌词编辑」做成准专业工具，还区分「写文件 / 写服务器API / 只存本地」 | `lyrics_editor_tap_sync`、`lyrics_editor_timing_stamp_word %lld`、`lyrics_embed_confirm_message` |
| 7 | **AI 是一个可编排的平台**（24 预设 × 4 协议 × 按功能路由 × 内置中转 + App Attest + 额度兑换码） | 远超「接一个 OpenAI key」的程度 | `ai_provider_preset_*`(24)、`ai_models_routing_footer`、`ai_primuse_relay_unsupported`、`ai_redeem_code_format` |
| 8 | **服务端权威统计 + 年度报告（16 种音乐人格）** | 认真正视「哪些数据服务端有、哪些没有」，并把年度报告做成产品 | `stats_server_navidrome_history_boundary`、`yearly_personality_lfvm_name`「黑胶守夜人」 |
| 9 | **内置浏览器端文件服务器（Wi-Fi 传输）** | App 内起 HTTP 服务器，手机/笔电浏览器直接管理曲库文件 | `wifi_subtitle`、`wifi_tooManyAttempts`、`wifi_tooLarge`「单文件最大支持 8 GB」 |
| 10 | **macOS 系统级深化**：桌面歌词 / 歌词上岛 / 菜单栏歌词 / 自定义快捷键 / WidgetKit / Spotlight / App Intents 含「改设置」 | Mac 版不是 iOS 移植，有独立产品面 | `desktop_lyrics_island`、`menu_bar_lyrics_description`、`keyboard_shortcuts_recorder_*`、`"Set Audio Output Mode"` |

---

## 4. 明显超出普通播放器的深度项

**A. 音频工程层**
1. 自带 FFmpeg + 9 个独立解码库 + 1 个 MP3 编码器（lame），支持 APE/WMA/TTA/MPC/WavPack/DSD；
2. 无缝播放有「预解码 + 边界票据 + 欠载自愈重建」的实现痕迹（二进制日志串）；
3. 压缩器/限制器带阈值-余量-增益的**失真上限提示**（`compressor_gain_cap_note`「总增益超过 %@ dB 会失真，超出的部分不生效」）；
4. 混响有 headroom 自动补偿（`reverb_headroom_note`）；
5. 交叉淡化区分「自然播完 → 按时长过渡」与「手动切歌 → 1 秒短过渡」，且**未缓存时会退化为直切**；
6. 串烧用「歌词重复段落」优先判断高潮，否则分析音频，且**不计入统计与 scrobble**。

**B. 数据一致性层**
7. 元数据写回是**五阶段事务**（检查版本 → 下载 → 写入校验 → 替换 → 回读校验），三方冲突（源文件被改 / 无 revision / 校验不过）都有独立错误码；
8. 歌词/封面「嵌入音频」前明确披露代价（整首重传、mtime 变化会让同步盘和媒体服务器当新文件、建议先备份）；
9. 缓存区分「播放缓存 / 离线固定 / 需完整文件的格式缓存 / 旧账号隔离缓存」四类，各有独立清理语义。

**C. 来源适配层**
10. 20+ 种后端，且每种都有**专属错误码 + 修复建议**（Synology 两步验证、Audio Station 权限、SMB 五类错误、FTP 三种数据连接模式、云盘 OAuth 过期、Drime token 权限粒度）；
11. 云盘只读 256 KB 标签头即可入库，详情后台分批 + 蜂窝自动暂停；
12. 内外网双地址容灾 + 自动切换。

**D. 本地化与合规层**
13. 16 种语言；
14. AI 同意书按功能逐条列出「发什么」（10 条 `ai_consent_data_*`），并说明服务端只转交不保存；
15. 诊断报告、开源许可页、更新检查区分平台版本线。

**E. 交互体贴层**
16. 设置搜索理解「某个设置在什么条件下不可用」并给出精确跳转；
17. 智能提示（`smart_nudge`）全部本机判断、几秒消失、拒绝后不再打扰；
18. 低电量 / 过热 / 减弱动态效果三路统一降级（歌词动效、全屏效果、Spotlight 索引、标签读取）。

---

## 5. Primuse 强在哪、弱在哪

### 5.1 明显强（且是护城河）

| 类别 | 判断依据 |
|---|---|
| **音频管线与音质** | 双信号链、独占输出+位深、DoP DSD、10 段 EQ+设备绑定+headroom、ReplayGain、压缩/限幅、混响、空间音频+头部追踪、0.5–2× 变速、±半音变调、无缝+智能交叉淡化 |
| **歌词（全链路）** | 8 种文件格式、逐字/ELRC/TTML、打轴工作台、4 档翻译、罗马音 4 语种 3 方式、格式转换、回写嵌入、多源切换、海报导出 |
| **曲库管理**（自建） | 扫描+体检、4 内置刮削源+JS 自定义源、五阶段标签写回、acoustid 去重、歌单导入 10 格式、艺术家名拆分 |
| **来源接入广度** | 20+ 种后端，含 11 家云盘（另 115 已实现未启用）、Synology QuickConnect + Audio Station、SMB/NFS/SFTP/FTP/WebDAV/S3/UPnP |
| **AI 深度** | 多服务多模型按功能路由、4 协议、内置中转 + 设备验证 + 额度体系、10 项具体能力、正式同意书 |
| **macOS 系统集成** | 桌面歌词/歌词岛/菜单栏歌词/自定义快捷键/WidgetKit/Spotlight/App Intents 含设置读写 |
| **多设备与离线** | 三级缓存 + 缓存互传 + 浏览器文件服务器 + 设备直传 + iCloud 同步 + 家庭共享 |

### 5.2 弱 / 不涉及

| 类别 | 判断与依据 |
|---|---|
| **影视/视频** | 几乎不涉及。仅 `player_animated_artwork` 提 GIF/APNG/WebP 动态封面、`karaoke` 有 MV 的排除逻辑（`player_backdrop_visualizer_hint`「Apple Music、电台和 MV 没有声音数据」）。**未发现**剧集/季/集号/字幕轨/转码选择相关 key |
| **多用户与权限体系** | 无本地多用户/家长控制。家庭共享是 iCloud 层面的「共享配置、私有历史」，不是账号体系 |
| **云同步元数据服务**（自己托管） | 明确拒绝：`onboarding_welcome_subtitle`「不上传任何文件到任何人」 |
| **社交/评论社区** | 只有本机个人星级与评论（`library_review_*`，且默认关闭），无公开社区 |
| **在线音乐商店/版权曲库** | 无自有曲库。`ai_song_discovery` 只能「推荐歌名让你去别处找」，明确不支持试听（`这里不能试听`） |
| **播放上报服务端聚合** | Last.fm / ListenBrainz 有，但**未发现**自有社交统计服务 |
| **投屏协议（Chromecast/AirPlay 视频）** | AirPlay 用于音频输出（`player_controls_action_airplay`），DLNA 只做**接收**；AirPlay 视频投屏**未确认** |
| **同步歌词的官方来源** | 明确受制于平台：`apple_music_lyrics_unavailable`「Apple Music 的同步歌词不开放给第三方应用」 |

### 5.3 商业形态（影响能力取舍）

订阅 + 买断并存：`ai_quota_source_subscription`「订阅」、`ai_redeem_*`（兑换码）、`ai_quota_source_testflight`「内测额度」、`ai_quota_source_grant`「赠送」。**AI 额度是唯一按次数计费的部分**，本地播放/曲库管理能力不设限。

---

## 6. 对 Overtone 的初步借鉴候选（供差距分析参考）

> 说明：以下仅从「Primuse 做到 & Overtone 可能没有」角度看，**成本/移植可行性未评估**（Overtone 是 Jellyfin/fnOS 流媒体客户端，凡属「曲库管理」的深度能力原则上应由服务器承担，不可照搬）。

| 候选 | 证据强度 | 理由 |
|---|---|---|
| EQ 预设**按输出设备自动切换** + 自动 headroom | **强**（`eq_device_*`、`eq_headroom_note`） | 纯客户端、不依赖后端，体积小、体感强 |
| **播放时间段（A-B 段）+ 自动高潮定位** | **强**（`playback_range_*` 17 条 + `playback_range_highlight`） | 对有声书/播客场景价值高，客户端可独立实现 |
| **歌词偏移 + 打轴编辑 + 多源切换** | **强**（`lyrics_offset_*`、`lyrics_editor_*` 74 条、`lyrics_sources_*`） | Overtone 已有歌词基础，补齐编辑/偏移是渐进式增强 |
| **交叉淡化「智能 vs 固定」+ 未缓存退化为直切** | **强**（`crossfade_mode_smart`、`crossfade_footer`） | 若 Overtone 只有固定淡入，这是低成本的「聪明感」提升 |
| **统计双数据源 + 服务端能力边界诚实标注** | **中强**（`stats_server_*` 28 条） | 对 Jellyfin 场景特别相关：Jellyfin 的统计能力有限，需如实降级 |
| **年度报告 / 音乐人格** | **中**（`yearly_*` 101 条，16 人格矩阵） | 数据全在服务端历史里即可算，纯展示层，但工作量大 |
| **设置搜索 + 可用性约束提示** | **中**（`SettingsSearch.strings` 74 条） | 设置项一多就必需，Overtone 设置面正在扩张 |
| **Utter 级 Mac 集成：菜单栏歌词 / 桌面歌词** | **中**（`desktop_*`、`menu_bar_lyrics`） | macOS 专属差异化，Overtone 同为 SwiftUI Mac 应用，移植性尚可 |
| AI 多服务按功能路由 | **弱（不建议照搬）** | 与 Overtone 定位不符，且需中继/额度/App Attest 全套基础设施 |

---

## 7. 未确认 / 边界说明

1. **CarPlay / Apple TV / iPhone 专属能力**（`carplay_*` 160、`tv_*` 70、`player_*` 中大量 iPhone 文案）来自共享字符串表，**macOS 端是否呈现未确认**；Mac 包内无 CarPlay entitlement。
2. **推送通知**：有 `aps-environment` entitlement，但**未找到**通知类型/文案 key，具体用途未确认。
3. **AirPlay 视频投屏 / Chromecast**：未确认。
4. **S3 对象存储**：仅有 `source_diag_config_missing_bucket` 一处证据，是否为正式支持的音乐源类型**未确认**。
5. **115 网盘**：`PrimuseU115ClientID` 为空字符串，二进制有 `proapi.115.com/open/*` 端点 → **代码已实现但当前版本未启用**（推断，非确认）。
6. **EQ 各 band 的具体中心频率**：`EQPresets.json` 只给 10 个增益值，不给频率；`"10-Band Equalizer"` 确认段数，频点**未确认**。
7. **开源许可页列出的精确组件版本**：只读到描述性条目（「音频解码引擎」「附加格式解码」「SMB / CIFS 连接」等），版本号未逐条提取。
8. **UI 实际布局/交互细节**：本次是资源与二进制层分析，未运行应用、未截图；「界面上大概长什么样」依据文案推断，可能与时序 UI 有偏差。
9. **字符串中的测试夹具 key**（如 `"December Exclusive · STATS-05"`、`"C-07 · Newly Written Credentials"`、`"Shui Diao Ge Tou · FLAC 988 kbps"`）确认为设计/测试用例文案，非功能能力。

---

*本文所有 key 均可在 `/tmp/primuse-research/zh-*.strings`（由 `/Applications/Primuse.app/Contents/Resources/*.lproj/*.strings` 转码得到，未改动原件）中直接检索复现。*
