import Foundation

/// 封面解析：把领域层的 `ArtworkRef` 交给当前活动后端换成可请求的 URL。
///
/// UI 里所有封面都走这里（而不是让视图知道 URL 怎么拼）：飞牛的封面地址可能
/// 逐请求签名，`ImageCache` 用 `ArtworkRef.cacheKey` 做键，不受签名影响。
@MainActor
enum ArtworkResolver {
    static func url(for ref: ArtworkRef?) -> URL? {
        guard let ref else { return nil }
        return BackendRegistry.shared.active.artworkURL(ref)
    }

    static func url(for item: MediaItem?, width: Int = 400) -> URL? {
        url(for: item?.artworkRef(width: width))
    }

    /// 缓存键（与 URL 无关，签名变化不会导致重复下载）
    static func cacheKey(for ref: ArtworkRef?) -> String? {
        ref?.cacheKey
    }
}
