import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 上传前把图片压小。
///
/// 之前用的是 `UIImage(data:)` → `UIGraphicsImageRenderer` → `jpegData`，
/// 也就是「先解全图、再重绘、再编码」。一张 2835×6144 的截图是 1700 万像素，
/// 光解码就要 60MB+，在主线程上跑会把触控直接堵死（上传完就卡住就是这个原因）。
///
/// 现在改用 `CGImageSourceCreateThumbnailAtIndex`：解码阶段就只产出目标尺寸，
/// 内存和 CPU 都降一个数量级；调用方再把整段放到后台线程，界面完全不卡。
///
/// 另外 `UIImage.size` 返回的是**点**不是像素 —— 3x 截图的 6144 像素会被当成
/// 2048 点，于是漏掉缩放（之前那个「压了但尺寸没变」就是这个 bug）。
/// 判断真实尺寸必须用 CGImageSource 的 PixelWidth/PixelHeight。
enum ImagePrep {
    static func compress(_ data: Data, maxPixel: Int = 2048, quality: CGFloat = 0.82) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0

        // 本来就够小：就地重编码，去掉 alpha 和元数据，不缩放
        if width > 0, height > 0, max(width, height) <= maxPixel, data.count < 900_000 {
            guard let image = UIImage(data: data) else { return data }
            return image.jpegData(compressionQuality: quality) ?? data
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return data
        }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: quality) ?? data
    }
}
