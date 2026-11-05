import SwiftUI
import UIKit

/// 系统分享面板, 用于导出棋谱
struct ShareSheetView: UIViewControllerRepresentable {
    var url: URL
    var title: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
