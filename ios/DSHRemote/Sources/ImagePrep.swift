import UIKit

/// 上传前先把图片压小。
///
/// 相册里的原图动辄 10–20MB（HEIC/PNG 更大），直接读成 Data 再走加密上传，
/// 手机端会明显卡住 —— 之前在选完多张图后卡死就是这个原因。
enum ImagePrep {
    /// 长边不超过 2048，JPEG 质量 0.82：一般压到 200–600KB，画质看不出来
    static func compress(_ data: Data, maxSide: CGFloat = 2048, quality: CGFloat = 0.82) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let longest = max(image.size.width, image.size.height)
        if longest <= maxSide, data.count < 900_000 {
            // 本来就够小，直接转一次 JPEG 去掉可能的 alpha/元数据
            return image.jpegData(compressionQuality: quality) ?? data
        }
        let scale = min(1, maxSide / longest)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality) ?? data
    }
}
