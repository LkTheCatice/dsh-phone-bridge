import SwiftUI

/// 产物文件分类（手机侧独立判断，不依赖桥下发）。
///
/// 用途：
///   ① 卡片左侧显示对应图标（图片 / 视频 / 文档 / 文本 / 压缩包 / 安装包）
///   ② 卡片右侧给出**能力标签**：「可预览」还是「仅下载」
///   ③ 点开时决定用哪个预览器
///
/// 为什么手机侧也要判断一次：桥的 `kind` 是新增字段，老桥（没重启）不会带；
/// 本地按扩展名兜底，卡片就不会退化成"什么都不知道"。
enum FileKind: String {
    case image, video, audio, text, doc, archive, package, other

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff":
            self = .image
        case "mp4", "mov", "m4v", "webm", "mkv", "avi":
            self = .video
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            self = .audio
        case "md", "markdown", "txt", "csv", "tsv", "json", "log", "yml", "yaml", "html", "htm", "xml":
            self = .text
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pdf", "epub":
            self = .doc
        case "zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz":
            self = .archive
        case "ipa", "apk", "dmg", "pkg", "exe", "msi":
            self = .package
        default:
            self = .other
        }
    }

    var icon: String {
        switch self {
        case .image: return "🖼"
        case .video: return "🎬"
        case .audio: return "🎧"
        case .text: return "📝"
        case .doc: return "📄"
        case .archive: return "🗜"
        case .package: return "📦"
        case .other: return "📎"
        }
    }

    /// 能不能在手机里直接看
    var canPreview: Bool {
        switch self {
        case .image, .video, .audio, .text: return true
        case .doc, .archive, .package, .other: return false
        }
    }

    /// 卡片右侧的标签文案
    var tag: String { canPreview ? L("可预览", "Preview") : L("下载", "Download") }
}
