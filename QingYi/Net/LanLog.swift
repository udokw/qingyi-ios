import Foundation

/// 联机时间线日志。
///
/// 目的：把「建房 → 被发现 → 握手」全过程按时间顺序记下来，
/// 用户在没有 Mac 的情况下也能一次性取走（页面复制 / 文件 App 里的 Documents/lan.log）。
///
/// 特点：
/// - 默认开启，Release 构建也记；只记联机相关事件，开销可控；
/// - 内存里保留最近 500 条（环形缓冲），文件同步追加，超过阈值自动重写成最近 500 条；
/// - 每行格式：`HH:mm:ss.SSS  [ok|fail|·]  类型  详情`。
final class LanLog: ObservableObject {
    struct Entry: Identifiable {
        let id: Int
        let line: String
    }

    static let shared = LanLog()

    /// 供页面直接渲染（只读快照，主线程更新）
    @Published private(set) var entries: [Entry] = []

    private let capacity = 500
    private let queue = DispatchQueue(label: "qingyi.lan.log")
    private var storage: [String] = []
    private var seq = 0
    private var writtenSinceTrim = 0
    private let formatter: DateFormatter
    let fileURL: URL

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("lan.log")
        // 启动时把旧日志带回来，避免重开 App 后页面空白
        if let old = try? String(contentsOf: fileURL, encoding: .utf8) {
            storage = old.split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(capacity)
                .map(String.init)
        }
        publish()
    }

    /// ok 传 nil 表示中性事件（既不是成功也不是失败）。
    func add(_ kind: String, ok: Bool? = nil, _ detail: String = "") {
        let stamp = formatter.string(from: Date())
        let flag = ok == nil ? "  · " : (ok! ? " ok " : "fail")
        let line = detail.isEmpty
            ? "\(stamp)  [\(flag)]  \(kind)"
            : "\(stamp)  [\(flag)]  \(kind)  \(detail)"
        queue.async { [weak self] in
            guard let self else { return }
            self.storage.append(line)
            if self.storage.count > self.capacity {
                self.storage.removeFirst(self.storage.count - self.capacity)
            }
            self.appendLineToFile(line)
            self.publish()
        }
    }

    /// 全部日志（按时间正序），用于「复制全部」
    func fullText() -> String {
        queue.sync { storage.joined(separator: "\n") }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.storage.removeAll()
            try? FileManager.default.removeItem(at: self.fileURL)
            self.writtenSinceTrim = 0
            self.publish()
        }
    }

    // MARK: - 落盘

    private func appendLineToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
        writtenSinceTrim += 1
        // 每 100 条重写一次，用内存里的环形缓冲裁掉旧内容，文件不会无限增长
        if writtenSinceTrim >= 100 {
            writtenSinceTrim = 0
            let text = storage.joined(separator: "\n") + "\n"
            try? text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 发布到界面

    private func publish() {
        let snapshot = storage.enumerated().map { Entry(id: $0.offset, line: $0.element) }
        DispatchQueue.main.async { [weak self] in
            self?.entries = snapshot
        }
    }
}
