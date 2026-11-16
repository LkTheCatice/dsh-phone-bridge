import SwiftUI

@main
struct DSHRemoteApp: App {
    /// 视频全屏要能横过来：方向由 OrientationGate 控制（见 VideoPlayerViews.swift）
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
            .environmentObject(model.sessionList)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var theme = UITheme.shared

    var body: some View {
        Group {
            if model.isPaired {
                MainView()
            } else {
                PairingView()
            }
        }
        // 切语言时整棵树重建：SwiftUI 不会因为 UserDefaults 变化重算，
        // 而我们的文案是 L() 现取的字符串，必须靠身份变化触发一次完整求值。
        .id(I18N.shared.token)
        // 外观：界面里没有写死的颜色，挂在这里整套跟着变
        .preferredColorScheme(theme.selection.colorScheme)
        // 微信 / QQ / 文件 App 里「用其他应用打开」递进来的文件
        .onOpenURL { url in
            Task { await model.ingestExternalFile(url) }
        }
        .sheet(item: $model.pendingIncoming) { file in
            IncomingFileSheet(file: file)
                .environmentObject(model)
            .environmentObject(model.sessionList)
        }
        // 错误改成顶部 toast：alert 会挡住操作，且每次都要点「知道了」
        .overlay(alignment: .top) {
            if let text = model.toast ?? model.lastError {
                Text(text)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    // 效率档不用模糊材质（省 GPU），换成不透明的次级背景
                    .background(Motion.material(.regularMaterial, fallback: Color(.secondarySystemBackground)), in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .transition(Motion.transition(.move(edge: .top).combined(with: .opacity)))
                    .onTapGesture {
                        model.toast = nil
                        model.lastError = nil
                    }
            }
        }
        .animation(Motion.anim(.easeInOut(duration: 0.2)), value: model.toast)
        .animation(Motion.anim(.easeInOut(duration: 0.2)), value: model.lastError)
        .onChange(of: model.lastError) { error in
            // lastError 也走 3 秒自动消失
            guard let error, !error.isEmpty else { return }
            let captured = error
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if model.lastError == captured { model.lastError = nil }
            }
        }
    }
}
