import Foundation
import Combine

/// 会话列表状态。
///
/// 为什么单独一个 ObservableObject：
/// `AppModel` 是用 `@EnvironmentObject` 注入给几乎每个视图的，而 SwiftUI 的订阅粒度
/// 是**整个对象** —— 只要 AppModel 上任何一个 `@Published` 变化，ChatView 就会重算
/// body，20 条气泡连带重新测量。会话列表在每条消息结束都会刷新（服务端偶尔还要
/// 800ms），于是聊天页跟着白重算一次，真机实测一次 700ms 级卡顿。
///
/// 把列表搬到独立对象后，列表怎么变都碰不到聊天树。
@MainActor
final class SessionListStore: ObservableObject {
    @Published var rows: [SessionRow] = []
    @Published var archived: [SessionRow] = []
}
