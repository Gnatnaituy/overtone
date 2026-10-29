import Foundation

// MARK: - 飞牛线上格式（wire）
//
// 证据：协议档 §6.6「通用 envelope 与分页」、§6.6 末尾的业务码表、§7.6（HTML 而不是
//      JSON = 请求没打到 API，多与重定向/中继失效有关）、§3.x 各接口的 `data` 字段；
//      [dart] `api_models.dart` 的 `ApiResponse` / `listItemsOf` / `totalOf`。
//
// 为什么不用 Codable DTO：
//   1. 飞牛的分页响应形态不统一 —— 多数是 `{list,total,sort}`，但也见过裸数组、
//      `{items}`、`{rows}`、`{libraries}`（协议档 §6.6 明确要求容错，[dart] 有
//      `_firstList` 四种 key 的兜底）；
//   2. 数值字段的单位/类型都不稳（`duration` 秒/毫秒、`createdAt` 秒/毫秒，
//      字段还可能给成字符串）；
//   3. 严格 Codable 一旦某个字段类型不符就整条响应解码失败 —— 对「第三方逆向协议」
//      来说这是最糟的失败模式（一个无关字段变型 → 整个列表空）。
//
// 所以这里先把 JSON 解成**宽容的树**（`FeiniuJSON`），再由 `FeiniuMapping` 逐字段取值：
// 类型不对就退化成 nil，单条坏数据不会拖垮整页。

/// 宽容 JSON 值。数值统一存成 `Double`（JSON 的整数/浮点都能解），需要 Int 时再取。
struct FeiniuJSON: Decodable {
    enum Value {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([FeiniuJSON])
        case object([String: FeiniuJSON])
    }

    let value: Value

    /// 直接用值构造（`Decodable` 之外的另一条入口：测试造数据、把两层响应拼成一层）。
    init(value: Value) {
        self.value = value
    }

    /// 用字典构造对象（`/track/metadata` 的 `{track, audioSpec}` 合并时用）。
    static func makeObject(_ dictionary: [String: FeiniuJSON]) -> FeiniuJSON {
        FeiniuJSON(value: .object(dictionary))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = .null
            return
        }
        // 顺序有感：Bool 必须在数值之前（true/false 不会解成数字，但反过来不成立），
        // Int 在 Double 之前（JSON 的 `300` 解 Double 也行，但先取 Int 更贴合语义）。
        if let bool = try? container.decode(Bool.self) { value = .bool(bool); return }
        if let int = try? container.decode(Int.self) { value = .number(Double(int)); return }
        if let double = try? container.decode(Double.self) { value = .number(double); return }
        if let string = try? container.decode(String.self) { value = .string(string); return }
        if let array = try? container.decode([FeiniuJSON].self) { value = .array(array); return }
        if let object = try? container.decode([String: FeiniuJSON].self) { value = .object(object); return }
        value = .null
    }
}

// MARK: - 取值器

extension FeiniuJSON {
    /// 对象取字段（非对象返回 nil，链式访问天然安全）
    subscript(key: String) -> FeiniuJSON? {
        guard case .object(let dictionary) = value else { return nil }
        return dictionary[key]
    }

    var objectValue: [String: FeiniuJSON]? {
        guard case .object(let dictionary) = value else { return nil }
        return dictionary
    }

    var arrayValue: [FeiniuJSON]? {
        guard case .array(let array) = value else { return nil }
        return array
    }

    /// 字符串；数字退化成字符串（个别部署把 `guid` 当数字发）。
    var stringValue: String? {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            guard number.isFinite else { return nil }
            // 320.0 → "320"，避免把数字 id 写成 "320.0" 再去请求
            return number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .array, .object, .null:
            return nil
        }
    }

    /// 整数；接受数字、数字字符串、布尔（true=1）。
    var intValue: Int? {
        switch value {
        case .number(let number):
            return Self.safeInt(number)
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) { return int }
            if let double = Double(trimmed) { return Self.safeInt(double) }
            return nil
        case .bool(let bool):
            return bool ? 1 : 0
        case .array, .object, .null:
            return nil
        }
    }

    /// 浮点；接受数字与数字字符串。
    var doubleValue: Double? {
        switch value {
        case .number(let number):
            return number.isFinite ? number : nil
        case .string(let string):
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool, .array, .object, .null:
            return nil
        }
    }

    /// 布尔；缺省即 false 的字段大量存在（协议档 §7.3），所以这里也接受 0/1 与字符串。
    var boolValue: Bool? {
        switch value {
        case .bool(let bool):
            return bool
        case .number(let number):
            return number != 0
        case .string(let string):
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        case .array, .object, .null:
            return nil
        }
    }

    /// 列表：裸数组，或 `{list}` / `{items}` / `{rows}` / `{libraries}` 任一分页键（协议档 §6.6）。
    /// 参考实现：[dart] `api_models.dart:11-18`（`listItemsOf`）。
    var listElements: [FeiniuJSON]? {
        if let array = arrayValue { return array }
        guard let dictionary = objectValue else { return nil }
        for key in ["list", "items", "rows", "libraries"] {
            if let array = dictionary[key]?.arrayValue { return array }
        }
        return nil
    }

    /// 分页总数（`total` 缺失时由调用方回退成当前页条数）。
    var totalCount: Int? {
        self["total"]?.intValue
    }

    private static func safeInt(_ number: Double) -> Int? {
        guard number.isFinite, number > -9.0e18, number < 9.0e18 else { return nil }
        return Int(number)
    }
}

// MARK: - 响应信封 `{code, msg, data}`

/// 飞牛统一响应信封（协议档 §6.6）。
///
/// **成功判据是「HTTP 状态符合预期 AND `code == 0`」**：错签名/会话失效时会得到
/// HTTP 200 + 非 0 code（协议档 §2.6、§6.6 都强调了），只看 HTTP 状态会漏判。
enum FeiniuEnvelope {
    /// 解出 `data`；`code != 0` 抛映射后的 `MusicBackendError`。
    ///
    /// - Returns: 空响应体（204 等）返回 nil。
    static func data(from body: Data) throws -> FeiniuJSON? {
        guard !body.isEmpty else { return nil }

        // 收到 HTML 而不是 JSON：请求没打到 API（重定向到登录页 / HTTPS 门户 / 中继失效）。
        // 协议档 §1.3.3 把这个现象本身当作「relay 掉了」的判据；这里至少给出可读原因，
        // 不把一坨 HTML 丢给 JSON 解析器变成「数据解析失败」。
        if let firstByte = body.first(where: { ![0x20, 0x0A, 0x0D, 0x09].contains($0) }),
           firstByte == UInt8(ascii: "<") {
            throw MusicBackendError.invalidServer(
                "服务器返回的是网页而不是接口数据（可能被重定向到登录页或 HTTPS 门户）；"
                    + "请检查地址是否需要 https://，以及是否少了 /music"
            )
        }

        let root: FeiniuJSON
        do {
            root = try JSONDecoder().decode(FeiniuJSON.self, from: body)
        } catch {
            throw MusicBackendError.decoding
        }
        guard let object = root.objectValue,
              let code = object["code"]?.intValue
        else { throw MusicBackendError.decoding }

        guard code == 0 else {
            // 真实 FNOS 用 `msg`；mock/旧响应用 `message`，与 [dart] `ApiResponse` 兼容读取一致。
            let message = object["msg"]?.stringValue ?? object["message"]?.stringValue
            throw FeiniuAPIError.map(code: code, message: message)
        }
        return object["data"]
    }
}

// MARK: - 业务错误码

/// 业务码 → `MusicBackendError`（协议档 §6.6 业务码表 / [dart] `ApiException.friendlyMessage`）。
///
/// 服务端 `msg` 是英文（如 `invalid arguments`），直接给用户看没有意义，所以
/// 「已知码给中文、未知码带上原始 msg」。
enum FeiniuAPIError {
    /// 会话失效的口径（协议档 §2.6）：HTTP 401/403，或 envelope code ∈ 下面这些。
    static let sessionExpiredCodes: Set<Int> = [99999, 120001, 401, 403]

    static func map(code: Int, message: String?) -> MusicBackendError {
        let serverMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch code {
        case 120001:
            // 登录时是「账号或密码错误」；会话中则是「登录状态已失效」。
            // 这里无法区分调用场景，用更中性的说法，登录页可自行覆盖文案。
            return .unauthorized("账号或密码错误，或登录状态已失效")
        case 100002:
            return .server("参数不完整或格式不正确（100002）")
        case 100005:
            return .server("资源不存在或已被删除（100005）")
        case 160001:
            return .server("歌单名称已存在（160001）")
        case 160002:
            return .server("歌单数量已达上限（160002）")
        default:
            if sessionExpiredCodes.contains(code) {
                return .unauthorized("登录状态已失效，请重新登录")
            }
            if serverMessage.isEmpty {
                return .server("请求失败（错误码 \(code)）")
            }
            return .server("\(serverMessage)（错误码 \(code)）")
        }
    }
}
