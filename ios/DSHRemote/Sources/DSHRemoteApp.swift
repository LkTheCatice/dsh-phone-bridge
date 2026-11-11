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
        .alert("出错了", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("知道了", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}
