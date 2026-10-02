import AppKit
import SwiftUI

/// 全局窗口引用（自定义关闭按钮等使用）
enum WindowManager {
    static weak var mainWindow: NSWindow?

    /// 侧栏当前是否为 64pt 图标栏（由 `MainView` 同步，含用户手动收起）。
    ///
    /// 图标栏面板只有 64pt 宽，红黄绿三键（16×3 + 间距 = 62pt）必须更靠左更紧凑才装得下；
    /// 完整侧栏（200–320pt）则用系统默认间距。与设计稿一致（preview 窄窗 `left:18px;gap:6px`）。
    static var sidebarUsesRail = false

    /// 侧栏形态变化后重新摆放三键
    static func refreshTrafficLights() {
        guard let window = mainWindow else { return }
        moveTrafficLights(into: window)
    }

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
        // 跟随主题（浅色白 / 深色 surface #16191F）：动态色由 AppKit 按外观解析
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(srgbHex: 0x16191F) : .white
        }
        window.hasShadow = true
        moveTrafficLights(into: window)
    }

    // MARK: - 红黄绿三键移进悬浮侧栏面板（§7.2 规则 2）

    /// 悬浮侧栏面板：外边距 10 + 圆角 10 → 面板左上角圆角圆心在 (20, 20)。
    /// 系统默认位置（首键左上角 (8, 8)，16×16）正好落在面板圆角**外侧**，
    /// 三键会露在玻璃面板外、悬在氛围层上。
    ///
    /// - 完整侧栏（面板 10–210）：三键 20–82，与系统观感一致；
    /// - 图标栏（面板 10–74，仅 64pt 宽）：三键收到 14–70，间距压到 4pt 才装得下。
    ///
    /// 目标位置用窗口坐标表达（窗口坐标原点在左下）再换算回按钮父视图坐标系，
    /// 这样不依赖标题栏内部视图是否 flipped。
    static func moveTrafficLights(into window: NSWindow) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard buttons.count == types.count, let parent = buttons[0].superview else { return }

        let rail = sidebarUsesRail
        let leading: CGFloat = rail ? 14 : 20
        let top: CGFloat = 20
        let gap: CGFloat = rail ? 4 : 7
        let windowHeight = window.frame.height

        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let target = NSRect(
                x: leading + CGFloat(index) * (size.width + gap),
                y: windowHeight - top - size.height,
                width: size.width,
                height: size.height
            )
            button.setFrameOrigin(parent.convert(target, from: nil).origin)
        }
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
        private var observers: [NSObjectProtocol] = []

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
            // 标题栏会随窗口尺寸/样式重新布局，把三键推回系统默认位置（8, 8）；
            // 缩放期间每次都要拉回悬浮面板内，否则三键会飘到面板圆角外
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            let recenter: (Notification) -> Void = { [weak window] _ in
                guard let window else { return }
                WindowManager.moveTrafficLights(into: window)
            }
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main, using: recenter
                ),
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main, using: recenter
                )
            ]
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
