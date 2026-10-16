import SwiftUI
import Darwin

@main
struct JellyfinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @ObservedObject private var settings = AppSettings.shared

    init() {
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        AppDelegate.disableWindowStateRestoration()
    }

    var body: some Scene {
        // 当前视觉风格（玻璃 / 纸墨）。这里读 `settings` 会让 App body 在风格变化时重算 ——
        // 环境值必须走这条通路注入（`Theme.visualStyle` 是全局镜像，读了不订阅）。
        let style = settings.visualStyle

        WindowGroup("Overtone") {
            RootView()
                .environmentObject(appState)
                .environmentObject(settings)
                // 视觉风格环境值：给「必须按风格改结构」的视图用（组件只消费，不自己判断来源）。
                //
                // **这一层不挂 `.id`**：RootView 下面是 `MainView`，它的导航栈 / 抽屉 /
                // 搜索词 / 排序 / 侧栏宽度都是自己的 @State，在这一层重建会把用户复位到默认页
                // （与 §5.4「导航/滚动无错乱」冲突）。重建交给「持有呈现层、但不持有页面状态」
                // 的那一层：主窗口 = `MainView` 的呈现子树（pages 负责），
                // 设置窗口 = `SettingsView` 的 body 内容（见下方注释）。
                .environment(\.appVisualStyle, style)
                .frame(minWidth: 520, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)

        // macOS 标准设置窗口：系统自带「设置…」菜单项与 ⌘, 快捷键
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(settings)
                .environment(\.appVisualStyle, style)
                // 这里**不挂** `.id`：设置页自己在 body 内把内容挂 `.id(visualStyle)`
                // （见 SettingsView），这样重建只波及内容，`group` 等 @State 保留 ——
                // 用户在「外观」里切风格，不会被踢回「通用」分组。
                // 设置窗口没有氛围层，玻璃在那里只会得到白底上的半透明白（§7.2 规则 3）
                .environment(\.appGlassSurfaces, false)
                .environment(\.appReduceTransparency, AccessibilityDisplayObserver.shared.reduceTransparency)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 主题外观：浅色 / 深色 / 跟随系统，令牌层按外观在绘制时解析（§4.2 双主题同权）
        Theme.applyStoredTheme()
        // 视觉风格：玻璃 / 纸墨，与外观正交。必须与上面并列在**首帧之前**应用 ——
        // 否则窗口会先按默认玻璃画一帧再跳成纸墨。
        Theme.applyStoredStyle()

        // 会话恢复由这里驱动（不绑定视图生命周期，避免被取消）
        Task { @MainActor in
            if AppSettings.shared.autoConnect {
                await AppState.shared.restoreSession()
            } else {
                AppState.shared.prepareWithoutAutoConnect()
            }
        }

        // 窗口每次成为主窗口时应用定制（覆盖 SwiftUI 对按钮显示状态的重置）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            // 只作用于承载 RootView 的主窗口：设置窗口保留系统标准标题栏与红黄绿三键
            guard let window = note.object as? NSWindow,
                  window === WindowManager.mainWindow else { return }
            WindowManager.apply(window)
        }

        // 未激活窗口的首次点击："单击直接生效"（等效于 acceptsFirstMouse = true）。
        //
        // ⚠️ 不能自己合成 mouseDown 投给 hitTest 命中的视图：SwiftUI 的控件（Menu / Button /
        // 自定义分段控件与色块）走的是 hosting view 的手势通路，命中视图收到 mouseDown 也
        // 不会触发控件 —— 点击被白白吞掉，表现为「窗口看得见，但里面点不动任何东西」
        // （设置窗口里的下拉框点不开、主题/强调色点不动，2026-10-01 定位）。
        // 正确做法：激活窗口后把这次点击重新入队，交给正常事件通路（含 SwiftUI 手势）处理。
        //
        // 另外，同一应用内的非 key 窗口不需要干预：AppKit 自己会把首次点击同时用于
        // 激活窗口和投递给控件（实测无监视器时首点即生效），拦下来反而更糟。
        var repostedEvents = Set<Int>()
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  !window.isKeyWindow,
                  window.level == .normal else { return event }
            guard !NSApp.isActive else { return event }
            // 激活失败时不重复入队，避免事件在监视器里打转
            guard !repostedEvents.contains(event.eventNumber) else { return event }
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            window.makeKeyAndOrderFront(nil)
            repostedEvents.insert(event.eventNumber)
            if repostedEvents.count > 64 { repostedEvents.removeAll() }
            NSApp.postEvent(event, atStart: false)
            return nil
        }

        // 点击文本输入框以外的任何区域 → 取消聚焦（"点击空白失焦"）
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let textView = window.firstResponder as? NSTextView else { return event }
            let location = event.locationInWindow
            let fieldFrame = textView.convert(textView.bounds, to: nil)
            if !fieldFrame.contains(location) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 「关闭窗口时继续播放」关闭时，关掉窗口即退出
        !AppSettings.shared.continuePlayingOnClose
    }

    // MARK: - 关闭 AppKit 窗口状态恢复（升级后「启动没有任何窗口」的坑）

    /// 关掉 macOS 的持久化窗口恢复（talagent / `com.apple.appkit.restoration_storage`）。
    ///
    /// **为什么必须关**：SwiftUI 的窗口恢复标识由**场景内容的泛型类型签名**派生
    /// （`SwiftUI.WindowGroup<…RootView…>-1-AppWindow-1`，见 `defaults read`）。只要视图
    /// 结构变一次 —— 本次就是给场景加了 `.environment(\.appVisualStyle, …)` —— 标识就变了；
    /// 而 macOS 仍拿**上一次运行保存的旧标识**来恢复：SwiftUI 的 `AppWindowsController`
    /// 认不出旧标识，恢复出来的窗口是 `nil`，于是启动后一个窗口都没有（实测日志：
    /// `_restoreWindowWithRestoration: … window=0x0` → `orderRestoredWindows … has no
    /// restoredWindow, skipping ordering`）。这不是「少了点状态」，是**升级后打不开窗口**。
    ///
    /// 关掉不丢功能：窗口尺寸/位置由 SwiftUI 自己写在 `NSWindow Frame …` 偏好里，与这套
    /// 恢复机制无关；`WindowManager.apply` 也会在窗口成为主窗口时重新套用定制。代价只有一个：
    /// 不再恢复上次退出时的窗口会话 —— 本应用只有一个主窗口 + 一个设置窗口，换不来什么。
    ///
    /// 时机：必须在 `NSApplicationMain` 之前写进偏好（`App.init()` 正好在它之前跑），
    /// AppKit 在启动流程早期读这个键。这里用 `set` 而不是 `register`：注册域优先级最低，
    /// 一旦别的域里存在同名键就会被盖掉，而这一条是「必须生效」的行为开关。
    static func disableWindowStateRestoration() {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// 风格环境值：只有**真实读取**才会订阅变化（`Theme.isPaper` 是全局镜像，读了不订阅）
    @Environment(\.appVisualStyle) private var appStyle
    @ObservedObject private var settings = AppSettings.shared
    /// 系统「降低透明度」：玻璃材质回落实底（§7.3）
    @ObservedObject private var display = AccessibilityDisplayObserver.shared

    var body: some View {
        Group {
            switch appState.phase {
            case .signedOut:
                // 登录页不在 `MainView` 那棵「按风格重建」的呈现子树里（见 JellyfinApp.body 的注释），
                // 所以这里单独给身份：风格一变就换一个视图，登录页的纸墨结构才会跟着翻，
                // 否则会停在「纸墨色 + 玻璃圆角」的中间态。登录表单的 @State 会复位，
                // 但登录页本来就没有值得跨风格保留的状态（而且切换风格要先开设置窗口，属刻意操作）。
                // 强调色也并进 id：理由见 `MainView` 里 `settings` 的注释（动态色重解析在
                // macOS 27 上不会让 SwiftUI 重绘，只有换视图身份才落得下新色阶）。
                LoginView()
                    .id("\(appStyle.rawValue)-\(settings.accent.rawValue)")
            case .signedIn:
                MainView()
            }
        }
        // 延伸到隐藏标题栏区域（fullSizeContentView），避免顶部露出透明条
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .animation(Theme.Motion.base, value: appState.phase)
        .background(Theme.canvas)
        // 系统「减少动态效果」或应用内设置任一开启即生效（§7）
        .environment(\.appReduceMotion, systemReduceMotion || settings.reduceMotion)
        // 系统「降低透明度」→ 全部玻璃换回 surface 实底（§7.3）
        .environment(\.appReduceTransparency, display.reduceTransparency)
        .toastHost()
        // 二次确认弹窗（破坏性操作）：请求记录发起窗口，只在该窗口渲染
        .dialogHost()
    }
}
