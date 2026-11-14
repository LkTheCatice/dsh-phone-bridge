import Foundation

/// 读取 App 自己证书的到期时间。
///
/// 为什么需要：免费签名只有 **7 天**，到期后 App 一打开就闪退 ——
/// 用户往往是"用着用着突然打不开"，完全不知道是签名过期。
/// 这里把到期日读出来，设置页显示"还剩 N 天"，快到期时给一条提醒。
enum SigningInfo {

    /// 证书到期时间（读不到就是 nil：比如从 Xcode 直接装、或企业签名）
    static var expiryDate: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return parseExpiry(from: data)
    }

    /// 剩余天数（向下取整）；已过期返回负数
    static var daysLeft: Int? {
        guard let expiry = expiryDate else { return nil }
        return Int(expiry.timeIntervalSinceNow / 86400.0)
    }

    /// 从 mobileprovision（CMS 包裹的 plist）里抠出 ExpirationDate。
    /// 整个文件里 plist 是明文的，只需要找 `<key>ExpirationDate</key><date>…</date>`。
    static func parseExpiry(from data: Data) -> Date? {
        // 用 latin1 扫，避免签名二进制段不是合法 UTF-8 导致整体解码失败
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        guard let keyRange = text.range(of: "<key>ExpirationDate</key>") else { return nil }
        let tail = text[keyRange.upperBound...]
        guard let start = tail.range(of: "<date>"),
              let end = tail.range(of: "</date>"),
              start.upperBound <= end.lowerBound else { return nil }
        let value = String(tail[start.upperBound..<end.lowerBound])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// 设置页那一行要显示的文字
    static var summary: String {
        guard let days = daysLeft else { return "未检测到（非侧载安装或读不到描述文件）" }
        if days < 0 { return "已过期 \(-days) 天 —— 需要重新签名安装" }
        if days == 0 { return "今天到期 —— 请尽快重装" }
        return "还剩 \(days) 天（到期后 App 会打不开，需用 Sideloadly 重新安装）"
    }

    /// 是否该给醒目提示
    static var shouldWarn: Bool {
        guard let days = daysLeft else { return false }
        return days <= 2
    }
}
