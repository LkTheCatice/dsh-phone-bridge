import PencilKit
import SwiftUI
import UIKit

/// 让 UIImage 能直接用于 `.sheet(item:)`
extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// 图片标注编辑器：在图上画圈、划重点、涂改，完成后把笔迹压平进图片。
///
/// 画布尺寸跟随图片的宽高比，笔迹按「画布 → 原图」的比例缩放，
/// 所以无论手机屏幕多大，最终合成的都是原分辨率。
struct ImageEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let onCommit: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var drawing = PKDrawing()
    @State private var tool: PKTool = PKInkingTool(.pen, color: .systemRed, width: 4)
    @State private var strokeWidth: CGFloat = 4
    @State private var colorIndex = 0

    private static let palette: [UIColor] = [.systemRed, .systemBlue, .systemYellow, .systemGreen, .label]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let fitted = fittedSize(in: geo.size)
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: fitted.width, height: fitted.height)
                        CanvasView(
                            drawing: $drawing,
                            tool: $tool,
                            toolSignature: "\(colorIndex)-\(Int(strokeWidth))"
                        )
                        .frame(width: fitted.width, height: fitted.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(.systemGroupedBackground))

                toolbar
            }
            .navigationTitle("标注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onCommit(flatten())
                    }
                    .disabled(drawing.strokes.isEmpty)
                }
            }
            .onChange(of: strokeWidth) { _ in rebuildTool() }
            .onChange(of: colorIndex) { _ in rebuildTool() }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(Self.palette.enumerated()), id: \.offset) { index, color in
                    Circle()
                        .fill(Color(uiColor: color))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle().strokeBorder(
                                colorIndex == index ? Color.primary : Color.clear,
                                lineWidth: 2
                            )
                        )
                        .onTapGesture { colorIndex = index }
                }
                Spacer()
                Button {
                    drawing = PKDrawing()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(drawing.strokes.isEmpty)
            }

            HStack(spacing: 12) {
                Image(systemName: "scribble").foregroundStyle(.secondary)
                Slider(value: $strokeWidth, in: 1...20)
                Text("\(Int(strokeWidth))").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func rebuildTool() {
        tool = PKInkingTool(.pen, color: Self.palette[colorIndex], width: strokeWidth)
    }

    /// 图片按容器等比缩放后的尺寸
    private func fittedSize(in container: CGSize) -> CGSize {
        let imageRatio = image.size.width / max(1, image.size.height)
        let containerRatio = container.width / max(1, container.height)
        if imageRatio > containerRatio {
            let width = container.width
            return CGSize(width: width, height: width / imageRatio)
        }
        let height = container.height
        return CGSize(width: height * imageRatio, height: height)
    }

    /// 把笔迹压平进原图
    private func flatten() -> UIImage {
        guard !drawing.strokes.isEmpty else { return image }
        let rect = CGRect(origin: .zero, size: image.size)
        // 笔迹先按原图分辨率渲染，再叠到原图上
        let strokeImage = drawing.image(from: rect, scale: image.scale)
        let renderer = UIGraphicsImageRenderer(size: image.size, scale: image.scale)
        return renderer.image { _ in
            image.draw(in: rect)
            strokeImage.draw(in: rect)
        }
    }
}

/// PencilKit 画布
private struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var tool: PKTool
    /// 由父视图算好的「工具签名」：PKTool 不满足 Equatable，
    /// 用类型 + 笔宽 + 颜色判断要不要重设
    let toolSignature: String

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = tool
        canvas.delegate = context.coordinator
        context.coordinator.lastToolSignature = toolSignature
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if context.coordinator.lastToolSignature != toolSignature {
            context.coordinator.lastToolSignature = toolSignature
            canvas.tool = tool
        }
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let parent: CanvasView
        var lastToolSignature = ""
        init(_ parent: CanvasView) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
