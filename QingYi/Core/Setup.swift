import Foundation

enum PlayMode: String {
    case ai
    case local
    case review
}

struct GoSetup: Identifiable, Equatable {
    let id = UUID()
    var mode: PlayMode = .ai
    var playerColor: GoColor = .black
    var level: Int = 10
    var handicap: Int = 0
    var size: Int = GoGame.defaultSize
    var recordURL: URL?
}

struct XiangqiSetup: Identifiable, Equatable {
    let id = UUID()
    var mode: PlayMode = .ai
    var playerColor: XiangqiGame.Color = .red
    var level: Int = 5
    var hints: Bool = true
    var recordURL: URL?
}

/// 五子棋：默认 19 路、黑先、五档 AI、禁手默认关（与 Android 一致）。
struct GomokuSetup: Identifiable, Equatable {
    let id = UUID()
    var mode: PlayMode = .ai
    /// 1 = 黑，2 = 白
    var playerColor: Int = GomokuGame.black
    var level: Int = 3
    var renju: Bool = false
    var hints: Bool = true
}

/// 暗棋：默认 5 段、执先手、红黑随机（与 Android 一致）。
struct BanqiSetup: Identifiable, Equatable {
    let id = UUID()
    var mode: PlayMode = .ai
    var first: Bool = true
    var level: Int = 5
}

struct GoRecord: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let subtitle: String
    let size: Int
}

enum Records {

    static func bundledGoRecords() -> [GoRecord] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "sgf", subdirectory: nil) ?? []
        let records = urls.map { url -> GoRecord in
            let game = (try? Sgf.load(url)) ?? Sgf.Game()
            let base = url.deletingPathExtension().lastPathComponent
            var title = game.event
            if title.isEmpty { title = base }
            var subtitle = ""
            if !game.blackName.isEmpty || !game.whiteName.isEmpty {
                subtitle = "黑 \(game.blackName) · 白 \(game.whiteName)"
            }
            if !game.result.isEmpty { subtitle += subtitle.isEmpty ? game.result : " · \(game.result)" }
            return GoRecord(url: url, title: title, subtitle: subtitle, size: game.size)
        }
        return records.sorted { a, b in
            let aOrder = orderIndex(a.url.lastPathComponent)
            let bOrder = orderIndex(b.url.lastPathComponent)
            if aOrder != bOrder { return aOrder < bOrder }
            return a.url.lastPathComponent < b.url.lastPathComponent
        }
    }

    private static func orderIndex(_ name: String) -> Int {
        switch name {
        case "Game1.sgf": return 0
        case "Game2.sgf": return 1
        case "Game3.sgf": return 2
        default: return 10
        }
    }

    /// 把外部文件复制进应用沙盒(处理安全作用域)
    static func importFile(_ url: URL, ext: String) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = Sgf.documentsDirectory().appendingPathComponent("清弈/导入", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = url.deletingPathExtension().lastPathComponent
        let dest = dir.appendingPathComponent("\(name)-\(stamp).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func displayTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
