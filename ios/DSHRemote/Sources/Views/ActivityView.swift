import SwiftUI
import UIKit

/// 包一层 UIActivityViewController：ShareLink 只能由用户点按钮触发，
/// 而这里的分享是「下载完成后自动弹出」，只能走程序化呈现。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
