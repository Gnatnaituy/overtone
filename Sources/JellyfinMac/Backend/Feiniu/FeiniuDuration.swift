import Foundation

// MARK: - 数值单位归一化（纯函数）
//
// 证据：协议档 §6.1「duration 单位不统一」大坑、§6.3（`createdAt/updatedAt` 同样是
//      秒/毫秒混用）、§7.7 坑 #1 / #12；[ps5] `src/fnos/api.cpp:83-89` 的阈值实现；
//      [dart] `api_models.dart:224-231`（`FnLibrary.lastChangedAt` 的 `> 1e12` 归一）
//      与 `:450`（`FnTrack.duration` 注释写「毫秒」—— 与 [ps5] 的秒口径冲突，所以必须归一化）。
//      [kotlin] `ApiDtos.kt:110` 把**两个** duration 都 `/1000` 换成秒
//      （`durationSeconds = (duration > 0 ? duration : audioSpec.duration) / 1_000.0`），
//      即 kotlin 侧认为 track.duration 与 audioSpec.duration 都是毫秒；
//      [ps5] 则用阈值兜「有的接口给秒」。两说并存 → 阈值法最稳。
//
// 这一整个文件的函数都是**纯函数**（不碰网络、不读时间、不读 UserDefaults），
// 目的就是能直接单测：飞牛最可能引发「时长显示错乱 + 进度条乱跳」的字段就在这里。

/// 时长归一化。
enum FeiniuDuration {
    /// 判定阈值（秒）：超过它的一律当成毫秒。
    ///
    /// 原注释（[ps5]）：「服务器单位不固定：同一首 5 分钟的歌，一个接口给 300，
    /// 另一个接口给 300000。判定阈值取 20000——没有 5.5 小时长的歌，也没有按毫秒
    /// 算只有 20 秒的片段。」
    static let millisecondThreshold = 20_000.0

    /// 把服务端原始 `duration` 归一化成**秒**（`MediaItem.duration` 的单位）。
    ///
    /// - `nil` / 负数 / 非有限值 → 0（不猜，交给 UI 显示「--:--」）。
    static func normalize(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return 0 }
        return raw > millisecondThreshold ? raw / 1000 : raw
    }

    static func normalize(_ raw: Int?) -> Double {
        normalize(raw.map(Double.init))
    }

    /// 自己算的毫秒（上报事件用）→ 秒。与 `normalize` 无关，只是给调用方少写一个除法。
    static func seconds(fromMilliseconds milliseconds: Double) -> Double {
        milliseconds / 1000
    }

    // TODO(C)：阈值法有已知盲区 —— 按毫秒返回的「20 秒以内的短音效/试听片段」
    // 会被当成 20 秒以上的秒值（例如 15000ms 会被读成 15000 秒）。协议档 §8#2
    // 要求「逐接口核对三处 duration（list / metadata / album-detail）」，联调时
    // 第一件事就是拿同一首歌对比这三个接口的原始值。
}

/// 时间戳归一化（epoch 秒 / 毫秒混用）。
enum FeiniuTimestamp {
    /// 毫秒时间戳的量级下限：`1e12` ms ≈ 2001 年，任何合理的「秒」时间戳都远小于它。
    /// 与 [dart] 在 `contentLastChangedAt` 上的处理一致（协议档 §6.3）。
    static let millisecondsFloor = 1_000_000_000_000.0

    /// 服务端 epoch（秒或毫秒）→ `Date`。0 / 负数 / 缺省 → nil。
    static func date(fromEpoch raw: Double?) -> Date? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        let seconds = raw > millisecondsFloor ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    /// `Date` → Unix 毫秒（`event/report` 的 `occurredAt` 要毫秒，协议档 §4.5）。
    static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
