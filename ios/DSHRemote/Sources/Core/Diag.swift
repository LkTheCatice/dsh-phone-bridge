import Foundation

/// 轻量打点：把一行 tag 发到电脑侧 `/v1/health?d=…`，桥会写进日志。
///
/// 为什么要有这个：真机卡顿只能在设备上量，而这台开发机没有 Xcode/模拟器，
/// NSLog 只进设备控制台，我看不到。走 health 打点后，**我可以自己读日志定位**，
/// 不必让用户复述现象、也不必让他等我一轮轮试。
///
/// 约束（照 AGENTS.md）：
///   - 只在**低频**处调用（每次 apply 一次、每 40 次测量一次），不做逐帧打点
///   - 全部走后台队列，绝不阻塞主线程
///   - 参数名必须是 `d`（服务端读这个键）
enum Diag {
    /// 由 AppModel 在拿到配对信息时写入
    nonisolated(unsafe) static var endpoint: (host: String, port: Int)?

    private static let queue = DispatchQueue(label: "dsh.diag", qos: .background)

    static func ping(_ tag: String) {
        guard let endpoint else { return }
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tag
        guard let url = URL(string: "http://\(endpoint.host):\(endpoint.port)/v1/health?d=\(encoded)") else { return }
        queue.async {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }
    }
}
