import AVKit
import SwiftUI

/// 聊天里的视频播放。
///
/// 视频必须先落到本地文件才能播（AVPlayer 不吃内存 Data）。
/// 大文件不自动下载：先读 1 字节探大小，超过 20MB 只显示占位卡，
/// 用户点了才下载 —— 否则滚过去就悄悄吃掉几十 MB 流量。
struct RemoteVideo: View {
    /// 自动下载的上限；超过就等用户点
    private static let autoDownloadLimit: Int64 = 20 * 1024 * 1024

    let path: String
    @EnvironmentObject private var model: AppModel

    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var failed = false
    /// 探到的大小（0 = 未知）
    @State private var knownBytes: Int64 = 0
    /// 封面帧（大视频才取）
    @State private var poster: UIImage?
    /// 超过阈值，等用户点击
    @State private var waitingForTap = false
    /// 已下载字节 / 总字节
    @State private var loadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0

    private var filename: String { (path as NSString).lastPathComponent }

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onDisappear { player.pause() }
            } else if failed {
                card {
                    HStack(spacing: 6) {
                        Image(systemName: "video.slash").foregroundStyle(.secondary)
                        Text(L("视频加载失败", "Video failed to load")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if waitingForTap {
                // 大文件：先要封面帧（电脑侧 ffmpeg 抽好，几十 KB），点了才下整段
                card {
                    ZStack(alignment: .bottomLeading) {
                        if let poster {
                            Image(uiImage: poster)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 160)
                                .clipped()
                        } else {
                            Rectangle()
                                .fill(.quaternary.opacity(0.25))
                                .frame(height: 160)
                                .overlay {
                                    Image(systemName: "video")
                                        .font(.system(size: 26))
                                        .foregroundStyle(.secondary)
                                }
                        }
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.55)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 160)
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(filename)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                Text(L("\(byteText(knownBytes)) · 点击下载", "\(byteText(knownBytes)) · tap to download"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                    }
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    waitingForTap = false
                    loading = true
                    Task { await prepare() }
                }
            } else {
                card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(L("加载视频…", "Loading video…")).font(.caption).foregroundStyle(.secondary)
                        }
                        if totalBytes > 0 {
                            ProgressView(value: Double(loadedBytes), total: Double(totalBytes))
                                .progressViewStyle(.linear)
                            Text("\(byteText(loadedBytes)) / \(byteText(totalBytes))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task { await probe() }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 先探大小，再决定自动下载还是等用户点
    private func probe() async {
        guard player == nil, knownBytes == 0 else { return }
        let size = await model.probeFileSize(path: path)
        knownBytes = size
        if size > Self.autoDownloadLimit {
            waitingForTap = true
            loading = false
            // 封面帧只有几十 KB，先取来占位
            if let data = await model.downloadPoster(path: path),
               let image = UIImage(data: data) {
                poster = image
            }
            return
        }
        await prepare()
    }

    private func prepare() async {
        guard player == nil else { return }
        do {
            let data = try await model.download(path: path) { received, total in
                Task { @MainActor in
                    loadedBytes = received
                    totalBytes = total
                }
            }
            let ext = (path as NSString).pathExtension.isEmpty ? "mp4" : (path as NSString).pathExtension
            let cacheName = "dsh-video-\(abs(path.hashValue)).\(ext)"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(cacheName)
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

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                    Text(L("加载失败", "Load failed")).font(.system(size: 10)).foregroundStyle(.red)
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
