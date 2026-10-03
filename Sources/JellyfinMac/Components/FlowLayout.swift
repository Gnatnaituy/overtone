import SwiftUI

/// 按可用宽度自动换行的水平排列（macOS 13 `Layout`）。
///
/// 用途：详情页头部的操作行（播放 / 随机播放 / 同步 / 重命名 / 删除）。
/// 五项一行摆开的最小宽度 ≈412pt（主按钮 128 + 次级 116 + 三个 44 图标键 + 间距 48），
/// 而内容列宽度 = 窗口宽 − 侧栏块，最窄时只有 ~450pt：`HStack` 不换行，页面最小宽度会被
/// 顶到内容列之上，整页向右溢出，顶栏 / 面包屑玻璃面板被窗口右缘裁掉（§7.2 规则 3）。
/// 换行后操作行的最小宽度 = 最宽单项（128pt），任何档位的内容列都放得下（§4.4「窄窗
/// 操作行换行」）。判据是**实际可用宽度**，不是窗口档位 —— 侧栏宽度可拖拽 180–320，
/// 同一档位下内容列宽度能差 250pt 以上（同 `MiniPlayerBar.BarLayout` 的理由）。
struct FlowLayout: Layout {
    /// 同一行内相邻项的间距
    var spacing: CGFloat = Theme.Spacing.lg
    /// 行与行之间的间距
    var lineSpacing: CGFloat = Theme.Spacing.md

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        // 宽度提议为 nil（不定）时按一行铺开；为 0 时每项独占一行 —— 于是本布局对外上报的
        // 最小宽度 = 最宽单项，页面最小宽度不会再被操作行顶宽。
        let limit = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = lineWidth == 0 ? size.width : lineWidth + spacing + size.width
            // 放不下就换行；单项比可用宽度还宽时独占一行（不裁切、不缩放）
            if lineWidth > 0, needed > limit {
                width = max(width, lineWidth)
                height += lineHeight + lineSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth = needed
                lineHeight = max(lineHeight, size.height)
            }
        }

        return CGSize(width: max(width, lineWidth), height: height + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > bounds.width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if x > 0 { x += spacing }

            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
