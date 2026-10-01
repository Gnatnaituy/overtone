import AppKit
import SwiftUI

/// 全局窗口引用（自定义关闭按钮等使用）
enum WindowManager {
    static weak var mainWindow: NSWindow?

    /// 统一应用窗口定制：透明标题栏 + 内容铺满标题栏 + 系统圆角/阴影，**保留红黄绿三键**。
    ///
    /// 注意：不能移除 .titled —— 窗口激活瞬间（didBecomeKey）改写 styleMask
    /// 会打断进行中的鼠标点击，导致"侧栏需要点两次才切换"。
    /// 用 titlebarAppearsTransparent + titleVisibility = .hidden 实现无标题文字的外观，
    /// 但标准窗口按钮保持可见（窗口左上角留出 `Theme.Size.windowChromeHeight` 的空白条）。
    ///
    /// 早期实现用 isOpaque=false + backgroundColor=.clear + RootView clipShape 自画圆角，
    /// 导致窗口顶部 ~28pt 标题栏区不参与绘制：布局按全窗口算（内容视图已是全尺寸）、
    /// 渲染却从内容区顶开始，logo 行（♪ Overtone 标题）上半截被"截掉"，文字看起来
    /// 像被横线划掉（2026-08-24 定位）。改为不透明窗口 + 内容色背景 + 系统圆角。
    static func apply(_ window: NSWindow) {
        mainWindow = window
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        // 不透明窗口：背景用内容同色，标题栏区由窗口自身着色，四角由系统圆角
        window.isOpaque = true
        window.backgroundColor = .white
        window.hasShadow = true
    }
}

/// 挂在视图层级上：窗口出现时应用定制
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ConfigNSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfigNSView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // 等 SwiftUI 完成窗口初始化后再应用，避免被覆盖
            DispatchQueue.main.async {
                WindowManager.apply(window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    WindowManager.apply(window)
                }
            }
        }
    }
}
