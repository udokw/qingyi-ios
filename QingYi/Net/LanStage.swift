import Foundation

/// 建房流程的阶段标记。
///
/// 目的：真机卡死时用户没法点开诊断区，只能强杀。
/// 所以把 `host.begin` → `host.ready` 的每一步记下来（UserDefaults 立即写、
/// 文件追加 + `fsync` 在后台 IO 队列），下次启动时如果发现上次没走到 `host.ready`，
/// 就在联机大厅顶部显示「上次停在 XXX」。
///
/// 主线程上只有一次 `UserDefaults.set`（内存操作），不做任何文件 IO。
enum LanStage {
    private static let lock = NSLock()
    private static let stageKey = "lan.host.stage"
    private static let runningKey = "lan.host.running"
    private static let buildKey = "lan.host.build"
    private static let defaults = UserDefaults.standard

    /// 落盘专用串行队列：`append` 里的文件写入 + `fsync` 全部在这里，
    /// 主线程只做 `UserDefaults.set`（纯内存），绝不碰文件描述符。
    private static let ioQueue = DispatchQueue(label: "qingyi.lan.stage")
    /// 只允许在 ioQueue 上使用（DateFormatter 不是线程安全的）
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let fileURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("host-stage.log")

    /// 上一次启动遗留的未完成阶段；nil 表示上次正常走到 ready。
    private(set) static var previousUnfinished: String?
    /// 上次没走完时是哪个构建，便于确认是不是刚更新的这版
    private(set) static var previousBuildTag: String?
    private static var didBootstrap = false

    /// 构建标识，例如 `1.1.6(16)`
    static var buildTag: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)(\(build))"
    }

    /// App 启动时调用一次：把上次崩溃/卡死遗留的阶段记下来，再重新开始。
    static func bootstrapOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true
        if defaults.bool(forKey: runningKey) {
            previousUnfinished = defaults.string(forKey: stageKey) ?? "未知阶段"
            previousBuildTag = defaults.string(forKey: buildKey)
        }
        defaults.set(false, forKey: runningKey)
    }

    /// 记录一个阶段。UserDefaults 同步写（内存，被强杀也不丢），
    /// 文件追加与 `fsync` 交给 IO 队列，调用方（包括主线程）立即返回。
    static func mark(_ stage: String, _ detail: String = "") {
        let at = Date()
        let tag = buildTag
        lock.lock()
        defaults.set(stage, forKey: stageKey)
        defaults.set(true, forKey: runningKey)
        defaults.set(tag, forKey: buildKey)
        lock.unlock()
        ioQueue.async { append("\(stamp(at))  \(tag)  \(stage)  \(detail)") }
    }

    /// 走到可交互状态（或失败退出）时收尾，下次启动就不会误报「上次停在」。
    static func finish(_ stage: String = "host.ready", _ detail: String = "") {
        let at = Date()
        let tag = buildTag
        lock.lock()
        defaults.set(stage, forKey: stageKey)
        defaults.set(false, forKey: runningKey)
        lock.unlock()
        ioQueue.async { append("\(stamp(at))  \(tag)  \(stage)  \(detail)") }
    }

    static func resetBanner() {
        lock.lock()
        defer { lock.unlock() }
        previousUnfinished = nil
    }

    // MARK: - 落盘

    private static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// 只在 ioQueue 上调用。
    private static func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        if let end = try? handle.seekToEnd() {
            // 文件超过 16KB 就只保留这一条，避免无限增长
            if end > 16_384 {
                try? data.write(to: fileURL, options: .atomic)
                if let h = try? FileHandle(forWritingTo: fileURL) {
                    fsync(h.fileDescriptor)
                    try? h.close()
                }
                return
            }
        }
        try? handle.write(contentsOf: data)
        fsync(handle.fileDescriptor)
    }
}
