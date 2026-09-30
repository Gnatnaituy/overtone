import SwiftUI
import Darwin

@main
struct JellyfinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    init() {
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }

    var body: some Scene {
        WindowGroup("Overtone") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 白色主题：跟随系统浅色外观
        NSApp.appearance = NSAppearance(named: .aqua)

        // 会话恢复由这里驱动（不绑定视图生命周期，避免被取消）
        Task { @MainActor in
            await AppState.shared.restoreSession()
        }

        // 窗口每次成为主窗口时应用定制（覆盖 SwiftUI 对按钮显示状态的重置）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            WindowManager.apply(window)
        }

        // 未激活窗口的首次点击："单击直接生效"（等效于所有控件 acceptsFirstMouse = true）。
        // 系统默认会把窗口未激活时的第一次点击只用于激活窗口、不投递给控件，需点第二次才生效。
        // 不能依赖 SwiftUI 视图上覆盖 acceptsFirstMouse —— hosting view 会拦截控件区域的
        // hit-test，作为按钮背景的代表视图永远不会被询问到。这里先激活窗口，再把点击
        // 直接投递给命中视图；激活完成后再投递，避免 didBecomeKey 期间的窗口改写打断点击。
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  !window.isKeyWindow,
                  window.level == .normal else { return event }
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            window.makeKeyAndOrderFront(nil)
            if let hit = window.contentView?.hitTest(event.locationInWindow) {
                hit.mouseDown(with: event)
            }
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
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState

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
        .animation(.easeInOut(duration: 0.3), value: appState.phase)
        .background(Theme.background)
    }
}
