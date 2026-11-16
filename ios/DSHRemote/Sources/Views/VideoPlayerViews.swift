import AVKit
import SwiftUI
import UIKit

/// 全屏播放时的方向闸门。
///
/// 整个 App 是竖屏设计的（对话、列表都是竖向排版），所以 Info.plist 里只声明了
/// `.portrait`。但视频全屏必须能横过来 —— 否则点了"全屏"只是把画面放大到竖屏里，
/// 观感上等于"没全屏"（实拍反馈）。
///
/// 做法：Info.plist 放开横屏，再由 AppDelegate 按这个开关决定**当前**允许的方向。
/// 平时锁竖屏，全屏播放器出现时放开。
final class OrientationGate {
    static let shared = OrientationGate()
    var allowLandscape = false

    /// 改完要通知系统重新问一次方向，否则不会立刻生效
    func refresh() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: allowLandscape ? .allButUpsideDown : .portrait))
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationGate.shared.allowLandscape ? .allButUpsideDown : .portrait
    }
}

// MARK: - 行内播放器（无系统控件）

/// 行内只负责"能看见画面"，不提供控件。
///
/// 之前用的是 SwiftUI 的 `VideoPlayer`：它自带一套 AVPlayerViewController，
/// 但那套控件的"全屏"依赖自己所在的容器和方向，被 `.frame(height: 220)`
/// 和 `.clipShape(...)` 包住之后点了没反应（实拍反馈）。
/// 现在行内极简化：只有画面，点一下进我们的全屏播放器。
struct InlineVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.attach(player)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.attach(player)
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func attach(_ player: AVPlayer) {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
}

// MARK: - 全屏播放器

/// 全屏播放：真正带控件的 AVPlayerViewController，并放开横屏。
struct FullScreenVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = false
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        // 让 AVPlayerViewController 自己接管旋转
        vc.modalPresentationStyle = .fullScreen
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
    }
}

/// 全屏容器：负责开方向闸门、加一个"关闭"按钮、退出时复原。
///
/// `AVPlayerViewController` 自己的 Done 按钮在某些 iOS 版本上不可靠，
/// 所以外面套一层我们自己的关闭按钮。
struct FullScreenVideoSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                FullScreenVideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                player?.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
            OrientationGate.shared.allowLandscape = true
            OrientationGate.shared.refresh()
        }
        .onDisappear {
            player?.pause()
            player = nil
            OrientationGate.shared.allowLandscape = false
            OrientationGate.shared.refresh()
        }
        .preferredColorScheme(.dark)
    }
}
