import Foundation

/// 联机发现链路的实时诊断快照。
///
/// 只有一个目的：iOS 建房、安卓搜不到时，能把「断在哪一层」直接显示在房主页上，
/// 而不是靠日志推测。它不参与任何协议，只读状态与计数器。
///
/// 读法：
/// - `收到 room_query` 一直是 0 → 安卓的广播根本没到 iOS（路由器/AP 隔离，或是不在同一网段）；
/// - 查询在涨、`回出 room_reply` 也在涨，但安卓仍搜不到 → 应答发出去了，安卓侧过滤了；
/// - 两个计数都在涨，且 mDNS 是 published → 发现侧已经是通的，问题只可能在安卓端解析。
final class LanDiagnostics: ObservableObject {
    struct Snapshot {
        var hostIP = ""
        var tcpPort: UInt16 = 0
        var listenerState = "未启动"
        /// 每个 Bonjour 服务类型 → publishing / published / failed
        var mdns: [String: String] = [:]
        var txt = "—"
        var udpStatus = "未启动"
        var udpListen = "—"
        var udpOptions = "—"
        var recvQueries = 0
        var sentReplies = 0
        var sentAnnounces = 0
        var lastFrom = "—"
        var lastEvent = "—"
        /// 跨端字段自检结果（每行一条中文结论）
        var selfCheck = "未运行"
        var fieldTable = LanUdpTypes.fieldTable
        /// 广播目标由通告循环在后台线程算好后回填，
        /// 这里绝不能在 init/reset 时调 getifaddrs（那会落在主线程上）。
        var broadcast = "—"
    }

    static let shared = LanDiagnostics()

    @Published private(set) var snapshot = Snapshot()

    private init() {}

    /// 后台队列（LanHost / LanQueryResponder）里调用，统一切到主线程改值。
    /// 主线程串行执行，因此计数器顺序不会乱。
    func update(_ change: @escaping (inout Snapshot) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.snapshot
            change(&next)
            self.snapshot = next
        }
    }

    func setMDNS(type: String, state: String) {
        update { $0.mdns[type] = state }
    }

    func reset() {
        update { $0 = Snapshot() }
    }
}
