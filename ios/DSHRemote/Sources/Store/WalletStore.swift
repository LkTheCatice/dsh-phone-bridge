import Foundation
import Combine

/// 账户余额（设置页显示）。
///
/// 拆出来的理由跟 ComfyStore 一样：这几个字段原本挂在 AppModel 上，
/// 而 ChatView / SettingsView 都用 `@EnvironmentObject var model: AppModel`
/// 订阅整个对象 —— 让这 4 个低频字段也参与全量通知没有必要。
///
/// 特别说明「拿不到数字」的情形：
/// 电脑端 DSH 的 `getBalance()` 内部要读某个没初始化的 HTTP client，
/// 会抛 `Cannot read properties of undefined (reading 'version')`。
/// 但 `getState()` 能给出 `status: "credential-stored"` 和用量页链接，
/// 所以桥层会用 getState 兜底，这里据实显示「已登录但取不到数字」，
/// 而不是谎报「没登录」。
@MainActor
final class WalletStore: ObservableObject {
    struct Wallet: Identifiable, Equatable {
        let currency: String
        let balance: String
        var id: String { currency }
        var isBonus: Bool = false
    }

    @Published private(set) var wallets: [Wallet] = []
    @Published private(set) var status: String = "idle"
    /// 服务端给的失败原因（设置页显示，便于判断是没登录还是接口问题）
    @Published private(set) var detail: String?
    /// 余额接口不可用时的兜底链接（DSH 会给出 usage 页地址）
    @Published private(set) var usageUrl: String?

    func apply(_ raw: [String: Any]) {
        status = (raw["status"] as? String) ?? "unknown"
        detail = raw["detail"] as? String
        usageUrl = ((raw["links"] as? [String: Any])?["usageUrl"] as? String)

        func parse(_ key: String, bonus: Bool) -> [Wallet] {
            (raw[key] as? [[String: Any]] ?? []).compactMap { item in
                guard let currency = item["currency"] as? String, !currency.isEmpty else { return nil }
                return Wallet(
                    currency: currency,
                    balance: (item["balance"] as? String) ?? "-",
                    isBonus: bonus
                )
            }
        }
        wallets = parse("wallets", bonus: false) + parse("bonuses", bonus: true)
    }

    func markLoading() {
        status = "loading"
    }

    func markFailed(_ message: String) {
        status = "failed"
        detail = message
        wallets = []
    }
}
