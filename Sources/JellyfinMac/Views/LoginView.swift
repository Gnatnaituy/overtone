import SwiftUI

/// 登录页（重做，§4.1）：左右分栏（品牌区 360 + 表单卡 400），窄窗（<720）降级单列。
struct LoginView: View {
    @EnvironmentObject private var appState: AppState

    @State private var host = UserDefaults.standard.string(forKey: "serverHost") ?? ""
    @State private var scheme = UserDefaults.standard.string(forKey: "serverScheme") ?? "http"
    @State private var port = UserDefaults.standard.string(forKey: "serverPort") ?? ""
    @State private var clientName = UserDefaults.standard.string(forKey: "clientName") ?? "Overtone"
    @State private var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showAdvanced = false
    @State private var showContent = false
    @State private var shakeOffset: CGFloat = 0

    // 本 SDK 的 macOS 13 目标无泛型版 .focused(Value?)，用 Bool 焦点位模拟焦点链
    @FocusState private var hostFocused: Bool
    @FocusState private var usernameFocused: Bool
    @FocusState private var passwordFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let isNarrow = geo.size.width < 720
            Group {
                if isNarrow { narrowLayout } else { splitLayout }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .frame(minWidth: 520, minHeight: 480)
        // 顶部让出红黄绿三键的位置，并让这一条可以拖动窗口
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(height: Theme.Size.windowChromeHeight)
        }
        .onAppear {
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
                .frame(width: 360)
                .frame(maxHeight: .infinity)

            Rectangle().fill(Theme.borderSubtle).frame(width: 1)

            formPanel(isNarrow: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var narrowLayout: some View {
        VStack(spacing: Theme.Spacing.section) {
            brandMark
            formPanel(isNarrow: true)
        }
        .padding(Theme.Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }

    // MARK: - 左：品牌区（360pt）

    private var brandPanel: some View {
        ZStack {
            Theme.canvas
            glowLayer

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                brandMark

                Text("Overtone")
                    .textStyle(.display, color: Theme.textPrimary)
                    .padding(.top, Theme.Spacing.xl)

                Text("登录你的音乐库")
                    .textStyle(.body, color: Theme.textSecondary)
                    .padding(.top, Theme.Spacing.xs)

                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    featureRow("直连优先，兼容时直接播放原始文件")
                    featureRow("播放进度多端同步")
                    featureRow("独立音乐模块，页面间不中断")
                }
                .padding(.top, Theme.Spacing.xxxl)

                Spacer(minLength: 0)
            }
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
    }

    private var brandMark: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.xl)
            .fill(Theme.brandGradient)
            .frame(width: 72, height: 72)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .elevation(.e2)
            .scaleEffect(showContent ? 1 : 0.86)
            .opacity(showContent ? 1 : 0)
            .animation(Theme.Motion.spring, value: showContent)
    }

    private func featureRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.tealText)
                .padding(.top, 2)
            Text(text)
                .textStyle(.bodySM, color: Theme.textSecondary)
        }
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
    }

    // MARK: - 右：表单卡（400pt）

    private func formPanel(isNarrow: Bool) -> some View {
        VStack {
            Spacer(minLength: 0)
            formCard(isNarrow: isNarrow)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
        .background(isNarrow ? Theme.surface : Theme.surface)
    }

    private func formCard(isNarrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("连接服务器")
                .textStyle(.title3, color: Theme.textPrimary)
            Text("填写你的 Jellyfin 服务器地址与账号")
                .textStyle(.footnote, color: Theme.textSecondary)
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.xxl)

            VStack(spacing: 14) {
                hostField
                usernameField
                passwordField

                if let errorMessage {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                        Text(errorMessage)
                            .textStyle(.bodySM)
                    }
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                }

                connectButton

                advancedSection
            }
        }
        .offset(x: shakeOffset)
        .padding(28)
        .frame(width: isNarrow ? 380 : 400)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(Theme.borderSubtle)
        )
        .elevation(.e2)
        .opacity(showContent ? 1 : 0)
        .offset(y: showContent ? 0 : 12)
        .animation(Theme.Motion.base, value: showContent)
        .animation(Theme.Motion.micro, value: errorMessage)
    }

    // MARK: 字段

    private var hostField: some View {
        TokenField(height: Theme.Size.formFieldHeight, isFocused: hostFocused) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                TextField("服务器地址，如 192.168.1.10", text: $host)
                    .textFieldStyle(.plain)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .focused($hostFocused)
                    .onSubmit { usernameFocused = true }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var usernameField: some View {
        TokenField(height: Theme.Size.formFieldHeight, isFocused: usernameFocused) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                TextField("用户名", text: $username)
                    .textFieldStyle(.plain)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .focused($usernameFocused)
                    .onSubmit { passwordFocused = true }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var passwordField: some View {
        TokenField(height: Theme.Size.formFieldHeight, isFocused: passwordFocused) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                SecureField("密码", text: $password)
                    .textFieldStyle(.plain)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .focused($passwordFocused)
                    .onSubmit { connect() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: Theme.Spacing.md) {
                if isConnecting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(isConnecting ? "连接中…" : "连接服务器")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isConnecting)
        .padding(.top, Theme.Spacing.xs)
    }

    // MARK: 高级选项（协议 / 端口 / 客户端名）

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Button {
                withAnimation(Theme.Motion.base) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("高级选项")
                        .textStyle(.footnote, weight: .medium, color: Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAdvanced ? "收起高级选项" : "展开高级选项")

            if showAdvanced {
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

    /// 由 协议 + 主机 + 端口 组装服务器地址（主机里已含 scheme 时以输入为准）
    private var composedServer: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return "" }
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
        let server = composedServer
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty else {
            errorMessage = "请填写服务器地址、用户名和密码"
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
                try await appState.login(server: server, username: username, password: password)
            } catch {
                errorMessage = error.localizedDescription
                shake()
            }
            isConnecting = false
        }
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
