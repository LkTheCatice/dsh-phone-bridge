import SwiftUI

@main
struct DSHRemoteApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isPaired {
                MainView()
            } else {
                PairingView()
            }
        }
        // 微信 / QQ / 文件 App 里「用其他应用打开」递进来的文件
        .onOpenURL { url in
            Task { await model.ingestExternalFile(url) }
        }
        .sheet(item: $model.pendingIncoming) { file in
            IncomingFileSheet(file: file)
                .environmentObject(model)
        }
        // 错误改成顶部 toast：alert 会挡住操作，且每次都要点「知道了」
        .overlay(alignment: .top) {
            if let text = model.toast ?? model.lastError {
                Text(text)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        model.toast = nil
                        model.lastError = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .animation(.easeInOut(duration: 0.2), value: model.lastError)
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
