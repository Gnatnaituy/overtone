# 飞牛音乐（fnOS Music）协议事实档

> 目的：为「Overtone（macOS / SwiftUI / AVPlayer）接入飞牛云 NAS 的飞牛音乐」这一工作量评估提供**协议事实基础**。
> 读者：要动手写 Swift 网络层与播放层的人。
> 结论先行：**只读接口 34 个（MVP 需 12 个），音乐侧写接口 15 个，收藏/歌单/事件上报齐全，但「播放进度同步」不存在**；最大的两个不确定点是 **authx 是否真的必需** 与 **duration 字段单位不统一**。
>
> 计数口径：只读 = §3.1–3.7 表格内端点（不含 §3.8 管理只读 6 个）；写 = §5 音乐侧端点（不含管理侧 12 个）。

**这不是官方文档。** fnOS / 飞牛音乐没有公开 API 契约，路径、签名常量、字段都可能在 NAS 升级后改变。

---

## 0. 怎么用这份文档

### 0.1 证据等级

沿用 `seasonyuu/FnMusic` 的标注体系：

| 标记 | 含义 | 本档判据 |
| --- | --- | --- |
| **V** | 协议实测 | 有客户端跑过真实 HTTP 并拿到状态码/响应头/业务码 |
| **S** | 静态包或实现确认 | 官方 Web 静态包、或可用的第三方客户端实现里明确出现 |
| **A** | 浏览器观测 | UI 交互触发过该请求 |
| **B** | 行为推断 | 按名字或上下文推断，未取得完整协议 |
| **C** | 待验证 | 实现需要，但证据不足；文中给出兜底方案 |

**本档的特别之处：有 4 个可用的第三方客户端实现可交叉验证**，互不一致处我会明确写「两说」而不是取其一。

### 0.2 素材（全部只读克隆于 `/tmp/fnresearch`）

| 代号 | 仓库 | 语言 | 价值 |
| --- | --- | --- | --- |
| **[api.md]** | `seasonyuu/FnMusic` → `api.md`（962 行） | — | 核心协议文档，附 `verify_api.py` / `verify_fn_connect.py`，实测 `41 PASS / 0 FAIL`。**本档主要骨架** |
| **[kotlin]** | `seasonyuu/FnMusic` → `core/network/...` | Kotlin/Retrofit | 权威端点清单（`@GET/@POST` 注解）+ DTO 默认值 |
| **[dart]** | `XDORG-N1/FnMusic` → `lib/app/services/feiniu/*.dart` | Dart/Flutter | 完整业务实现（3628 行），**不签 authx**，有 CUE/转码/安全码 |
| **[ps5]** | `naye1120/fnmusic-ps5` → `src/fnos/*.cpp` | C++/libcurl | **令牌续期**、Range 读取、duration 单位坑 |
| **[primuse]** | `chenqi92/primuse` → `PrimuseKit/.../Streaming/*.swift` | **Swift** | **已在 macOS/iOS 上线**的飞牛音乐源：authx 的 Swift 实现、FN Connect 解析、AVPlayer 处理 |
| **[ext]** | `javycoder/fnos_music_ext` | Python | 反向代理官方 Web，佐证新版前端行为（`authx` 逐请求、临时令牌头） |
| **[open]** | `sscrl/open-fnmusic` | Kotlin | 无在线接口，**对本档无贡献**（已核实） |

> ⚠️ 关于 **[ext]**：它在自己的服务上**注册了 `/music/api/v1/track/url`、`/music/api/v1/track/audio-info`、`/music/api/v1/play-history/delete`** 等路由。这些是**扩展自己的接口，不是 fnOS 上游接口**（`@app.get("/music/api/v1/track/audio-info")` 明确注册在它自己的 FastAPI 里）。不要当成飞牛能力。

### 0.3 占位符

`{host}` NAS 域名或 IP ｜ `{fnId}` FN ID ｜ `{relay}` 中继域名 ｜ `{trackGuid}` `{albumGuid}` `{artistGuid}` `{genreGuid}` `{playlistGuid}` 业务 GUID ｜ `{coverId}` 封面标识 ｜ `{q}` 搜索词

---

## 1. 入口与基址

### 1.1 两种入口

飞牛音乐只有两种可达方式：

```text
A. 自定义域名/直连（推荐，协议最简单）
   https://{host}/music/            ← 用户在浏览器里看到的
   https://{host}/music/api/v1/...  ← 真正的 API 基址

B. FN Connect（厂商的远程访问）
   https://{fnos.net 或 5ddd.com}/{fnId}/music/   ← 只是引导页，不能直接当 API 基址
```

**关键事实：`https://fnos.net/{fnId}/music/api/...` 不会代理音乐 API**，直接请求返回 FN Connect 的 HTML 而非 JSON（V）。FN Connect 必须经过「定位 → 选路 → relay 激活」才能拿到真正基址。

对 Overtone 的意义：**第一版只做 A**。自定义域名下没有 relay、没有引导页、没有 `mode=relay` cookie，整个 §1.3 的工作量为零。FN Connect 是可选的第二阶段。

### 1.2 基址规范化

三种输入都要能收敛到同一个基址（S，[ps5] `Api::set_server` / [primuse] `serverBaseURL` 都做了这件事）：

| 用户输入 | 归一化结果 |
| --- | --- |
| `nas.example.com` | `https://nas.example.com/music/api/v1`（按 useSSL 选 scheme） |
| `https://nas.example.com/music/` | 同上（去尾斜杠，补 `/api/v1`） |
| `https://nas.example.com/music/api/v1` | 原样（**别再重复拼**） |
| `http://192.168.1.10:5667/music` | `http://192.168.1.10:5667/music/api/v1` |
| 反代前缀 `https://x.com/nas/music/` | 保留前缀，**但签名路径要截到 `/music/api/v1/...`**（见 §2.1.4） |

[primuse] `endpointURL` 的判定顺序值得抄：`path` 已 `hasSuffix(apiPath)` → 不动；`hasSuffix("/music")` → 补 `/api/v1`；否则 → 补 `/music/api/v1`。

### 1.3 FN Connect（可选阶段，工作量集中区）

#### 1.3.1 定位（FN ID → 候选地址）

两个**不同**的定位主机，两个客户端各用一种，都能用：

| 主机 | 需要什么头 | 证据 |
| --- | --- | --- |
| `https://fnos.net/api/v1/fn/con` | `authx` + **`fn-sign`** | V（[api.md]） |
| `https://5ddd.com/api/v1/fn/con` | **只要 `authx`** | S（[primuse]、[dart] 都只发 authx） |

> `5ddd.com` 是 FN Connect 的老域名，`fnos.net` 是现在的品牌域名；relay 主机的白名单两个都要（[primuse] `relayCandidate` 明确只接受 `.5ddd.com` / `.fnos.net` 后缀）。

```http
POST /api/v1/fn/con
Content-Type: application/json
authx: nonce={6位}&timestamp={unix毫秒}&sign={md5}
fn-sign: {sha256}          ← 仅 fnos.net 路线
{"fnId":"{fnId}"}
```

定位签名（V，[api.md] §4.3；[dart] `_computeAuthx` 同）：

```text
AUTHX_PREFIX       = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
FN_CONNECT_API_KEY = "zIGtkc3dqZnJpd29qZXJqa2w7c"

body      = {"fnId":"{fnId}"}                    ← 紧凑 JSON，无空格
bodyHash  = MD5_UTF8(body)
signing   = PREFIX + "_/api/v1/fn/con_" + nonce + "_" + timestamp + "_" + bodyHash + "_" + FN_CONNECT_API_KEY
authx.sign = MD5_UTF8(signing)

fn-sign   = SHA256_UTF8("trim_connect`{fnId}`{timestamp}`anna")   ← 同一 timestamp
```

> ⚠️ 音乐 API 的 key 是 `6D5602D4-A342-4799-A0F0-BB795E7167D0`，**定位用的是 `zIGtkc3dqZnJpd29qZXJqa2w7c`**，两个不能混。

响应 envelope（V）：

```json
{"code":0,"msg":"...","data":{
  "ver":"...","checkSum":"...",
  "fn":[...],          // FN Connect HTTPS relay 候选
  "ddns":[...],        // NAS 自配 DDNS
  "publicIpv4":[], "publicIpv6":[],
  "ipv4":[], "ipv6":[],
  "port":{"httpPort":5666,"httpsPort":5667},
  "forbbidPublicIpv6":false
}}
```

`port` 缺省时 **http=5666 / https=5667**（S，[dart]、[primuse] 双向印证；注意 `forbbidPublicIpv6` 是**厂商拼写错误**，照抄）。

`code` 语义（S，[primuse] `lookup`）：

| code | 含义 |
| --- | --- |
| `404 / 1001 / 1004 / 3000006 / 3000037` | FN ID 不存在 |
| `3000009` | 定位服务不可用 |
| 其它非 0 | 响应异常 |

#### 1.3.2 选路与探测

[primuse] 的候选分组顺序（S），**和 [dart] 基本一致**：

```
[内网 IPv4+IPv6 (http)] → [内网 https] → [公网 IPv6 (https)] → [公网 IPv4 (https)] → [ddns] → [relay]
```

两个实现都刻意对**内网用 http 优先、https 兜底**，理由写得很直白：内网 IP 多是自签证书，http 直接绕开证书校验。公网/relay 一律 https。

探测超时（S，可照抄）：内网 `2s`、中继 `10s`、定位请求 `10s`。

#### 1.3.3 relay 激活 —— 比 api.md 描述的简单

[api.md] 描述的流程：请求 `{relay}/music/` → `302` + `Set-Cookie: mode=relay` → 再请求得 HTML。

[primuse] 的做法是**直接带上 `Cookie: mode=relay`**，不请求引导页、不等 302：

```swift
// [primuse] authenticationCookie(token:usesRelay:)
values = []; if let token { values.append("music-token=\(esc)") }
if usesRelay { values.append("mode=relay") }
// → "music-token=...; mode=relay"
```

两种说法并不冲突（服务端是「看到 mode=relay 就转发」），但**哪一种在特定固件上都需要实测**。建议实现成：先直接带 `mode=relay` 试一次；若被 302 回 `fnos.net/{fnId}/...`，再走引导页握手。标 **B/C**。

> relay 失效的判定（V，[api.md] §11.1）：**API 返回 HTML 而不是 JSON** = relay 掉了，重新定位。

### 1.4 端口、证书

| 项 | 值 | 证据 |
| --- | --- | --- |
| fNOS 默认 http / https 端口 | `5666` / `5667` | S（[dart]、[primuse]） |
| 自定义域名 | 通常 443 + 反代 | B |
| relay | 恒 `443` | S |
| 证书 | **自签**（除非用户自己装了证书） | S（[ps5] 注释明确写了这点） |

**macOS 侧证书处理**：
- [ps5] 直接关校验（`CURLOPT_SSL_VERIFYPEER=0`），并注明「家用局域网可接受」。
- [primuse] 走 `URLSessionDelegate` 的 `URLAuthenticationChallenge` 自定义信任策略（`TVServerTrustPolicy`）。
- **Overtone 已有现成的解**：`scripts/build-app.sh:66-70` 已写入

  ```xml
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/>
        <key>NSAllowsLocalNetworking</key><true/></dict>
  ```

  即 ATS 已全开，**明文 http 到局域网 IP 可直接用**；自签 https 仍需 `URLSessionDelegate` 放行。→ §1.4 对 Overtone 的增量工作量≈一个小 delegate（自签 https 才需要；纯 http 直连不需要）。

### 1.5 分阶段建议

| 阶段 | 覆盖 | 增量 |
| --- | --- | --- |
| P0 | 自定义域名（http 内网 / https 反代） | 基址归一化 + 登录 |
| P1 | 自签 https 信任弹窗 | 一个 `URLSessionDelegate` |
| P2 | FN Connect（`5ddd.com` → 探测 → relay） | **本档最大的独立工作块**，可后置 |

---

## 2. 认证与会话

### 2.1 `authx` 请求签名 —— 先回答「要不要做」

这是**全档最重要的判断题**，因为它决定 §7.6 的播放层工作量。

| 客户端 | 是否对音乐 API 签 authx | 状态 |
| --- | --- | --- |
| [api.md] / [kotlin] | ✅ 每个请求都签 | **V**，`41 PASS` 实测通过 |
| [primuse]（Swift，面向 macOS/iOS/tvOS 的完整客户端） | ✅ 每个请求都签 | **S**，代码 + 单测都在 |
| [dart]（Flutter） | ❌ **不签**，只带 Cookie | **S**，全仓仅 `fn_connection_probe_service.dart` 用 authx（且仅用于 FN 定位） |
| [ps5]（C++） | ❌ **不签**，只带 Cookie | **S**，`Api::auth_headers()` 只产出 `Cookie: music-token=...` |

**判读**：两个第三方实现完全不签名也能正常读写登录/曲库/收藏/播放，说明**当前固件对音乐 API 并不强制 authx**（或仅对部分部署/开关强制）。但官方 Web 前端与另外两个客户端都在签。

**建议**：
1. **按「不强制但会变」设计**：把签名抽成 `FnAuthxSigner` 协议，`NoopSigner` 与 `RealSigner` 两实现，开关放在诊断页。
2. **先做 Noop**（工作量≈0），联调时若遇 401/403 再切 Real。
3. **Real 实现成本很低**（≈60 行 Swift，见 2.1.3），别省——它是应对固件升级的保险。

证据等级：**「不签能用」= S；「未来是否强制」= C**。

#### 2.1.1 常量（⚠️ 脆弱点）

```text
AUTHX_PREFIX   = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"      // 音乐 API 与 FN 定位共用
MUSIC_API_KEY  = "6D5602D4-A342-4799-A0F0-BB795E7167D0" // 音乐 API 专用
```

来源：官方 Web 静态包。**它们不是用户凭据，也不能视为稳定契约**——fnOS 升级换代时最可能先变的就是这两个常量（见 §8 尾部「维护成本」）。

#### 2.1.2 签名算法（音乐 API）

```text
authx: nonce={6位数字}&timestamp={unix毫秒}&sign={32位小写md5}
```

```text
signingText = PREFIX + "_" + requestPath + "_" + nonce + "_" + timestamp + "_" + dataHash + "_" + MUSIC_API_KEY
sign        = MD5_UTF8(signingText)
```

- `requestPath` = **完整 URL pathname**，含 `/music` 前缀 → `/music/api/v1/track/list`（V，[api.md] 明确警告不能只签 `/api/v1/...`）。
- `nonce` = `100000...999999`，每次请求新取。
- `timestamp` = 毫秒字符串。

#### 2.1.3 `dataHash` 的两种规则

**GET**（把 query 规范化后哈希）：

1. 取 query 参数
2. **丢弃**值为字符串 `"undefined"` 或 `"null"` 的参数
3. **按参数名排序**
4. 用 URLSearchParams 编码（空格→`+`）
5. `+` → `%20`
6. 对整个 query 串 `decodeURIComponent`
7. 对结果做 `MD5_UTF8`

```text
URL:        /music/api/v1/track/list?size=50&page=1
canonical:  page=1&size=50
dataHash:   MD5_UTF8("page=1&size=50")
```

**非 GET**：`dataHash = MD5_UTF8(JSON.stringify(body))`（紧凑、无空格、UTF-8、不转义中文）。无 body 时 `MD5_UTF8("")`。
**签名用的 JSON 必须与实际发出的字节完全一致**——不要签格式化 JSON 再发紧凑 JSON。

**Swift 参考实现**（照抄 [primuse]，其单测覆盖签名正确性）：

```swift
// GET: 排序 → 用 unreserved 集百分号编码 → + 还原空格 → 整体解码 → MD5
static func canonicalQuery(_ items: [URLQueryItem]) -> String? {
    guard !items.isEmpty else { return nil }
    return items.enumerated()
        .sorted { $0.element.name == $1.element.name
                  ? $0.offset < $1.offset
                  : $0.element.name < $1.element.name }
        .map { _, i in
            let n = i.name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? i.name
            let v = (i.value ?? "").addingPercentEncoding(withAllowedCharacters: unreserved) ?? (i.value ?? "")
            return "\(n)=\(v)"
        }.joined(separator: "&")
}
// unreserved = "A-Za-z0-9-._~"

func authxHeader(method: String, path: String, queryItems: [URLQueryItem],
                 bodyData: Data?, nonce: String, timestampMs: Int64) -> String {
    let payload: Data
    if method.uppercased() == "GET" {
        let enc = canonicalQuery(queryItems) ?? ""
        let plus = enc.replacingOccurrences(of: "+", with: " ")
        payload = Data(((plus.removingPercentEncoding) ?? enc).utf8)
    } else { payload = bodyData ?? Data() }

    let hash = Insecure.MD5.hash(data: payload).hex
    let src  = [PREFIX, path, nonce, String(timestampMs), hash, KEY].joined(separator: "_")
    return "nonce=\(nonce)&timestamp=\(timestampMs)&sign=\(Insecure.MD5.hash(data: Data(src.utf8)).hex)"
}
```

#### 2.1.4 反代前缀的处理（易错）

[primuse] `authxPath(for:)` 的做法：**取 path 中最后一次出现的 `/music/api/v1` 起算**。

```
https://x.com/nas/music/api/v1/track/list  →  签 "/music/api/v1/track/list"
```

服务端只认规范 API 路径。若把整个 `/nas/music/api/v1/...` 拿去做签名串，会稳定 401。**S**。

### 2.2 登录

```http
POST /music/api/v1/user/password-login
Content-Type: application/json
authx: ...            ← 若启用签名；两个不签的客户端此处也不签

{"username":"{用户名}","password":"{sha256Hex}","deviceId":"{32位hex}"}
```

- `password` = `SHA256_UTF8(明文密码)` **小写 hex**（S，四个客户端一致）。
- `deviceId` = 32 位 hex（见 2.5）。
- 登录请求本身也带 `authx`（V，[api.md]）。

成功响应（V）：

```json
{"code":0,"msg":"...","data":{"user":{...},"userToken":"{token}"}}
```

> **服务端不会 `Set-Cookie`**。非浏览器客户端必须自己从 `data.userToken` 取 token 并写入 Cookie（V，[api.md] §6.1；[primuse]、[dart]、[ps5] 全部自己拼）。

**登录可能返回 3xx**：服务端强制 HTTPS 时，登录 POST 会回 3xx 而不是 JSON。必须单独识别并提示用户检查「HTTPS 设置」，否则会误报为「密码错误」（S，[ps5] `sign_in_with`）。

业务错误码：`120001` = 账号或密码错误（V）。

### 2.3 `music-token` Cookie

```text
Cookie: music-token={urlEncodedToken}
FN Connect 下：Cookie: music-token={token}; mode=relay
```

- 编码规则（S，[primuse]）：token 按 unreserved 集百分号编码，再把 `%20` 变回 `+`。
- 该 Cookie 必须随**三类请求**都发：`api/v1/*` JSON、`static/cover` 封面、`track/stream` 音频（V）。
- [dart] 实现里直接把它作为 `Cookie` **请求头**手工设置（不依赖系统 CookieJar），跨平台最省心。**推荐 Swift 侧照做**，别用 `HTTPCookieStorage`——relay/直连两套域名会让 Cookie 作用域变得很烦。

### 2.4 安全码（`x-access-code`）—— api.md 未覆盖

NAS 若开了「安全码」（访问口令），**所有请求**还要加两个头（S，[dart] `access_code_service.dart`、[primuse] `accessCodeHeaders`）：

```http
x-access-code: base64(安全码)
x-access-source: app
```

校验端点（S，[primuse]）：

```http
GET {host}/access_code_verify
→ 2xx / 404 : 通过（404 表示旧固件没有此端点）
→ 401/403/429 : 需要安全码 / 安全码错误 / 被限流
```

注意它在**站点根**，不在 `/music` 下。对 Overtone 的意义：如果目标用户开了安全码，缺这两个头会一直 401/403 而看不出原因——**建议 P1 就支持**（约 20 行）。

### 2.5 设备号 `deviceId`

- 32 位 hex，`UUID` 去掉横线即可（S，[primuse]）。
- **一台设备一个、持久化**（`UserDefaults` / `Keychain`），不要每次请求随机生成（V，[api.md]）。
- **语义坑（重要）**：`[primuse]` 注释写明「**飞牛同一个设备号只认最后一次登录，所以同一台设备上的会话必须共用**」。即 `deviceId` 是「设备身份」而非「会话身份」，用同一个 deviceId 并发登录会互踢。→ 实现上**全 App 共用一份 deviceId、共用一份 token**，别为播放器另开一套登录（[primuse] 专门为此写了 `SourceLoginSessionStore`）。标 **S**（注释级证据，非实测）。

### 2.6 过期与保活 —— api.md 的未解问题，这里给出答案

**在 [ps5] 的实现里没有 refresh token、没有续期接口**；服务端会话失效后**用保存的密码摘要重新登录**是最小可行的保活方式（**S**：实现如此；api.md 仍把「续期接口」列为待验证，即不排除固件另有 refresh 端点）：

```text
收到 401/403  →
  若本次请求本就带着 Cookie（had_session）且已有 username+passwordHash+deviceId →
    重新 POST /user/password-login（同一 deviceId）→ 拿新 userToken → 重试原请求一次
  否则 → 登出
```

[ps5] 的关键设计，值得照抄：

- **只在「发出去的会话被拒」时续期**，不能因为手里有凭据就把一个没带 Cookie 的请求签进去（登出后不该自动复活）。
- **最多续期一次**，防死循环。
- **密码摘要视为可重放凭据**：登录时就把 `sha256(密码)` 留住，续期时直接复用，不必让用户再输密码（[ps5] `login_hash_`；[primuse] `SourceLoginSessionStore`）。
- 传输层再重试：`[ps5]` 允许 1 次 300ms 后的传输重试。

**会话校验收哪里？**
- [api.md] 明确：**不能**用 `/sys/config` 判断会话有效——它在失效会话下也能成功返回（V）。必须用受保护端点。
- [dart] 用 `GET /track/list?page=1&size=1` 判活（超时/断网视为离线、保留会话）。
- [primuse] 用 `/user/me`。
- 建议：**`/user/me`**（语义最正，代价一次小请求）。

**业务码也可能表示会话失效**（S，[primuse]）：HTTP `401/403`，**或** envelope `code ∈ {99999, 120001, 401, 403}`。HTTP 200 + `code!=0` 是常态，**只看 HTTP 状态会漏判**（V，[api.md]）。

### 2.7 重定向策略

[primuse] `FnMusicRedirectPolicy`（S）值得直接抄：

- 只跟**同 host** 的重定向；
- 禁止 `https → http` 降级；
- 端口必须一致；
- 重定向后**重新生成 authx**（签名含路径与 query！）；
- 只保留 `Cookie`、`x-access-code`、`x-access-source`、`Accept`、`Range` 等头。

否则：登录 POST 撞上反代的 301 会让 authx 失效，range 请求会丢 `Range` 头。

---

## 3. 只读接口表

基址统一 `https://{host}/music`；下表路径均相对于它。分页默认 `page`/`size`（**从 1 开始**）。响应统一 envelope：

```json
{"code":0,"msg":"","data":{...}}
```

### 3.1 初始化与配置

| 方法 | 路径 | 参数 | data 字段 | 证据 |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/initialization/state` | — | `initialized` | V+S |
| GET | `/api/v1/sys/config` | — | `mediasrvVersion` `nasOAuth` `serverGUID` `serverName` `serverVersion` | V+S |
| GET | `/api/v1/user/me` | — | `createdAt` `guid` `lastAccessedAt` `name` `role` `updatedAt` | V+S |
| GET | `/api/v1/shared-library/list` | — | `list[]`（见 §6.4） | V+S |
| GET | `/api/v1/task/list` | — | `list[]`（扫描任务，见 §6.4） | V+S |

> `role` ∈ `admin` / `member`（S）。`serverVersion ≥ 1.0.10` 才有「授权文件夹」入口（S，[api.md]）。**只读实测**：全部 200 + `code=0`。

### 3.2 曲目

| 方法 | 路径 | 参数 | data 字段 | 证据 |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/track/list` | `page` `size` `sort` | `list[]` `total` `sort` | V+S |
| GET | `/api/v1/track/metadata` | `guid` | `track`（**单个对象**） + `audioSpec` | V+S |
| GET | `/api/v1/track/album-detail/list` | `albumGUID` `page` `size` | `list[]` `total` `sort` | V+S |
| GET | `/api/v1/track/artist-detail/list` | `artistGUID` `page` `size` | `list[]` `total` `sort` | V+S |
| GET | `/api/v1/track/playlist-detail/list` | `playlistGUID` `page` `size` | `list[]` `total` `sort` | V+S |
| GET | `/api/v1/track/genre-detail/list` | `genreGUID` `page` `size` | `list[]` `total` `sort` | **S（仅 [ps5] 实现）** |

> **`genre-detail/list` 是 api.md 明确说「尚未发现」的接口**，[ps5] 实现了它（`/track/genre-detail/list?genreGUID=...&page=1&size=500`）。**只有单一来源，标 S、需实测**；若 404，按风格筛曲的兜底方案见 §8。
> `track/metadata` 的 `track` 是**单个对象**不是数组（V）。
> 所有 `pageSize` 见 §7.2 的争议。

### 3.3 专辑 / 歌手 / 风格

| 方法 | 路径 | 参数 | data 字段 | 证据 |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/album/list` | `page` `size` `sort` | `list[]` `total` `sort` | V+S |
| GET | `/api/v1/album/detail` | `guid` | `artists[]` `barcode` `coverId` `createdAt` `guid` `name` `releaseDate` `trackCount` `updatedAt` | V+S |
| GET | `/api/v1/album/artist-detail/list` | `artistGUID` `page` `size` | `list[]` `total` `sort` | V+S |
| GET | `/api/v1/artist/list` | `page` `size` | `list[]` `total` `sort` | V+S |
| GET | `/api/v1/artist/detail` | `guid` | `albumCount` `coverId` `createdAt` `guid` `name` `trackCount` `updatedAt` | V+S |
| GET | `/api/v1/genre/list` | `page` `size` | `list[]` `total` `sort` | V+S |

> 风格列表项含 `trackCount` / `coverId`（S，[dart] `FnGenre`）。
> ⚠️ api.md 说「测试库风格列表为空」，但 [dart] 明确按 `trackCount`/`coverId` 解析——**说明其它部署上风格是有数据的**。

### 3.4 歌单

| 方法 | 路径 | 参数 | data 字段 | 证据 |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/playlist/list` | `page` `size` | `list[]` `total` | V+S |
| GET | `/api/v1/playlist/detail` | `guid` | `coverId` `createdAt` `guid` `name` `trackCount` `updatedAt` | V+S |
| GET | `/api/v1/playlist/batch-detail` | `guids`（**复数**） | `list[]` | V+S |
| GET | `/api/v1/playlist/purge-track-count` | `guid` | `total`（失效曲目数） | V+S |

> `batch-detail` 的**多 GUID 分隔格式仍未确认**（api.md 列为待验证）：[kotlin] 只传单个，[primuse] 未用。**兜底：只传一个 guid，或逐个 `detail`**。
> ⚠️ 注意参数名分裂：读列表用 `playlistGUID`，**写操作用 `guid`**（§5）。

### 3.5 搜索

| 方法 | 路径 | 参数 | data 字段 | 证据 |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/search/suggest` | `q` | `track` `album` `artist` `playlist`（分组建议） | V+S |
| GET | `/api/v1/search/track` | `q` `page` `size` | `list[]` `total` | V+S |
| GET | `/api/v1/search/album` | `q` `page` `size` | `list[]` `total` | V+S |
| GET | `/api/v1/search/artist` | `q` `page` `size` | `list[]` `total` | V+S |
| GET | `/api/v1/search/playlist` | `q` `page` `size` | `list[]` `total` | V+S |

> 参数名是 **`q`**（不是 `keyword`）——[ext] 的代理层为此专门写了兼容分支（`params.get("keyword") or params.get("q")`），说明确有客户端搞错。
> **搜索结果是分页结构 `{list,total}`，不是裸数组**——[dart] 注释记录了这个 TypeError 坑。
> 最短词长、结果上限、排序、高亮字段：**C**。

### 3.6 收藏 / 最近播放 / 漫游

| 方法 | 路径 | 参数 | data 字段 | 证据 |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/favorite-track/list` | `page` `size` | `list[]` `total` | V+S |
| GET | `/api/v1/play-history/list` | `page` `size` | `list[]` `total` | V+S |
| GET | `/api/v1/track/roam-start` | `deviceId` | `current` `next`，各 `{roamId, track}` | V+S |
| GET | `/api/v1/track/roam-next` | `deviceId` `relativeRoamId` | `previous` `current` `next` | S（[dart]、[kotlin]） |
| GET | `/api/v1/track/roam-previous` | `deviceId` `relativeRoamId` | 同上 | S（[kotlin]） |

> **漫游 = 飞牛的「随机播放」**：服务端随机给一首，用 `roamId` 串成一条链。对 Overtone 的「随机播放全部」可以直接用它，也可以本地 shuffle（更可控）。
> `size=-1` 在 [ps5] 里用于「取全部收藏」（`/favorite-track/list?page=1&size=-1`）——**B，需验证**；兜底是分页拉全。
> **没有「播放进度」接口**（见 §7.4）。

### 3.7 歌词 / 封面 / 音频流

| 方法 | 路径 | 参数 | data 字段 | 证据 |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/lyric/list` | `trackGUID` | `list[]` `preferred` | V+S |
| GET | `/api/v1/static/cover` | `coverId` `size` | **二进制** `image/jpeg` | V |
| GET | `/api/v1/track/stream` | `guid` | **音频字节流** | V |

**歌词**（S，[dart] `FnLyric` + [ps5] 一致）：

```json
"data": {
  "preferred": "{lyricGuid}",
  "list": [ {"guid":"...", "content":"[00:12.34]...LRC 文本...", "isLRC":true, "offset":0} ]
}
```

选取策略（两个客户端一致）：取 `list` 中 `guid == preferred` 的项，否则取第一项。
**C**：编码（是否含 BOM）、时间轴单位、翻译/多语言歌词、空歌词行为。

**封面**：
- `coverId` 自带前缀 `track_` / `album_` / `playlist_`（V）。
- **必须从列表/详情响应里读，不能拿 GUID 拼**（V，api.md 明确警告）。
- 响应头有 `Accept-Ranges` `Content-Length` `ETag` `Last-Modified` → **可做条件缓存**（V）。
- `size` 取值集合未知（[dart] 默认 300），**C**。

### 3.8 管理只读（Overtone 第一版不需要，列出以说明边界）

`/api/v1/app-center/authed-dir/list`、`/app-center/authed-dir/sub/list?parent=`、`/shared-library/detail?guid=`、`/user/list`、`/settings/user`、`/settings/server`（V，只读实测）。

---

## 4. 播放

### 4.1 原文件直链 + Range

```http
GET /music/api/v1/track/stream?guid={trackGuid}
Cookie: music-token={token}
Range: bytes=0-0
```

实测（V）：

```http
HTTP/2 206 Partial Content
Content-Type: audio/flac
Accept-Ranges: bytes
Content-Range: bytes 0-0/{totalBytes}
Content-Length: 1
ETag: ...
Last-Modified: ...
```

**要点**
- **服务端支持标准字节范围**，适合 AVPlayer seek / 断点续读。
- 拿总长最稳的方式：`Range: bytes=0-0` 读 `Content-Range` 的总字节数（[ps5] 就是这么干的）。
- **越界 Range 会 416**：`[ps5]` 踩过——请求 `bytes=12345-12344` 得 416，被解码线程当成网络错误，导致歌曲最后一秒报错、队列卡住。**实现必须把 range 末端 clamp 到 `total-1`**（S，含明确错误现象）。
- 完整请求（无 Range）返回 200 —— 逻辑上成立但 [api.md] 标为待验证（**C**）。
- 其它格式（mp3/aac）的 MIME：**C**。

### 4.2 转码 / HLS —— 真实存在，且是「兜底播放」的关键

> api.md §8.3 把转码列为「未验证」，但后续章节与 [dart]、[kotlin] 都已确认实现。这里以**实现为准**给出完整契约。

**发起**（V 实测 + S）：

```http
POST /music/api/v1/track/transcode
{"guid":"{trackGuid}","output":{"codec":"opus","bitrate":128,"channel":2}}
```

响应 `data`：

| 字段 | 含义 |
| --- | --- |
| `status` | `ready` / `success` 才可播；否则失败 |
| `errno` | 失败时给错误号 |
| `url` | 播放列表地址（[dart] 读 `data.url`，可能是相对路径） |

**取清单**（V，实测生成 Opus / 48 kHz / 双声道 / fMP4-HLS，约 126.5 kbps）：

```http
GET /music/api/v1/track/hls/{trackGuid}/preset.m3u8
```

**保活**（播放期间每 **10 秒**，V）：

```http
POST /music/api/v1/track/transcode/heartbeat
{"guid":"{trackGuid}","timestamp":{秒}}
```

**收尾**（切歌/停止时，幂等，V）：

```http
POST /music/api/v1/track/transcode/quit
{"guid":"{trackGuid}"}
```

**坑**
- **`codec:"aac"` 在当前服务返回 `errno 8192`，不可用**（V）。→ 转码目标实际只有 **Opus**。
- `url` 可能是相对路径，要按「基址 + 相对」解析（[dart] `resolvePlayUrl` 专门处理了尾斜杠陷阱：`/music/api/v1` 缺尾斜杠时相对解析会丢掉最后一段）。
- [dart] 的用法更简：`POST /track/transcode {"guid":...}`（**不带 output**），读 `data.url`。说明 `output` 可能可省、由服务端取默认档。**C**。

### 4.3 播放请求序列（浏览器观测）

```text
track/metadata → lyric/list → track/stream → event/report
```

四个都已协议验证（V）。播放器判定「已播放」后才上报 `track_play`；阈值/去重/重试由客户端决定，服务端幂等语义 **C**。

### 4.4 CUE 整轨（macOS 也必须处理）

飞牛对「整轨 + CUE」专辑会**按曲目拆成多条**（`isCue=true`，多首共享同一物理文件 → `audioSpec.path` 相同），**但 `/track/stream?guid=` 返回的是整个整轨文件，且响应里没有起始偏移字段**（S，[dart] `cue_service.dart` 注释）。

客户端必须自己算：

```text
同一 (album.guid, audioSpec.path) 镜像内
按 (discNo, trackNo) 排序
第 i 首起始偏移 = 前 i 首 duration 之和
```

[seek 到 offset，长度 = 本曲 duration]。对 AVPlayer 意味着**要用 `AVPlayerItem` 的 `forwardPlaybackEndTime` + seek**，且需自行处理「播到本曲终点就切下一首」。若不做，整轨专辑会变成一首超长曲目。**S**（有完整实现可参考）。

### 4.5 事件上报（播放统计）

```http
POST /music/api/v1/event/report
{"events":[{"eventType":"track_play","occurredAt":1700000000000,
            "payload":{"trackGUID":"{trackGuid}"}}]}
```

`occurredAt` = Unix **毫秒**。V+S。

> **只有 `track_play` 一种事件类型**——四个客户端、官方 Web 全部只发这一种（V/S）。见 §7.4。

---

## 5. 写接口

全部 `POST`，JSON body。**每条都需 Cookie（启用签名时还要 authx）**。

### 5.1 收藏

| 路径 | body | 证据 |
| --- | --- | --- |
| `/api/v1/favorite-track/create` | `{"trackGUID":"{trackGuid}"}` | V+A |
| `/api/v1/favorite-track/delete` | `{"trackGUID":"{trackGuid}"}` | V+A |

注意参数名是 **`trackGUID`**（大写 GUID）。重复创建/冲突语义 **C**。

### 5.2 歌单全生命周期（api.md 标注「全部通过」）

| 路径 | body | 备注 |
| --- | --- | --- |
| `/api/v1/playlist/create` | `{"name":"...","coverId":"..."}` | 名称 1–32 字符 |
| `/api/v1/playlist/edit` | `{"guid":"...","name":"...","coverId":"..."}` | |
| `/api/v1/playlist/add-track` | `{"guid":"...","trackGUIDs":["..."]}` | **批量** |
| `/api/v1/playlist/remove-track` | `{"guid":"...","trackGUIDs":["..."]}` | **批量** |
| `/api/v1/playlist/delete` | `{"guid":"..."}` | 不可恢复 |
| `/api/v1/playlist/purge-track` | `{"guid":"..."}` | 清理失效曲目 |
| `GET /api/v1/playlist/purge-track-count` | `?guid=` | 先查数量再清 |
| `POST /api/v1/static/cover/playlist` | `multipart`，字段名 **`file`** | 返回 `data.coverId` |

证据：V+S+A（含临时歌单全流程实测，`finally` 清理）。

**错误码**（V）：`160001` 名称已存在 · `160002` 数量达上限。
**封面**：JPG/JPEG/PNG/WEBP，Web UI 限 5 MiB；**签名时按 `JSON.stringify(FormData)` 即 `{}` 算**，不要对 multipart 二进制体签名（S，api.md 明确）。
**C**：重复添加/移除的幂等、并发覆盖、曲目重排（**Web 里未观测到重排端点**，即无上移/下移接口）。

### 5.3 其它写接口

| 路径 | body | 证据 |
| --- | --- | --- |
| `/api/v1/event/report` | 见 §4.5 | V |
| `/api/v1/user/passwd-change` | `{"password":"{sha256Hex}"}` | S |
| `/api/v1/track/metadata` | `{guid,title,album,artistGUIDs,genreGUIDs,year,trackNo,discNo,...}` | **S（仅 [kotlin] DTO）** |
| `/api/v1/track/transcode` `/heartbeat` `/quit` | 见 §4.2 | V |
| `/api/v1/shared-library/create` `/edit` `/delete` `/scan` `/scan-all` | 管理 | V(读)/S(写) |
| `/api/v1/search/index/rebuild`、`/task/cancel`、`/task/retry` | 管理 | S |
| `/api/v1/user/create` `/edit`、`/settings/user`、`/settings/server` | 管理 | S |

### 5.4 写接口完备性判定

音乐侧写接口共 **15 个**：收藏 2 · 事件上报 1 · 歌单 7（含封面上传）· 改密 1 · 曲目元数据 1 · 转码会话 3；另有管理侧写接口约 12 个（音乐库、用户、任务、设置），与「接一个音乐源」无关。

| 能力 | 状态 |
| --- | --- |
| 收藏增删 | ✅ 齐全 |
| 歌单增删改、加/移曲、清失效、封面 | ✅ 齐全（**无重排**） |
| 播放事件上报 | ✅ 只有 `track_play` |
| **播放进度 / 断点续播** | ❌ **不存在**（见 §7.4） |
| 专辑/歌手收藏 | ❌ 未见（只有 track 级） |
| 评分 / 播放计数 | ❌ 未见 |

---

## 6. 数据模型字段表

字段名大小写**逐字照抄**，本协议不做驼峰/下划线转换。

### 6.1 Track（曲目）

| 字段 | 类型 | 必需 | 说明 / 坑 | 证据 |
| --- | --- | --- | --- | --- |
| `guid` | String | ✅ | 不透明标识，**别解析** | V |
| `title` | String | ✅ | 可能为空 → 客户端兜「未知标题」 | V |
| `duration` | Int | ⚠️ | **单位不固定！** 见下方大坑 | V |
| `coverId` | String? | ⚠️ | 带前缀，用于 `/static/cover` | V |
| `album` | Object? | ⚠️ | `{guid,name,coverId,year?,trackCount?}` 内嵌简要专辑 | V |
| `artists` | Array | ⚠️ | `[{guid,name,coverId?}]`，**复数必有**；个别接口可能只给 `artist` 字符串 | V |
| `genres` | Array | ⚠️ | `[{guid,name,trackCount,coverId?}]` | S |
| `year` | Int? | ❌ | 曲目级年份 | S |
| `trackNo` / `discNo` | Int? | ❌ | 轨号/碟号（CUE 排序靠它） | S |
| `isCue` | Bool | ❌ | 整轨 CUE 拆分曲目标记（缺省 false） | S |
| `isFavorite` | Bool | ❌ | 缺省 false | V |
| `hasLyric` | Bool | ❌ | 缺省 false，决定要不要请求歌词 | V |
| `accessStatus` | Int | ❌ | **0/缺省=可播，非 0=不可播**：1/3 文件缺失，2/4 无权限，其余=不可用。**这是「歌单里有坏歌」的唯一信号**，必须处理 | S |
| `audioSpec` | Object? | ❌ | 见 6.5 | V |

**⚠️ 大坑：`duration` 单位不统一（S，[ps5] 注释 + [dart] 按毫秒）**

> 「服务器单位不固定：同一首 5 分钟的歌，一个接口给 300，另一个接口给 300000。判定阈值取 **20000**——没有 5.5 小时长的歌，也没有按毫秒算只有 20 秒的片段。」

```swift
// [ps5] 的归一化
let normalized = raw > 20000 ? raw / 1000 : raw   // 秒
```

[dart] 则**统一当作毫秒**（`FnTrack.duration` 注释「时长（毫秒）」）。

**两说并存 → 建议实现**：进入模型时就归一化成**毫秒**，用阈值判定；并把「按接口来源」当可疑项记录日志，联调时逐接口核对。**这是最可能引发「时长显示错乱 + 进度条乱跳」的字段**，标 **C（必须实测）**。

### 6.2 Album / Artist / Genre

| 模型 | 字段 | 证据 |
| --- | --- | --- |
| **Album**（`/album/detail`） | `guid` `name` `coverId` `artists[]` `barcode` `releaseDate` `trackCount` `createdAt` `updatedAt` | V |
| **Album**（列表项） | `guid` `name` `coverId` `year?` `trackCount?` | S |
| **Artist**（`/artist/detail`） | `guid` `name` `coverId` `albumCount` `trackCount` `createdAt` `updatedAt` | V |
| **Artist**（列表/内嵌） | `guid` `name` `coverId?` | V |
| **Genre** | `guid` `name` `trackCount` `coverId?` | S |

> ⚠️ **专辑的「年份」双轨**：列表项是 `year`（Int），详情是 `releaseDate`。[ps5] 把 `releaseDate` 直接 `int_of()` 当 year 用——若服务端给的是日期字符串，这会得到 0。**C**，别照抄。

### 6.3 Playlist

| 字段 | 类型 | 来源 | 证据 |
| --- | --- | --- | --- |
| `guid` `name` `coverId` `trackCount` | — | list / detail | V |
| `createdAt` `updatedAt` | Int（epoch，秒或毫秒**未定**） | detail | V |

> `updatedAt/createdAt` 的单位问题同 `duration`：`[dart]` 在 library 的 `contentLastChangedAt` 上做了 `> 1e12 ? 秒级归一 : 原值` 的处理（S），说明**这里确实秒/毫秒混用**。

### 6.4 User / Library / Task

| 模型 | 字段 | 证据 |
| --- | --- | --- |
| **User**（`/user/me`） | `guid` `name` `role`（`admin`/`member`） `createdAt` `updatedAt` `lastAccessedAt` | V |
| **Library**（`/shared-library/list`） | `guid` `name` `path` `metadataPreference` `autoDownloadLyric` `contentLastChangedAt` `accessStatus` `coverIds[]` | V+S |
| **Task**（`/task/list`） | `id` `type` `name` `total` `successCount` `failCount` `done` `retryable` `canceled` `cancelling` `canceledCount` `createdAt` `doneAt` `ext.libraryGUID` | V |
| **Directory**（授权目录） | `path` `name` `storageType`（0外接/1他人共享/2远程/3存储空间/4应用文件） `permission` `uname` `address` `comment` `username` | V |

`metadataPreference` 枚举：`local_preferred` / `cloud_preferred` / `local_only`（S）。
任务 `type` 枚举：`fileScan` / `cloudScrape` / `cloudScrapeCorrection` / `lyricDownload`（S）。

### 6.5 AudioSpec（音质信息，`track.metadata` / 列表项里）

| 字段 | 类型 | 说明 | 证据 |
| --- | --- | --- | --- |
| `bitDepth` | Int? | 位深（16/24） | S |
| `sampleRate` | Int? | 采样率（44100/96000） | S |
| `channel` | Int? | 声道数 | S |
| `bitrate` | Int? | 码率 | S |
| `codec` | String? | 编码（flac/alac/mp3/aac/dsd…） | S |
| `format` | String? | **容器/格式**（flac/m4a/dsf…），格式能力判定用它 | S |
| `duration` | Int? | 同 §6.1 单位坑 | S |
| `size` | Int? | 文件字节数 | S |
| `path` | String? | **物理文件路径**（CUE 分组的 key） | S |

> 判断「要不要转码」应该用 `audioSpec.format` + `audioSpec.codec`（见 §7.5），与 [dart] `transcode_service.dart` 的做法一致。

### 6.6 通用 envelope 与分页

```json
{"code":0,"msg":"","data":{...}}
```

- **成功 = HTTP 状态符合预期 AND `code == 0`**（V，api.md 强调：错签名/错登录体会得到 **HTTP 200 + 非 0 code**）。
- `msg` 通常是英文（如 `invalid arguments`），业务码更有用。
- 分页响应：`data = {list:[...], total:Int, sort?:String}`。
- **个别接口返回裸数组**，也有 `{items}`/`{rows}`/`{libraries}` 变体 → 解析器要容错（S，[dart] `_firstList` 兜底 4 种 key）。

**已知业务码汇总**

| code | 含义 | 证据 |
| --- | --- | --- |
| `100002` | InvalidArgs（参数缺失/格式错，如空 albumGUID） | S |
| `100005` | NotFound | S |
| `120001` | Unauthorized / 账号密码错误 | V |
| `160001` | 歌单名已存在 | V |
| `160002` | 歌单数量达上限 | V |
| `99999` | 会话失效（另一口径） | S（[primuse]） |
| `8192` | 转码 `errno`（AAC 不可用） | V |

---

## 7. 与 Jellyfin 概念的差异与坑

> 这一节是给「已经有 Jellyfin 客户端」的人看的：哪些能直接映射、哪些必须专门写。

### 7.1 标识符：`GUID` vs Jellyfin `Id`

| Jellyfin | 飞牛音乐 |
| --- | --- |
| `Id`（32 位 hex） | `guid`（不透明字符串，格式别假设） |
| 一个 `itemId` 走遍所有端点 | **同名概念、不同参数名**：`guid` / `trackGUID` / `albumGUID` / `artistGUID` / `genreGUID` / `playlistGUID` / `guids` |
| `ImageTags` 置图 | `coverId`（**带 `track_`/`album_`/`playlist_` 前缀，从响应读，不能拼**） |

**头号坑：参数名大小写不统一**（V，api.md 明确警告）：

```
/api/v1/track/metadata?guid=           ← 小写
/api/v1/lyric/list?trackGUID=          ← 大写
/api/v1/track/album-detail/list?albumGUID=
/api/v1/track/playlist-detail/list?playlistGUID=    ← 读
/api/v1/playlist/add-track   {"guid":"..."}         ← 写！反而变小写
/api/v1/playlist/batch-detail?guids=                ← 复数小写
```

→ **不要写任何自动大小写转换**，逐端点硬编码。

### 7.2 分页与排序：风格完全不同

| Jellyfin | 飞牛音乐 |
| --- | --- |
| `StartIndex` / `Limit` | **`page` / `size`（page 从 1 开始）** |
| 响应包 `{Items, TotalRecordCount}` | `{list, total, sort}` |
| `SortBy=SortName&SortOrder=Ascending` | `sort="字段,方向"`（如 `createdAt,desc`、`newTrackAddedAt,desc`） |
| 支持 `Fields=` 展开 | 无字段选择，返回什么解析什么 |

**`size` 上限是争议点**：

- [dart] 注释写「默认每页 50（size 上限）」，但代码里传 `size: 100`（靠 `paginateAll` 循环补齐）；
- [ps5] 直接传 `size=500`，且**不翻页**（`album_tracks` 只请求 page=1）；
- [primuse] 固定 `pageSize = 50`。

**判读**：服务端很可能**静默 cap**（比如 50 或 100），[ps5] 的「一次性 size=500」在曲目多的专辑上有**截断风险**。
**建议（务必照做）**：用「循环取页直到 `items.count >= total` 或返回空页」的防御式分页，`size` 取 50～100，并设页数上限防死循环。排序字段全集 **C**。

### 7.3 字段命名与嵌套

- 飞牛**把 album/artists 内嵌进 track**（Jellyfin 要单独请求或靠 `Fields`）→ 解析省事。
- 但 **`track/metadata` 返回 `{track, audioSpec}` 两层**，而列表项是**扁平的 track**（`audioSpec` 也可能出现在列表项里）。→ 同一个 `Track` 要能吃两种形状。
- 命名：`discNo`/`trackNo`（不是 `ParentIndexNumber`/`IndexNumber`）、`isFavorite`（不是 `UserData.IsFavorite`）、`hasLyric`、`accessStatus`（不是 `LocationType`）。
- 布尔字段大量**缺省即 false**，解码必须 `decodeIfPresent ?? false`。

### 7.4 缺失能力清单（**决定产品范围，请务必先看**）

| Overtone 现有（Jellyfin）能力 | 飞牛音乐 | 影响 |
| --- | --- | --- |
| **播放进度上报 / 断点续播 / 继续播放** | ❌ **不存在**。`event/report` 只接受 `track_play`（仅曲目 GUID，无 position/ticks） | 「继续播放」模块**无法移植**；播放进度只能**本地存**（[dart] 用 `SessionCache` 本地缓存，不是服务端状态） |
| 播放状态（`Played`/`PlayCount`）读写 | ❌ | 只能展示服务端的 `play-history` |
| 专辑/歌手收藏 | ❌（只有 track） | 收藏按钮只能放在曲目上 |
| 播放列表**重排** | ❌ 未观测到端点 | Overtone 的「上移/下移 + 双向同步」需降级为「删掉再按序重加」或只做本地排序 |
| `InstantMix` / 相似歌曲 | ⚠️ 只有 `roam`（服务端随机） | 随机播放可用 roam 或本地 shuffle |
| 服务端转码档位协商 | ⚠️ 只有 opus/128/2ch（AAC 报 8192） | 音质档位实际只有「原始 / 标准(opus)」两档 |
| 歌词时间轴结构 | ⚠️ 只有 LRC 文本（`content`） | 需自己解析 LRC |
| 图片多尺寸/多类型 | ⚠️ 只有 `coverId` + `size` | 无 `Backdrop`/`Logo`/`Banner` |
| 搜索高亮、用户数据过滤、`Fields` 展开 | ❌ | 只能拿全量再本地处理 |
| `PlaybackInfo` / `MediaSources` | ❌ | 无多版本/多码率选择概念 |
| 收藏/播放历史**分页之外**的增量同步（`Since`） | ❌ | 只能全量拉或按 `sort` 取最近 N |

### 7.5 macOS / AVPlayer 侧格式能力对照

飞牛是**文件直出**（`/track/stream` 给原文件字节），因此「能不能播」完全取决于 **AVFoundation 是否认这个容器/编码**。参照 [dart] `transcode_service.dart` 的黑白名单（Android/ExoPlayer 视角），换算到 macOS：

| 格式/编码 | AVPlayer (macOS 13+) | 处置 |
| --- | --- | --- |
| MP3 / AAC(M4A) / ALAC / AIFF / WAV | ✅ 原生 | 直连 |
| **FLAC** | ✅（macOS 11+ 原生支持） | 直连（注意：tvOS 上有「禁用 metadata block type 127」导致整首拒播的已知问题，macOS 侧 [primuse] 是绕开 AVPlayer 走 libFLAC 的——**需实测**） |
| Opus / Ogg 容器 | ⚠️ Opus-in-CAF 支持；**`.ogg` 容器基本不支持** | 直连试，失败转码 |
| **APE / WavPack(.wv) / DSD(.dsf/.dff) / DTS / TTA / WMA / Musepack / RealAudio** | ❌ | **必须走服务端转码**（这也是飞牛转码接口存在的意义） |
| MKA / MKV 音频 | ❌ | 转码 |
| EAC3/AC3/TrueHD/MLP 在多声道容器里 | ⚠️ 视声道/容器而定 | 失败即转码 |
| **服务端转码产物：Opus in fMP4 / HLS** | ⚠️ Apple 平台自 macOS High Sierra 起支持 HLS 内 Opus，**但需实测**（[api.md] 的验证是在 Android 上做的） | **P0 就要验**：若不支持，且 AAC 又报 8192，则**APE/DSD 用户无解** → 产品上要明确降级提示 |

**判定逻辑（建议）**：

```
format ∈ {flac, mp3, m4a, aac, alac, wav, aiff} → 直连
其它 → 可选：先试转码 /track/transcode → hls/preset.m3u8
```

**兜底**：转码失败就把该曲标为「当前设备无法播放」，不要静默跳歌（[dart] 是双引擎回退 + 转码兜底，macOS 没有多引擎可选，只剩转码一条路）。

### 7.6 对 AVPlayer 的影响 —— 本次评估最关键的不确定点

Overtone 现在是 `AVPlayerItem(url:)`（`MusicPlayerModel.swift:340`），token 塞在 query 里（`:478-480` 的 `api_key`）。**这套在飞牛上不能照搬**，原因：

**（a）飞牛的凭据在 Cookie 头里，query 里没有 token 参数**（无 `api_key` 概念）。

AVPlayer 无法给 URL 直接设请求头。可行手段只有两个：

| 方案 | 做法 | 能力 | 代价 |
| --- | --- | --- | --- |
| **A. `AVURLAsset` 选项** | `AVURLAsset(url:options:["AVURLAssetHTTPHeaderFieldsKey": headers])` | 头**只设一次**，对初始请求 + 后续所有 Range 请求都复用 | 小（几行）。**前提：头不需要随时间变化** |
| **B. `AVAssetResourceLoaderDelegate`** | 把 URL 换成自定义 scheme，拦截每个 `AVAssetResourceLoadingRequest`，自己用 `URLSession` 带新头去取字节再回填 | **每片都能重算头**，支持 seek | **大**（[primuse] 的 `TVStreamResourceLoader` 是 400+ 行，含并发、配额、range 校验、FLAC 修补） |

**（b）决定性变量就是 authx**：

- 若 **不签 authx**（§2.1，两个第三方实现都不签）→ Cookie 是**静态头** → **方案 A 就够**，播放层几乎零改动。
- 若 **必须签 authx** → authx 含 `nonce` + `timestamp`，**短期有效**。[primuse] 的代码注释把结论写死了：

  > 「飞牛音乐的 authx 含短时效时间戳。解析阶段给出的首个签名只能用于立即探测，**长曲播放或稍后 seek 时必须为 AVPlayer 发起的每个 Range 请求重新签名**。」

  即你必须走**方案 B**：每个 range 请求重新算 `nonce`/`timestamp`/`sign`。且因为**时间容差未知（C）**，还要处理「服务端认为时间戳过期」的中途 403 → 重新签名重试、必要时重新登录。

**结论（写给估工期的人）**：

| 情形 | 播放层工作量 |
| --- | --- |
| authx 不强制 | ≈ 1 个 `AVURLAsset` 封装 + Cookie 注入（半天级） |
| authx 强制 | 完整的 resource-loader 分片代理（[primuse] 规模：数天～一周，含 seek/切歌/错误恢复/并发） |

→ **P0 的第一件事应该是拿真机验一次「不带 authx 的 Range 请求能不能 206」**。这一个实验决定了几天的工期差。

**（c）其它 AVPlayer 相关**：

- `mode=relay` 也必须随 Cookie 一起发（FN Connect 场景）→ 同样是静态头，方案 A 可覆盖。
- 自签证书：AVPlayer 走的是系统网络栈，`URLSessionDelegate` 的信任策略**不一定**能覆盖 AVPlayerItem 的请求。若目标用户用自签 https，需实测；**建议 P0 只支持 http 内网 + 可信 https**。
- **CUE 整轨**需要 `forwardPlaybackEndTime` + `seek`，与 `AVPlayerItem` 生命周期管理耦合（见 §4.4）。
- 转码走 HLS：`.m3u8` 的分片请求**同样不受你控制** → 若开 authx，HLS 的每个分片也要签名，方案 B 同样适用（且 HLS 下 delegate 的坑更多）。这是「authx 强制」情形下第二个昂贵点。

### 7.7 其它坑（清单）

| # | 坑 | 处置 | 证据 |
| --- | --- | --- | --- |
| 1 | `duration` 单位不统一（秒/毫秒混） | 入模型归一化为毫秒，阈值 20000 | S |
| 2 | `size` 可能被静默 cap | 防御式翻页 | S/C |
| 3 | Range 越界 → 416 → 被误判网络错误 | range 末端 clamp 到 `total-1` | S |
| 4 | `accessStatus != 0` 的曲目不可播 | 灰显 + 禁止入队 + 整单播放时过滤（保留索引映射） | S |
| 5 | 同名歌单/上限 | 处理 `160001`/`160002` 给中文提示 | V |
| 6 | 业务码在 HTTP 200 里 | 必须双重判定 | V |
| 7 | `sys/config` 不能当会话校验 | 用 `/user/me` | V |
| 8 | 同一 `deviceId` 只认最后一次登录 | 全 App 共用一份 token | S |
| 9 | 参数名大小写 | 逐端点硬编码 | V |
| 10 | 封面 `coverId` 不能由 GUID 拼 | 从响应读 | V |
| 11 | `msg` 是英文 | 自建中文错误映射 | S |
| 12 | 时间戳字段秒/毫秒混 | 解析时按 `>1e12` 归一 | S |
| 13 | 整轨 CUE | 自算偏移 | S |
| 14 | 转码 AAC 不可用（8192） | 只用 opus | V |
| 15 | `codec`/`format` 可能缺省 | 缺省时不猜，直接直连试播 | S |

---

## 8. 未解问题清单（按「对工期的影响」排序）

| # | 问题 | 为什么重要 | 怎么验（约 10 分钟） |
| --- | --- | --- | --- |
| **1** | **不带 `authx` 的 `track/stream` + Range 能否 206？** | 决定播放层是「半天」还是「一周」（§7.6） | `curl -H "Cookie: music-token=$T" -H "Range: bytes=0-1" "$BASE/api/v1/track/stream?guid=$G" -o /dev/null -w '%{http_code}'` |
| 2 | `duration` 到底什么单位（逐接口） | 时长/进度条错乱 | 同曲对比 `track/list`、`track/metadata`、`album-detail/list` 三处的 duration |
| 3 | `size` 上限与超限行为 | 列表截断 | `size=500` 看 `list.count` 与 `total` |
| **4** | 会话有效期多长 / 有无上限 | 保活策略、用户重登频次 | 挂一个长跑脚本每小时打 `/user/me` |
| 5 | `track/genre-detail/list` 是否存在 | 风格页能否下钻 | 直接请求 |
| 6 | 转码 Opus/HLS 能否被 macOS AVPlayer 播 | APE/DSD 用户是否可用（§7.5） | 拿 `preset.m3u8` 在 AVPlayer 里试 |
| 7 | 签名时间容差 / nonce 重放规则 | authx 强制时能否长播 | 用旧 timestamp 发请求看是否 401 |
| 8 | `batch-detail` 多 GUID 分隔符 | 批量取歌单详情 | 试 `,` / `|` / 重复参数 |
| 9 | 歌单重排是否有端点 | 「上移/下移」能否同步 | 抓 Web 的 reorder 请求（api.md 说未观测到） |
| 10 | `playlist/*` 写操作幂等/并发语义 | 重试安全性 | 重复 add 同一 track 看是否去重 |
| 11 | 歌词编码/时间轴/翻译 | 歌词页 | 取多份样本 |
| 12 | `static/cover?size=` 合法取值 | 封面清晰度 | 试 100/300/600/1000 |
| 13 | 是否有 `favorite-album` / `favorite-artist` | 收藏粒度 | 探 `/api/v1/favorite-album/list` |
| 14 | 是否存在其它 `eventType`（如进度） | 「继续播放」可行性 | 抓官方 Web 播放 30 秒内的全部 `event/report` body |
| 15 | 自签 https 下 AVPlayer 是否可播 | 用户覆盖面 | 自签证书 NAS 上试 AVPlayerItem |
| 16 | 多用户/多库切换 | 多账号场景 | `/user/list` + 库 GUID 关系 |

---

## 9. 给实施者的最小可行调用序列

> 目标：**用最少的接口跑通「登录 → 浏览 → 播放 → 收藏」**。下面每一步都对应一次可 curl 的调用。伪代码用 Swift 风格。

### 9.1 最小接口集（12 个）

```
POST /user/password-login       登录
GET  /user/me                   会话校验
GET  /sys/config                服务器信息（可选）
GET  /track/list                曲库（分页）
GET  /album/list                专辑
GET  /artist/list               艺人
GET  /playlist/list             歌单
GET  /track/album-detail/list   专辑曲目
GET  /track/metadata            单曲详情（可选，列表已够）
GET  /lyric/list                歌词
GET  /static/cover              封面
GET  /track/stream              音频
── 写 ──
POST /favorite-track/create|delete
POST /event/report
POST /playlist/{create,edit,add-track,remove-track,delete}
```

### 9.2 步骤

```swift
// ── 0. 配置：只做自定义域名，别碰 FN Connect ─────────────────
// 输入 "nas.local" / "https://nas.example.com/music/" 都要收敛
func normalizeBase(_ input: String, useSSL: Bool) -> URL
// → {scheme}://{host}:{port}/music/api/v1
//   已含 /music/api/v1 → 不再拼；已含 /music → 补 /api/v1
//   反代前缀保留，但签名路径截到 "/music/api/v1/..."（§2.1.4）

// ── 1. 设备号：一次生成，永久持久化 ─────────────────────────
let deviceId = stored ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

// ── 2. 登录 ────────────────────────────────────────────────
let body = ["username": user,
            "password": SHA256.hash(Data(pw.utf8)).hex,   // 小写 hex
            "deviceId": deviceId]
POST  /user/password-login   (+ authx 可选, + x-access-code 可选)
// 识别 3xx → 提示「服务器要求 HTTPS」，别当密码错误
guard code == 0, let token = data["userToken"] else { throw }
// ⚠️ 服务端不 Set-Cookie，自己存 token

// ── 3. 会话校验（启动时）────────────────────────────────────
GET /user/me   → 200 & code==0 才算有效
// 失败判定：HTTP 401/403  或  code ∈ {99999,120001,401,403}
// 有效判定不能用 /sys/config（失效会话下也会成功）

// ── 4. 保活（无需 refresh token）──────────────────────────
// 401/403 且手里有 username+passwordHash+deviceId
//   → 重放 login（同 deviceId）→ 换新 token → 重试原请求 1 次
//   仅当「带 Cookie 的请求被拒」才续期；登出后不复活

// ── 5. 浏览（全部分页，防御式）──────────────────────────────
func pages<T>(_ path: String, _ q: [String:String]) async throws -> [T] {
    var page = 1, all: [T] = [], total = Int.max
    repeat {
        let d = try await get(path, q + ["page": "\(page)", "size": "100"])
        let items: [T] = d["list"]            // 兜底裸数组 / items / rows
        if items.isEmpty { break }
        all += items
        total = d["total"] ?? items.count     // total 可能是 0/缺失
        page += 1
    } while all.count < total && page <= 100  // 页数上限防死循环
    return all
}
tracks   = pages("/track/list")                 // sort="createdAt,desc" 试
albums   = pages("/album/list")                 // sort="newTrackAddedAt,desc" 试
artists  = pages("/artist/list")
playlists= pages("/playlist/list")
albumTracks = pages("/track/album-detail/list", ["albumGUID": g])   // 注意大写 GUID

// ── 6. 曲目规整（两个必须做的转换）──────────────────────────
track.durationMs = raw > 20000 ? raw / 1000 * 1000 : raw * 1000  // §6.1，逐接口核对
if track.accessStatus != 0 { markUnplayable(track) }             // §7.7#4

// ── 7. 封面 ────────────────────────────────────────────────
let url = base + "/static/cover?coverId=\(track.coverId)&size=300"
// 带 Cookie（+ authx 可选）；可用 ETag 做条件缓存

// ── 8. 歌词（可选）─────────────────────────────────────────
if track.hasLyric {
    let d = try await get("/lyric/list", ["trackGUID": track.guid])
    let lrc = d["list"].first(where: { $0.guid == d["preferred"] })?.content ?? d["list"].first?.content
    parseLRC(lrc)      // 自己解析 [mm:ss.xx]
}

// ── 9. 播放：先试「方案 A」，失败再上 resource loader ─────────
let streamURL = base + "/track/stream?guid=\(track.guid)"
let headers   = ["Cookie": "music-token=\(token)"]     // (+ "; mode=relay" 若走中继)
// 若确认 authx 必需 → 每片重签 → AVAssetResourceLoaderDelegate（§7.6 方案 B）

let asset = AVURLAsset(url: streamURL,
                       options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
player.replaceCurrentItem(with: AVPlayerItem(asset: asset))

// CUE 整轨：seek 到 offset，并把 forwardPlaybackEndTime 设为本曲终点（§4.4）

// ── 10. 播放事件上报（替代 Jellyfin 的进度上报）──────────────
// ⚠️ 只有「播放过」这一个事件，没有 position/ticks
POST /event/report
{"events":[{"eventType":"track_play",
            "occurredAt": Int(Date().timeIntervalSince1970 * 1000),
            "payload":["trackGUID": track.guid]}]}
// 进度条位置只能本地存（UserDefaults/SQLite），不要指望服务端续播

// ── 11. 收藏 ───────────────────────────────────────────────
POST /favorite-track/create  {"trackGUID": track.guid}
POST /favorite-track/delete  {"trackGUID": track.guid}

// ── 12. 歌单（注意写用 guid，读用 playlistGUID）──────────────
POST /playlist/create      {"name": name, "coverId": nil}
POST /playlist/add-track   {"guid": g, "trackGUIDs": [t1, t2]}
// 上限/重名：160001 / 160002
// 无重排接口 → 需要「顺序变更」时只能 remove 全部 + 按序 add
```

### 9.3 建议的落地顺序（可直接对工）

| 阶段 | 内容 | 依赖 | 相对工作量 |
| --- | --- | --- | --- |
| **S0 事实验证** | 跑 §8 的 1/2/3/4/6 五项（都有现成 curl） | 一台真 NAS | **0.5 天**（但决定后面全部） |
| S1 网络层 | 基址归一化 + 设备号 + 登录 + Cookie + 401 续期 + envelope 解码 | — | 1–2 天 |
| S2 只读模型 | Track/Album/Artist/Playlist/Genre + 分页 + 规整（duration/accessStatus） | S1 | 2–3 天 |
| S3 播放 | stream + AVURLAsset 头注入（+ CUE 偏移） | S0#1 | **0.5 天**（authx 不强制）/ **3–5 天**（强制，走 loader） |
| S4 写 | 收藏 + 歌单 CRUD | S2 | 1–2 天 |
| S5 源抽象重构 | 把 Overtone 的 Jellyfin 专用 `APIClient`/`MusicDataStore` 抽成 `MusicSource` 协议 | 与 S1–S2 并行 | 2–3 天（**存量代码，风险最高**） |
| S6 可选 | 转码回退（APE/DSD）、歌词页、FN Connect、安全码、管理页 | S3 | 2 天＋FN Connect 另算 3–5 天 |

> **S5 提示**：Overtone 目前是单一 executable target、`APIClient.shared` 单例 + `BaseItemDto` 直接进 UI（34 个 Swift 文件）。接第二个源必须先把「Jellyfin 形状」从 UI 层剥出来，否则会到处写 `if isFnMusic`。这部分**看起来不像工作量，实际最容易超期**。

### 9.4 自测用的最小 curl（换成自己的值）

```bash
BASE="https://nas.local/music/api/v1"        # 或 http://192.168.1.10:5666/music/api/v1
PW_HASH=$(printf '%s' 'your-password' | shasum -a 256 | cut -d' ' -f1)
DID=$(uuidgen | tr 'A-F' 'a-f' | tr -d '-')

# 登录
curl -sk -X POST "$BASE/user/password-login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$PW_HASH\",\"deviceId\":\"$DID\"}"
# → {"code":0,"data":{"userToken":"..."}}

T='<上一步的 userToken>'

# 会话校验
curl -sk "$BASE/user/me" -H "Cookie: music-token=$T"

# 曲库第一页
curl -sk "$BASE/track/list?page=1&size=50" -H "Cookie: music-token=$T"

# Range 探测（★ 决定播放层工期的那个实验：不带 authx 能否 206）
curl -sk -o /dev/null -w '%{http_code}\n' \
  -H "Cookie: music-token=$T" -H 'Range: bytes=0-1' \
  "$BASE/track/stream?guid=<trackGuid>"

# 封面
curl -sk -o /tmp/c.jpg "$BASE/static/cover?coverId=<coverId>&size=300" -H "Cookie: music-token=$T"
```

---

## 附录 A. 维护成本与脆弱性（读之前请先读这一节）

飞牛音乐是**非公开接口**，没有兼容性承诺。以下按「最可能先变」排序：

1. **静态签名常量** `AUTHX_PREFIX` / `MUSIC_API_KEY` / 定位用的 `FN_CONNECT_API_KEY`
   来自官方 Web 静态包（[api.md] 甚至记录了资源 SHA-256）。**fnOS 大版本升级后极可能变**。若 Overtone 选择「不签 authx」，这部分风险直接归零——这是「不签」方案的额外收益。
2. **签名算法本身**（拼串顺序、GET query 规范化细节）。
3. **参数名大小写**（`guid` / `trackGUID` / `guids` 已经够乱，再变一次不奇怪）。
4. **端点路径**（`genre-detail/list` 这类只在单一客户端出现的，最可能不存在或被改名）。
5. **字段单位**（`duration` 已经混了；`createdAt/updatedAt` 也是）。
6. **业务错误码**（已有 6 个口径，还会加）。

**工程建议（低成本、高回报）**：

- 把「签名」与「端点表」各自做成可版本化的独立单元，运行时读 `/sys/config.serverVersion` 记录到诊断日志；
- 提供一个**只读自检**（登录 + `/user/me` + 一页 `track/list` + 一次 Range 探测），让用户能在「设置 → 诊断」里一键跑，出问题时好定位是「网络/证书/会话/协议变更」哪一层；
- 对未知 JSON 字段宽容（`decodeIfPresent` + 忽略多余键），对**必要**字段缺失则明确失败并提示「NAS 版本可能不受支持」；
- 把 `serverVersion` 与「已知可用版本区间」比对，超区间时给一次性提示（而不是静默失败）。

## 附录 B. 一句话结论

- **技术可行性：高。** 协议已被 4 个第三方客户端跑通，其中 **一个就是 Swift/macOS 的**（[primuse]，可直接对照实现）。
- **只读 + 播放 + 收藏 + 歌单** 是一块边界清晰、可估的工作。
- **最大变量不是接口数量，而是两个「是/否」**：`authx` 是否强制（→ 播放层半天 vs 一周）、`duration` 单位（→ 一处归一化，但必须先实测）。
- **最大的产品落差不是协议，而是能力**：飞牛**没有播放进度同步**，Overtone 现有的「继续播放」不能平移，只能本地实现。
- **FN Connect 是一个独立的、可后置的大块**（3–5 天），第一版完全可以只支持自定义域名/局域网。
