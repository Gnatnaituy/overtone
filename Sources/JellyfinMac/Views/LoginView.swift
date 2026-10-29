import SwiftUI

/// 登录页（§2 页面骨架 / §4.1 品牌母题 / §4.5 组件 / §7 玻璃）。
///
/// - 左：品牌区 360pt —— 品牌渐变 logo 72（圆角 20）+ `display` 34/700 标题 + 副标题 +
///   底部三条特性行（图标走 `tealText`，第二谐波语义）。
/// - 右：表单卡 380pt —— `surface` + `Radius.xl` + `elevation(.e2, cornerRadius:)`，
///   输入框高 44（`Theme.Size.formFieldHeight`），主按钮 `PrimaryButtonStyle` 撑满宽度。
/// - 窄窗（width < 860）：隐藏品牌区，只留表单卡；顶部 28pt 是窗口拖拽条，内容不压上去。
struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    /// 订阅视觉风格：`Theme.isPaper` 是全局镜像、读了不订阅；同时用它当呈现子树的 `.id`，
    /// 切风格只重建呈现层，本视图的 @State（服务器地址 / 用户名 / 密码 / 高级选项）全部保留
    @Environment(\.appVisualStyle) private var appStyle

    /// 登录目标后端（Jellyfin / 飞牛音乐）。切换时回填该后端上次用过的地址与账号。
    @State private var backendKind: BackendKind = BackendRegistry.shared.activeKind
    @State private var host = ""
    @State private var scheme = UserDefaults.standard.string(forKey: "serverScheme") ?? "http"
    @State private var port = UserDefaults.standard.string(forKey: "serverPort") ?? ""
    @State private var clientName = UserDefaults.standard.string(forKey: "clientName") ?? "Overtone"
    @State private var username = ""
    @State private var password = ""
    /// 飞牛音乐的可选安全码（`x-access-code`）
    @State private var accessCode = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    /// 仅本地校验失败时点亮字段错误态（服务端 / 网络错误只走内联横幅）
    @State private var showsFieldError = false
    @State private var showAdvanced = false
    @State private var showContent = false
    @State private var shakeOffset: CGFloat = 0

    // 本 SDK 的 macOS 13 目标无泛型版 .focused(Value?)，用 Bool 焦点位模拟焦点链
    @FocusState private var hostFocused: Bool
    @FocusState private var usernameFocused: Bool
    @FocusState private var passwordFocused: Bool

    /// 品牌区宽度（§2 登录页线框）
    private let brandWidth: CGFloat = 360
    /// 表单卡宽度（§2 登录页线框）
    private let cardWidth: CGFloat = 380
    /// 窄窗阈值：低于此宽度隐藏品牌区
    private let narrowThreshold: CGFloat = 860

    var body: some View {
        GeometryReader { geo in
            let isNarrow = geo.size.width < narrowThreshold
            Group {
                if isNarrow { narrowLayout } else { splitLayout }
            }
            // 顶部让出红黄绿三键的 28pt 拖拽条，内容不侵入
            .padding(.top, Theme.Size.windowChromeHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.Motion.base, value: isNarrow)
            // 换风格重建呈现子树（玻璃的品牌光晕 / 纸墨的反色版头是两套结构）。
            // 挂在 Group 上而不是本视图最外层：@State 与 .onAppear 的焦点安排都不会被打断
            .id(appStyle)
        }
        // 登录页也走氛围层：玻璃 chrome 之下必须有可透的内容（§7.2 规则 3）
        .background {
            ZStack {
                Theme.canvas
                AmbientWash()
            }
            .ignoresSafeArea()
        }
        .frame(minWidth: 520, minHeight: 480)
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(height: Theme.Size.windowChromeHeight)
        }
        .onAppear {
            prefillForBackend()
            withAnimation(Theme.Motion.base) { showContent = true }
            DispatchQueue.main.async {
                if host.isEmpty { hostFocused = true } else { usernameFocused = true }
            }
        }
    }

    // MARK: - 布局

    private var splitLayout: some View {
        HStack(spacing: 0) {
            brandPanel
                .frame(width: brandWidth)
                .frame(maxHeight: .infinity)

            formPanel
        }
    }

    /// 窄窗：品牌区整块隐藏，只留表单卡（居中）
    private var narrowLayout: some View {
        formCard
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, Theme.Spacing.section)
    }

    // MARK: - 左：品牌区（360pt）

    private var brandPanel: some View {
        ZStack {
            if Theme.isPaper {
                // 品牌面板固定反色（§2.1）：墨底 + 纸字，双主题一致 —— 像报纸的固定版头。
                // 走 `Paper.panelFill` / `panelInk` 这对专用令牌（不是 `ink` / `sheet`：
                // 那对是「当前主题的墨与纸」，会随深色主题翻成浅底）。
                // 不用氛围 wash：印刷品没有灯光
                Theme.Paper.panelFill
            } else {
                // 不铺 canvas：让窗口氛围层透过来，左右两侧才是同一张底（§7.2 规则 3）
                glowLayer
            }

            brandPanelContent
        }
        .clipped()
    }

    @ViewBuilder
    private var brandPanelContent: some View {
        if Theme.isPaper {
            VStack(alignment: .leading, spacing: 0) {
                // 品牌图形首演：～谐波线～ 纸色于墨底（§6.1）
                HarmonicLines(count: 1)
                    .stroke(
                        Theme.Paper.panelInk,
                        style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                    )
                    .frame(width: 76, height: 22)

                Text("泛音")
                    .textStyle(.display, color: Theme.Paper.panelInk)
                    .padding(.top, Theme.Spacing.xl)

                Text("OVERTONE")
                    .textStyle(.caption, weight: .bold, color: Theme.Paper.panelInk.opacity(0.72))
                    .tracking(6)
                    .padding(.top, Theme.Spacing.md)

                Rectangle()
                    .fill(Theme.Paper.signal)
                    .frame(width: 44, height: 2)
                    .padding(.vertical, Theme.Spacing.xxl)

                Text("基音之上，叠加一层听感。")
                    .paperSerifTitle(.bodyLG, weight: .regular,
                                     color: Theme.Paper.panelInk.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Theme.Spacing.section)

                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    featureRow("直连优先，兼容时直接播放原始文件", systemImage: "bolt.fill")
                    featureRow("播放进度多端同步", systemImage: "arrow.triangle.2.circlepath")
                    featureRow("独立音乐模块，页面间不中断", systemImage: "music.note")
                }

                Text("非官方客户端 · 与 Jellyfin 项目无隶属关系")
                    .textStyle(.caption, color: Theme.Paper.panelInk.opacity(0.5))
                    .padding(.top, Theme.Spacing.xxl)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, Theme.Spacing.section)
            .padding(.bottom, Theme.Spacing.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                brandMark

                Text("Overtone")
                    .textStyle(.display, color: Theme.textPrimary)
                    .padding(.top, Theme.Spacing.xl)

                Text("登录你的音乐库")
                    .textStyle(.body, color: Theme.textSecondary)
                    .padding(.top, Theme.Spacing.xs)

                Spacer(minLength: Theme.Spacing.section)

                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    featureRow("直连优先，兼容时直接播放原始文件", systemImage: "bolt.fill")
                    featureRow("播放进度多端同步", systemImage: "arrow.triangle.2.circlepath")
                    featureRow("独立音乐模块，页面间不中断", systemImage: "music.note")
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, Theme.Spacing.section)
            .padding(.bottom, Theme.Spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var brandMark: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.xl)
            .fill(Theme.brandGradient)
            .frame(width: 72, height: 72)
            .overlay(
                Image(systemName: "music.note")
                    .textStyle(.title1, color: Theme.textOnAccent)
            )
            .elevation(.e2, cornerRadius: Theme.Radius.xl)
            .scaleEffect(showContent ? 1 : 0.86)
            .opacity(showContent ? 1 : 0)
            .animation(Theme.Motion.spring, value: showContent)
            .accessibilityHidden(true)
    }

    /// 特性行：图标用 `tealText`（第二谐波），文字 13 `textSecondary`。
    /// paper 的品牌栏是**固定反色版头**（`panelFill` / `panelInk`），语义令牌
    /// （ink-2 / 泛音青）在墨上对比度不足，所以这里换版头纸字档 ——
    /// glass 侧取值一个字都没动。
    private func featureRow(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .textStyle(.footnote,
                           color: Theme.isPaper ? Theme.Paper.panelInk.opacity(0.55) : Theme.tealText)
                .frame(width: Theme.Spacing.xl, alignment: .leading)
            Text(text)
                .textStyle(.bodySM,
                           color: Theme.isPaper ? Theme.Paper.panelInk.opacity(0.82) : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 极低透明度光晕（brandGradient + 泛音青）
    private var glowLayer: some View {
        ZStack {
            Circle()
                .fill(Theme.brand500.opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 70)
                .offset(x: -90, y: -70)
            Circle()
                .fill(Theme.overtoneTeal.opacity(0.16))
                .frame(width: 250, height: 250)
                .blur(radius: 70)
                .offset(x: 90, y: 170)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 右：表单卡（380pt）

    private var formPanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            formCard
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.xxl)
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            backendSelector
                .padding(.bottom, Theme.Spacing.lg)

            Text("连接服务器")
                // §6.1：paper 右栏标题用 title3 衬线（字符映射由 Theme 的字形切换完成）
                .textStyle(Theme.isPaper ? .title3 : .title4, color: Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(backendKind == .feiniu
                 ? "填写 FN ID 或飞牛 NAS 地址，以及飞牛音乐账号"
                 : "填写你的 Jellyfin 服务器地址与账号")
                .textStyle(.footnote, color: Theme.textSecondary)
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.xxl)

            VStack(spacing: Theme.Spacing.lg) {
                hostField
                usernameField
                passwordField

                if let errorMessage {
                    if Theme.isPaper {
                        // §6.1：错误态 = 字段下 1px 信号红 + caption 信号红文案（不弹窗、不横幅）。
                        // 字段本身的红色下划线由 TokenField 的 isError 承担
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            Rectangle()
                                .fill(Theme.Paper.signal)
                                .frame(width: 16, height: 1)
                                .padding(.top, Theme.Spacing.md)
                            Text(errorMessage)
                                .textStyle(.caption, color: Theme.Paper.signalInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .transition(.opacity)
                    } else {
                        InlineBanner(kind: .error, message: errorMessage)
                            .transition(.opacity)
                    }
                }

                connectButton

                advancedSection
            }
        }
        .padding(Theme.Spacing.xxxl)
        .frame(width: cardWidth)
        .modifier(LoginCardChrome())
        .offset(x: shakeOffset)
        .opacity(showContent ? 1 : 0)
        .offset(y: showContent ? 0 : 12)
        .animation(Theme.Motion.base, value: showContent)
        .animation(Theme.Motion.micro, value: errorMessage)
    }

    /// 表单卡外观：glass = surface 卡 + e2；paper = 直接落在纸面上（§6.1 右栏纸底），
    /// 没有卡片、没有投影 —— 印刷品用细线与留白分区
    private struct LoginCardChrome: ViewModifier {
        func body(content: Content) -> some View {
            if Theme.isPaper {
                content
            } else {
                content
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.xl)
                            .fill(Theme.surface)
                    )
                    // 深色主题下 e2 自动降级为 borderSubtle 描边（§4.2 规则 1）
                    .elevation(.e2, cornerRadius: Theme.Radius.xl)
            }
        }
    }

    // MARK: 字段（高 44，聚焦 / 错误态由 TokenField 承担）

    private var hostField: some View {
        TokenField(
            height: Theme.Size.formFieldHeight,
            isFocused: hostFocused,
            isError: showsFieldError
        ) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "server.rack")
                    .textStyle(.bodySM, color: Theme.textTertiary)
                TextField(backendKind.serverPlaceholder, text: $host)
                    .textFieldStyle(.plain)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .focused($hostFocused)
                    .onSubmit { usernameFocused = true }
                    .accessibilityLabel("服务器地址")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var usernameField: some View {
        TokenField(
            height: Theme.Size.formFieldHeight,
            isFocused: usernameFocused,
            isError: showsFieldError
        ) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "person.fill")
                    .textStyle(.bodySM, color: Theme.textTertiary)
                TextField("用户名", text: $username)
                    .textFieldStyle(.plain)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .focused($usernameFocused)
                    .onSubmit { passwordFocused = true }
                    .accessibilityLabel("用户名")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var passwordField: some View {
        TokenField(
            height: Theme.Size.formFieldHeight,
            isFocused: passwordFocused,
            isError: showsFieldError
        ) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "lock.fill")
                    .textStyle(.bodySM, color: Theme.textTertiary)
                SecureField("密码", text: $password)
                    .textFieldStyle(.plain)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .focused($passwordFocused)
                    .onSubmit { connect() }
                    .accessibilityLabel("密码")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: Theme.Spacing.md) {
                if isConnecting {
                    ProgressView().controlSize(.small).tint(Theme.textOnAccent)
                } else {
                    Image(systemName: "arrow.right")
                        .textStyle(.bodySM, weight: .semibold, color: Theme.textOnAccent)
                }
                Text(isConnecting ? "连接中…" : "连接服务器")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isConnecting)
        .padding(.top, Theme.Spacing.xs)
        .accessibilityLabel(isConnecting ? "正在连接服务器" : "连接服务器")
    }

    // MARK: 高级选项（协议 / 端口 / 客户端名）

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if backendKind == .feiniu {
                accessCodeSection
            }
            Button {
                withAnimation(Theme.Motion.base) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .textStyle(.caption, color: Theme.textSecondary)
                    Text("高级选项")
                        .textStyle(.footnote, weight: .medium, color: Theme.textSecondary)
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .hitExpand(from: 28, to: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAdvanced ? "收起高级选项" : "展开高级选项")

            if showAdvanced && backendKind == .jellyfin {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    HStack(spacing: Theme.Spacing.lg) {
                        Text("协议")
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        SegmentedControl(
                            segments: [.init("http", "http"), .init("https", "https")],
                            selection: $scheme
                        )
                    }

                    HStack(spacing: Theme.Spacing.lg) {
                        Text("端口")
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        TokenField {
                            TextField("8096（留空用默认）", text: $port)
                                .textFieldStyle(.plain)
                                .textStyle(.bodySM, color: Theme.textPrimary)
                                .accessibilityLabel("端口")
                        }
                        .frame(maxWidth: .infinity)
                    }

                    HStack(spacing: Theme.Spacing.lg) {
                        Text("客户端名")
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        TokenField {
                            TextField("Overtone", text: $clientName)
                                .textFieldStyle(.plain)
                                .textStyle(.bodySM, color: Theme.textPrimary)
                                .accessibilityLabel("客户端名称")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.top, Theme.Spacing.md)
    }

    // MARK: - 动作

    /// 由 协议 + 主机 + 端口 组装服务器地址（主机里已含 scheme 时以输入为准）。
    /// 飞牛的基址形态由后端自己规范化（可能带 `/music` 前缀或 FN ID），这里原样传。
    private var composedServer: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return "" }
        if backendKind == .feiniu { return trimmedHost }
        if trimmedHost.contains("://") { return trimmedHost }

        var value = "\(scheme)://\(trimmedHost)"
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPort.isEmpty, !trimmedHost.contains(":") {
            value += ":\(trimmedPort)"
        }
        return value
    }

    private func connect() {
        errorMessage = nil
        showsFieldError = false
        let server = composedServer
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty else {
            errorMessage = "请填写服务器地址、用户名和密码"
            showsFieldError = true
            shake()
            return
        }

        UserDefaults.standard.set(host, forKey: "serverHost")
        UserDefaults.standard.set(scheme, forKey: "serverScheme")
        UserDefaults.standard.set(port, forKey: "serverPort")
        UserDefaults.standard.set(clientName, forKey: "clientName")

        isConnecting = true
        Task {
            do {
                try await appState.signIn(
                    server: server,
                    username: username,
                    password: password,
                    backend: backendKind,
                    accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                shake()
            }
            isConnecting = false
        }
    }

    // MARK: - 后端选择与回填

    /// 后端选择器（分段控件）——登录页顶部
    private var backendSelector: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("服务器类型")
                .textStyle(.caption, color: Theme.textSecondary)
            SegmentedControl(
                segments: BackendKind.allCases.map { .init($0.rawValue, $0.displayName) },
                selection: Binding(
                    get: { backendKind.rawValue },
                    set: { raw in
                        guard let kind = BackendKind(rawValue: raw), kind != backendKind else { return }
                        backendKind = kind
                        errorMessage = nil
                        showsFieldError = false
                        prefillForBackend()
                        // 该后端之前登录过（内存会话 / 已存会话 / 已存密码）就直接进去，
                        // 不再让用户重输密码 —— 凭证本来就是按后端分别保存的。
                        Task { await appState.activateFromLogin(kind) }
                    }
                )
            )
        }
    }

    /// 飞牛音乐的可选安全码（部分 NAS 开启了访问码）
    private var accessCodeSection: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text("安全码")
                .textStyle(.footnote, color: Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            TokenField {
                SecureField("可选（NAS 未开启访问码则留空）", text: $accessCode)
                    .textFieldStyle(.plain)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .accessibilityLabel("安全码")
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 按当前后端回填上次的服务器地址与账号（凭据按后端命名空间存放）。
    /// 飞牛上次若是用 FN ID 连的，就回填 FN ID 而不是当时解析出来的中继地址 ——
    /// 中继地址会变，FN ID 不会。
    private func prefillForBackend() {
        let persistence = SessionPersistence.shared
        if backendKind == .feiniu, let fnID = persistence.loadSession(.feiniu)?.fnID {
            host = fnID
        } else if let lastServer = persistence.lastServerURL(backendKind) {
            host = displayHost(from: lastServer)
        } else if backendKind == .jellyfin,
                  let legacy = UserDefaults.standard.string(forKey: "serverHost") {
            host = legacy
        } else {
            host = ""
        }
        username = persistence.lastUsername(backendKind)
            ?? (backendKind == .jellyfin ? UserDefaults.standard.string(forKey: "username") ?? "" : "")
        password = ""
        accessCode = persistence.accessCode(backendKind) ?? ""
    }

    /// 已存地址回填到输入框时去掉 scheme 前缀（界面里另有「协议」分段）
    private func displayHost(from stored: String) -> String {
        guard backendKind == .jellyfin else { return stored }
        var value = stored
        for prefix in ["http://", "https://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        return value
    }

    /// 左右往复抖动 3 次
    private func shake() {
        withAnimation(Animation.easeInOut(duration: 0.07).repeatCount(6, autoreverses: true)) {
            shakeOffset = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(Theme.Motion.micro) { shakeOffset = 0 }
        }
    }
}
