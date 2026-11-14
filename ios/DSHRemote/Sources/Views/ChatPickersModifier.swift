import SwiftUI
import PhotosUI

/// 附件选择相关的一整组 modifier（文件 / 相册图片 / 相册视频）。
///
/// 拆出来的原因：这些 `.fileImporter` / `.photosPicker` / `.onChange` 挂在
/// chatContent 的链上，会让 Swift 对整个表达式做类型推断时超时
/// （CI 报 `Task { await loadVideos(items) }` 那一行无法推断）。
/// 收进一个 modifier 后，chatContent 上只多一行。
struct ChatPickersModifier: ViewModifier {
    @Binding var showFiles: Bool
    @Binding var importingAudio: Bool
    @Binding var showPhotos: Bool
    @Binding var photoItems: [PhotosPickerItem]
    @Binding var showVideos: Bool
    @Binding var videoItems: [PhotosPickerItem]

    let onFile: (Result<[URL], Error>) -> Void
    let onPhotos: ([PhotosPickerItem]) async -> Void
    let onVideos: ([PhotosPickerItem]) async -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showFiles,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in onFile(result) }
            .fileImporter(
                isPresented: $importingAudio,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in onFile(result) }
            .photosPicker(
                isPresented: $showPhotos,
                selection: $photoItems,
                maxSelectionCount: 9,
                matching: .images
            )
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task { await onPhotos(items) }
            }
            .photosPicker(
                isPresented: $showVideos,
                selection: $videoItems,
                maxSelectionCount: 3,
                matching: .videos
            )
            .onChange(of: videoItems) { items in
                guard !items.isEmpty else { return }
                Task { await onVideos(items) }
            }
    }
}
