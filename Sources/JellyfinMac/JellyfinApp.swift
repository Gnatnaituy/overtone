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
    }

    var body: some Scene {
        WindowGroup("Overtone") {
            RootView()
                .environmentObject(appState)
                .environmentObject(settings)
                .frame(minWidth: 520, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)

        // macOS 标准设置窗口：系统自带「设置…」菜单项与 ⌘, 快捷键
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(settings)
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
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject private var settings = AppSettings.shared
    /// 系统「降低透明度」：玻璃材质回落实底（§7.3）
    @ObservedObject private var display = AccessibilityDisplayObserver.shared

    var body: some View {
        Group {
            switch appState.phase {
            case .signedOut: LoginView()
            case .signedIn: MainView()
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
