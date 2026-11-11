import AVKit
import SwiftUI

/// 聊天里的视频播放。
///
/// 视频必须先落到本地文件才能播（AVPlayer 不吃内存 Data），
/// 所以进视口时才下载，下载到临时目录后播放；离开视口自动暂停。
struct RemoteVideo: View {
    let path: String
    @EnvironmentObject private var model: AppModel

    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onDisappear { player.pause() }
            } else if failed {
                HStack(spacing: 6) {
                    Image(systemName: "video.slash").foregroundStyle(.secondary)
                    Text("视频加载失败").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("加载视频…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task { await prepare() }
    }

    private func prepare() async {
        guard player == nil else { return }
        do {
            let data = try await model.download(path: path)
            let ext = (path as NSString).pathExtension.isEmpty ? "mp4" : (path as NSString).pathExtension
            let filename = "dsh-video-\(abs(path.hashValue)).\(ext)"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            let item = AVPlayerItem(url: url)
            let created = AVPlayer(playerItem: item)
            created.isMuted = false
            player = created
            loading = false
        } catch {
            failed = true
            loading = false
        }
    }
}

/// 聊天里的音频播放：一条紧凑的控制条
struct RemoteAudio: View {
    let path: String
    @EnvironmentObject private var model: AppModel

    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var failed = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var timer: Timer?

    private var filename: String { (path as NSString).lastPathComponent }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await toggle() }
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(failed)

            VStack(alignment: .leading, spacing: 3) {
                Text(filename)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if failed {
                    Text("加载失败").font(.system(size: 10)).foregroundStyle(.red)
                } else {
                    ProgressView(value: duration > 0 ? min(progress / duration, 1) : 0)
                        .progressViewStyle(.linear)
                    Text("\(timeText(progress)) / \(timeText(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .onDisappear { stop() }
    }

    private func toggle() async {
        if player == nil { await prepare() }
        guard let player else { return }
        if playing {
            player.pause()
            playing = false
        } else {
            player.play()
            playing = true
            startTimer()
        }
    }

    private func prepare() async {
        do {
            let data = try await model.download(path: path)
            let ext = (path as NSString).pathExtension.isEmpty ? "mp3" : (path as NSString).pathExtension
            let filename = "dsh-audio-\(abs(path.hashValue)).\(ext)"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            let created = AVPlayer(url: url)
            player = created
            duration = await loadDuration(url)
            startTimer()
        } catch {
            failed = true
        }
    }

    private func loadDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = try? await asset.load(.duration).seconds
        return seconds?.isFinite == true ? (seconds ?? 0) : 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                guard let player else { return }
                progress = player.currentTime().seconds
                if duration == 0, let itemDuration = player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    duration = itemDuration
                }
            }
        }
    }

    private func stop() {
        player?.pause()
        playing = false
        timer?.invalidate()
        timer = nil
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
