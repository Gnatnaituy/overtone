# Client-side metadata scraping for a Jellyfin music client on macOS

**Verdict: feasible and worth doing, but scope it as "lyrics + cover art first."** Lyrics are the highest-value, lowest-risk win because Jellyfin exposes a first-class write-back endpoint. Most APIs covering CJK music are *unofficial* and carry real breakage/ToS risk; the *official* ones (MusicBrainz, iTunes, Deezer, TheAudioDB) cover CJK better than commonly assumed, but only for mainstream artists.

All endpoint shapes below were live-tested on 2026-10-06 unless marked **UNVERIFIED**.

## Summary table

| Source | Provides | Auth | CJK coverage | Reliability |
|---|---|---|---|---|
| lrclib.net | Synced+plain lyrics | None | **Excellent** (Mandopop, Cantopop, JP ACG) | Good, but intermittent 503 under bursts |
| NetEase legacy `/api/*` | Lyrics, art, album, year | None (Referer) | **Excellent** | Unofficial; ecosystem already DMCA'd once |
| QQ Music `fcg_query_lyric_new` | Synced lyrics (LRC) | None (Referer) | **Excellent** | Lyrics stable; search broken without cookies |
| Kugou `krcs.kugou.com` | Lyrics (base64 LRC), search | None | **Excellent** | Working; older mobile CDN dead |
| MusicBrainz + CAA | Art, MBIDs, year | None (User-Agent) | **Good for mainstream** | Official, strict 1 req/s |
| iTunes Search | Art, album, year | None | **Good** | Official; rate limit not verified |
| Deezer | Art, artist images | None | **Good** (EN names only) | Official; CJK queries unreliable |
| TheAudioDB | Art, bios, artist images | Free key `123` | **Weak** (romanized only) | Official; free key changed |
| Last.fm | Bios, tags | API key | Moderate | Official; **artwork excluded**, 100 MB cap |
| Musixmatch / Genius | Lyrics | Key | — | **Licensing deal-breakers** |

## 1. Lyrics

**lrclib.net — the primary recommendation.** No key, no auth. Two shapes, both verified:

- `GET https://lrclib.net/api/search?q={query}` — free-text
- `GET https://lrclib.net/api/get?artist_name=&track_name=&album_name=&duration=` — exact signature match

Responses carry `plainLyrics` *and* `syncedLyrics` (real LRC with `[mm:ss.xx]` tags). Verified: 周杰伦《晴天》 returned synced LRC plus full album data; 李克勤《总有你鼓励》 returned Cantonese synced lyrics; 残酷な天使のテーゼ returned JP lyrics. CJK + ACG coverage is genuinely strong. **Reliability caveat (measured):** 1 of 6 requests in a rapid burst returned `HTTP 503 {"name":"ServerOverloaded"}`. No `X-RateLimit-*` headers appear, and lrclib's docs page is JS-rendered so its published limits are **UNVERIFIED**; treat it as "serialize to ~1 req/s, honor `Retry-After`."

**NetEase (网易云) — works *without* encryption.** The old plaintext endpoints still respond, so you do **not** need weapi/eapi crypto. With `Referer: https://music.163.com`:

- `GET /api/search/get/web?s=&type=1&offset=0&limit=`
- `GET /api/song/lyric?id=186016&lv=1&kv=1&tv=-1` → `lrc.lyric` (plus `tlyric` for translations)
- `GET /api/song/detail/?id=&ids=[...]` → album `picUrl`

Risk is nonetheless high: [Binaryify/NeteaseCloudMusicApi is now **archived**](https://github.com/Binaryify/NeteaseCloudMusicApi) (30,246 stars) and was [removed over copyright pressure](https://www.donews.com/news/detail/4/3967225.html); forks like [`api-enhanced`](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced) (1,931 stars) carry on, so this class of API is durable-in-practice but never stable.

**QQ Music — split reliability.** Lyrics: `GET https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=&format=json&nobase64=1` with `Referer: https://y.qq.com/portal/player.html` returned full LRC for 晴天, no auth. Search: `client_search_cp` returned **empty**, and `musicu.fcg` returned `code: 2001` with empty lists (needs cookies). `splcloud/fcgi-bin/smartbox_new.fcg?key=` worked for albums/artists. Use QQ for lyrics given a known `songmid`, not for discovery.

**Kugou — both steps verified.** `songsearch.kugou.com/song_search_v2?keyword=&page=&pagesize=` returned 480 results; `krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=&duration=` returns candidates with `id` + `accesskey`; `krcs.kugou.com/download?...&id=&accesskey=&fmt=lrc&charset=utf8` returns **base64-encoded** LRC. `mobilecdn.kugou.com/api/v3/search/song` is now dead — live endpoint rot.

**Musixmatch / Genius — avoid.** Musixmatch's [API Terms](https://about.musixmatch.com/apiterms) are a hard blocker for a distributed app: non-commercial only (§1.1), mandatory "powered by Musixmatch" credit (§2.1.5), **no AI/ML use** (§2.2.14), delete all data on termination (§7.2.1). Genius's terms (metadata + backlink only, lyrics text unlicensed) are **UNVERIFIED** — I could not fetch them — but that is the long-standing constraint.

## 2. Cover art / album metadata

**TheAudioDB — free key changed.** Most tutorials and older code use test key `2`; that now returns `{"Message":"Not found"}`, as does `1`. Key **`123` works**: `GET https://www.theaudiodb.com/api/v1/json/123/search.php?s=`, plus `searchalbum.php`, `searchtrack.php`. CJK coverage is the weak spot: `Jay Chou` → found (with `strArtistAlternate: "周杰倫, 周杰伦"`), `Aimyon` → found (あいみょん); but `周杰伦` → `null` and `Yorushika` → `null`. So it needs romanized input and is patchy for doujin/ACG.

**MusicBrainz — better than expected, but throttled.** `GET https://musicbrainz.org/ws/2/recording?query=artist:周杰伦 AND recording:晴天&fmt=json&limit=` returned **count 495, score 100**, with CJK aliases (周杰倫 / ジェイ・チョウ / 주걸륜). Mainstream Mandopop is well covered. Requirements: descriptive `User-Agent`, and **1 request/second** (widely documented; the rate-limit page itself is **UNVERIFIED** here). **Cover Art Archive:** `GET https://coverartarchive.org/release/{mbid}/front-250` — verified it 307-redirects and then serves a real JPEG, so follow redirects.

**iTunes Search — free, no key, real CJK coverage.** `GET https://itunes.apple.com/search?term=&entity=song|album&limit=&country=` returns Jay Chou releases. Artwork pattern confirmed: swap the `/100x100bb.jpg` suffix for `/600x600bb.jpg`. A `country=CN` query for 周杰伦 returned 0 results — **UNVERIFIED** whether that is storefront restriction or query behaviour; prefer omitting `country` or using `US`. Apple's Search API artwork/promotional terms are **UNVERIFIED** (found the [Search API page](https://performance-partners.apple.com/search-api), did not extract the artwork clause).

**Deezer — free, no auth.** `GET https://api.deezer.com/search/album?q=` (verified, 65 results for "Jay Chou") and `search/artist?q=`. `cover_xl` is `https://cdn-images.dzcdn.net/images/cover/{hash}/1000x1000-000000-80-0-0.jpg`. Caveat: `search?q=周杰伦` returned `{"data":[],"total":156}` — empty data with nonzero total, i.e. CJK text search is unreliable. Use romanized names. Caching terms are **UNVERIFIED**.

**Douban — treat as unavailable.** I found no evidence of a live public music API, only a [third-party userscript](https://github.com/Dennis-Sun/douban-music-advanced-search). Your recollection that it was shut down appears correct, but I could not verify a specific notice (**UNVERIFIED**) — do not plan around it.

## 3. Artist bios / images

- **Last.fm** — `artist.getInfo` gives bios and tags via an API key. Its [API ToS](https://www.last.fm/api/tos) is restrictive: non-commercial only (§3.1), mandatory "powered by AudioScrobbler" button and links (§2.7), **Reasonable Usage Cap of 100 MB stored at any time** (§4.3.4), and crucially **artwork and images are expressly excluded from the licence** (§5.1.8). Bios yes, artist images no.
- **TheAudioDB** — `strArtistThumb`, `strArtistFanart`, `strBiography` (verified field names).
- **Deezer** — `picture_xl` artist images (verified).
- **Wikipedia/Wikidata** — the usual fallback for bios; **UNVERIFIED** here but low-risk.

## 4. Matching strategy

**beets is the best-documented recipe**, and its defaults are directly portable. From `beets/config_default.yaml`: `strong_rec_thresh: 0.04`, `medium_rec_thresh: 0.25`, `rec_gap_thresh: 0.25`; `distance_weights` of **track_title 3.0, artist 3.0, album 3.0**, track_artist 2.0, **track_length 2.0**, track_index 1.0, year 1.0, media 1.0, with album_id/track_id 5.0. Duration tolerance is explicit: **`track_length_grace: 10`, `track_length_max: 30`** — ±10 s is free, >30 s is rejected. This matters: lrclib's search for 晴天 returned the same title at 299 s (live), 270 s (studio) and 249 s, so duration filtering is what disambiguates versions.

**Music Tag Web is the closest existing model to your use case.** Its [README](https://raw.githubusercontent.com/xhongc/music-tag-web/master/README.md) describes exactly your architecture — a sidecar for music on a remote server, editing *remote* files. It scrapes 网易云音乐 / QQ音乐 / 咪咕音乐 (Migu — worth adding to your list). Its licence is GPL-3.0 plus an addendum that is effectively a legal warning: **non-commercial only**, and *"使用者务必在24小时内清除...版权数据"* (users must delete scraped copyright data within 24 hours). Expect to publish similar disclaimers.

**Fingerprinting: possible but poor ROI, and it needs the audio.** [ChromaSwift](https://github.com/wallisch/ChromaSwift) is a good technical fit — MIT-licensed SPM wrapper for Chromaprint, macOS/iOS/tvOS, Swift 6, using AVFoundation resampling to strip the LGPL ffmpeg code. `try AudioFingerprint(from: fileURL)` then `AcoustID(apiKey:).lookup(...)`; needs an AcoustID key, `.test2` algorithm, samples 120 s by default. **The blocker is your constraint:** the API takes a *file URL*, so the app must download the track (or a prefix) from Jellyfin first. Whether a partial download suffices is **UNVERIFIED** (the wrapper documents only file URLs, though `import CChromaprint` exposes the streaming C API). Given AcoustID/MusicBrainz fingerprints are weakest exactly where you need help (CJK/ACG), skip fingerprinting and use fuzzy title+artist+duration matching.

## 5. Reliability, legal, and write-back

**Write back to Jellyfin — this works, and it's the right design.** Verified against the [Jellyfin OpenAPI spec](https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json):

- `POST /Audio/{itemId}/Lyrics` — *"Upload an external lyric file"*, body `text/plain`. Exactly the endpoint you hoped for.
- `GET /Audio/{itemId}/RemoteSearch/Lyrics` and `POST /Audio/{itemId}/RemoteSearch/Lyrics/{lyricId}`
- `POST /Items/{itemId}/Images/{imageType}/{imageIndex}` — set item image (cover art write-back)
- `DELETE /Audio/{itemId}/Lyrics` — useful for undo

**Design recommendation:** cache every scraped result locally (SQLite/GRDB) keyed by Jellyfin item ID so a provider outage never blanks the UI, and make server write-back an explicit per-item opt-in — a wrongly matched lyric written back is worse than none. There is no verified Jellyfin endpoint for writing *artist biographies*, so treat bios as display-only.

**Keys the user must supply:** AcoustID (only if fingerprinting) and Last.fm. Everything else works keyless: lrclib, NetEase, QQ, Kugou, MusicBrainz, iTunes, Deezer, and TheAudioDB's shared key `123`.

**Biggest risks, ranked:** (1) unofficial CJK endpoints break without notice — Kugou's dead CDN and NetEase's archived reference implementation prove this; isolate each provider behind a protocol with per-provider health tracking. (2) ToS/legal exposure in redistributing scraped lyrics and art — the unofficial providers offer no licence at all, so ship disclaimers and default to lrclib. (3) Rate limits: MusicBrainz 1 req/s is a hard contractual limit, lrclib throttles under bursts, Last.fm caps stored data at 100 MB — use one global serialized queue with per-host budgets. (4) Last.fm/Musixmatch terms forbid shipping artwork or commercial use — keep those optional.

**Suggested build order:** lrclib lyrics → iTunes/Deezer/CAA cover art → MusicBrainz for year/album/genre → NetEase/QQ/Kugou as opt-in "CJK boosters" → artist bios last.
