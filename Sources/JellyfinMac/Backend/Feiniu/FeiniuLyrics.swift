import Foundation

// MARK: - LRC 解析（纯函数）
//
// 证据：协议档 §3.7（`/lyric/list` 返回 `{preferred, list:[{guid, content, isLRC, offset}]}`，
//      `content` 是 **LRC 文本**）、§7.4（「歌词时间轴结构」缺失 → 只能自己解析）、
//      [dart] `api_models.dart:596-617`（`FnLyric`）；LRC 标签格式本身是公开的 LRC 格式约定。
//
// 为什么单独一个文件：解析器是纯函数（字符串进、`[LyricLine]` 出），
// 既能单测，也不让歌词细节混进网络层。
//
// TODO(C)：协议档把「编码（是否含 BOM）、时间轴单位、翻译/多语言歌词、空歌词行为」
// 全列为待验证。这里的假设是「UTF-8 + 标准 `[mm:ss.xx]` 十进位秒」；
// 真机上如果歌词整体偏移，先查是不是服务端已经做过 `[offset:]` 调整。
enum FeiniuLyrics {

    /// LRC 文本 → 歌词行。
    ///
    /// - Parameters:
    ///   - content: 服务端 `content` 字段原文
    ///   - isLRC: 服务端 `isLRC` 标记。false（或解析不出任何时间标签）时按纯文本处理，
    ///            返回的 `LyricLine.start` 全为 nil（`MediaModels` 里「纯文本歌词为 nil」）。
    /// - Returns: 按时间升序排列的歌词行；空歌词返回空数组（不返回「无歌词」占位行）。
    static func parse(_ content: String, isLRC: Bool = true) -> [LyricLine] {
        let normalized = normalizeInput(content)
        guard !normalized.isEmpty else { return [] }

        guard isLRC else { return plainTextLines(normalized) }

        var offsetSeconds = 0.0
        var timed: [(start: Double, text: String)] = []

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let characters = Array(rawLine)
            let parsed = parseLine(characters)
            if let offset = parsed.offsetMilliseconds {
                // 全局偏移标签通常出现在开头；后出现的以最后一次为准。
                offsetSeconds = offset / 1000
            }
            guard !parsed.times.isEmpty else { continue }
            let text = stripWordTimingTags(parsed.text)
            // 有时间戳但文本为空 = 间奏留白，UI 侧无内容可滚，直接丢掉。
            guard !text.isEmpty else { continue }
            for time in parsed.times {
                // LRC `[offset:]` 语义：正值 = 歌词提前，所以这里是「减」。
                // TODO(C)：这一条在实现间有分歧（有的实现用加），Navidrome/音乐播客
                // 工具多用减；若真机歌词整体偏移 2×offset，把这里改成加。
                let start = max(0, time - offsetSeconds)
                timed.append((start, text))
            }
        }

        guard !timed.isEmpty else {
            // 标了 isLRC=true 但一个时间标签都没有（或全是元数据标签）→ 退化成纯文本。
            return plainTextLines(normalized)
        }

        // 稳定排序：同一时间戳的多个翻译行保持原顺序。
        let sorted = timed.enumerated()
            .sorted { lhs, rhs in
                lhs.element.start == rhs.element.start
                    ? lhs.offset < rhs.offset
                    : lhs.element.start < rhs.element.start
            }
            .map(\.element)
        return sorted.map { LyricLine(text: $0.text, start: $0.start) }
    }

    // MARK: - 内部（仍为纯函数，便于单测）

    /// 去掉 BOM、统一换行。
    static func normalizeInput(_ content: String) -> String {
        var text = content
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct ParsedLine {
        var times: [Double] = []
        var text: String = ""
        var offsetMilliseconds: Double?
    }

    /// 解析一行：吃掉行首所有 `[...]` 标签，剩下的是歌词文本。
    ///
    /// 支持的标签：
    /// - `[mm:ss]` / `[mm:ss.x]` / `[mm:ss.xx]` / `[mm:ss.xxx]` / `[mm:ss:xx]` → 时间
    /// - `[offset:+/-123]` → 全局偏移（毫秒）
    /// - `[ti:] [ar:] [al:] [by:] …` 等元数据 → 忽略
    static func parseLine(_ line: [Character]) -> ParsedLine {
        var result = ParsedLine()
        var index = 0
        while index < line.count, line[index] == "[" {
            guard let close = line[index...].firstIndex(of: "]") else { break }
            let body = Array(line[(index + 1)..<close])
            if let seconds = parseTimestamp(body) {
                result.times.append(seconds)
            } else if let offset = parseOffsetTag(body) {
                result.offsetMilliseconds = offset
            }
            index = close + 1
        }
        result.text = String(line[index...]).trimmingCharacters(in: .whitespaces)
        return result
    }

    /// `[mm:ss.xx]` 的内部部分 → 秒。不是时间标签时返回 nil。
    static func parseTimestamp(_ body: [Character]) -> Double? {
        var index = 0
        let total = body.count
        func readDigits() -> Int? {
            var value = 0
            var count = 0
            while index < total, let digit = body[index].wholeNumberValue {
                value = value * 10 + digit
                index += 1
                count += 1
            }
            return count > 0 ? value : nil
        }
        guard let minutes = readDigits(), index < total, body[index] == ":" else { return nil }
        index += 1
        guard let seconds = readDigits() else { return nil }

        var fraction = 0.0
        if index < total, body[index] == "." || body[index] == ":" {
            index += 1
            var digits = ""
            while index < total, let digit = body[index].wholeNumberValue {
                digits.append(String(digit))
                index += 1
            }
            guard !digits.isEmpty else { return nil }
            fraction = Double("0." + digits) ?? 0
        }
        // 还有残留字符说明不是纯时间标签（例如 `[ar:某某]`）。
        guard index == total else { return nil }
        return Double(minutes) * 60 + Double(seconds) + fraction
    }

    /// `[offset:+250]` → 毫秒。
    static func parseOffsetTag(_ body: [Character]) -> Double? {
        let text = String(body).trimmingCharacters(in: .whitespaces)
        let prefix = "offset:"
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let value = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return Double(value)
    }

    /// 去掉「增强 LRC」的逐字时间标签 `<00:12.34>`，只保留文本。
    static func stripWordTimingTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var output = ""
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; continue }
            if !insideTag { output.append(character) }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// 纯文本歌词：一行一条，`start = nil`。
    static func plainTextLines(_ text: String) -> [LyricLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(text: $0, start: nil) }
    }
}
