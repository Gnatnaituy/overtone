import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appState: AppState

    @State private var server = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @State private var username = UserDefaults.standard.string(forKey: "username") ?? ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    // 本 SDK 的 macOS 13 目标无泛型版 .focused(Value?)，用三个 Bool 焦点位模拟焦点链
    @FocusState private var serverFocused: Bool
    @FocusState private var usernameFocused: Bool
    @FocusState private var passwordFocused: Bool
    @State private var showContent = false
    /// 错误抖动偏移（0 → ±10 → 0）
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            auroraGlow

            VStack(spacing: 34) {
                logo
                loginForm
                footnote
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            withAnimation(Theme.bouncy) { showContent = true }
            // 下一轮 runloop 聚焦（视图已安装后）：已有服务器地址则直接聚焦到用户名
            DispatchQueue.main.async {
                if server.isEmpty { serverFocused = true } else { usernameFocused = true }
            }
        }
    }

    // MARK: - 表单

    private var loginForm: some View {
        VStack(spacing: 14) {
            field(index: 0) { serverField }
            field(index: 1) { usernameField }
            field(index: 2) { passwordField }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text(errorMessage)
                        .font(.system(size: 13))
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            field(index: 3) {
                Button(action: connect) {
                    HStack(spacing: 8) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text(isConnecting ? "连接中…" : "连接服务器")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isConnecting)
            }
        }
        .frame(width: 380)
        .offset(x: shakeOffset)
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
    }

    private var footnote: some View {
        Text("连接你自己的 Jellyfin 服务器 · 播放你的音乐库")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .opacity(showContent ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.5), value: showContent)
    }

    // MARK: - 输入框（拆分避免大表达式类型推断超时）

    private var serverField: some View {
        FlatFieldBox {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundStyle(Theme.secondaryText)
                TextField("服务器地址", text: $server)
                    .textFieldStyle(.plain)
                    .focused($serverFocused)
                    .onSubmit { usernameFocused = true }
            }
        }
        .overlay(focusBorder(highlight: serverFocused))
    }

    private var usernameField: some View {
        FlatFieldBox {
            HStack(spacing: 8) {
                Image(systemName: "person.fill")
                    .foregroundStyle(Theme.secondaryText)
                TextField("用户名", text: $username)
                    .textFieldStyle(.plain)
                    .focused($usernameFocused)
                    .onSubmit { passwordFocused = true }
            }
        }
        .overlay(focusBorder(highlight: usernameFocused))
    }

    private var passwordField: some View {
        FlatFieldBox {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.secondaryText)
                SecureField("密码", text: $password)
                    .textFieldStyle(.plain)
                    .focused($passwordFocused)
                    .onSubmit { connect() }
            }
        }
        .overlay(focusBorder(highlight: passwordFocused))
    }

    // MARK: - 入场错落动画

    @ViewBuilder
    private func field<Content: View>(index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(showContent ? 1 : 0)
            .offset(y: showContent ? 0 : 16)
            .animation(
                .spring(response: 0.45, dampingFraction: 0.82).delay(0.15 + Double(index) * 0.08),
                value: showContent
            )
    }

    private func focusBorder(highlight: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(highlight ? Theme.accentEnd : .clear, lineWidth: 1.5)
    }

    /// 左右往复抖动 3 次
    private func shake() {
        withAnimation(Animation.easeInOut(duration: 0.07).repeatCount(6, autoreverses: true)) {
            shakeOffset = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.1)) { shakeOffset = 0 }
        }
    }

    // MARK: - Logo

    private var logo: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Theme.accentGradient)
                    .frame(width: 78, height: 78)
                    .shadow(color: Theme.accentStart.opacity(0.28), radius: 16, y: 7)
                Image(systemName: "music.note")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(showContent ? 1 : 0.7)
            .opacity(showContent ? 1 : 0)
            .animation(Theme.bouncy, value: showContent)
            VStack(spacing: 4) {
                Text("Overtone")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("登录你的音乐库")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .opacity(showContent ? 1 : 0)
            .offset(y: showContent ? 0 : 10)
            .animation(.easeOut(duration: 0.45).delay(0.25), value: showContent)
        }
    }

    // MARK: - 极光背景（缓慢漂移的柔和光斑）

    private var auroraGlow: some View {
        ZStack {
            GlowBlob(
                color: Theme.accentStart.opacity(0.10),
                diameter: 480,
                start: CGPoint(x: -280, y: -240),
                end: CGPoint(x: -230, y: -190)
            )
            GlowBlob(
                color: Theme.accentEnd.opacity(0.09),
                diameter: 520,
                start: CGPoint(x: 300, y: 260),
                end: CGPoint(x: 240, y: 220)
            )
            GlowBlob(
                color: Color(hex: 0x5BC8C8).opacity(0.06),
                diameter: 380,
                start: CGPoint(x: 260, y: -280),
                end: CGPoint(x: 320, y: -220)
            )
        }
        .allowsHitTesting(false)
    }

    private func connect() {
        errorMessage = nil
        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty, !username.isEmpty, !password.isEmpty else {
            errorMessage = "请填写服务器地址、用户名和密码"
            shake()
            return
        }
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
}

/// 缓慢往返漂移的柔光斑
private struct GlowBlob: View {
    let color: Color
    let diameter: CGFloat
    let start: CGPoint
    let end: CGPoint

    @State private var drift = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .blur(radius: 130)
            .offset(x: drift ? end.x : start.x, y: drift ? end.y : start.y)
            .onAppear {
                withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                    drift = true
                }
            }
    }
}
