import Foundation

/// SGF(FF[4]) 读写: 支持根属性 / 主变落子 / 摆子 / 注释
/// 变着只读取主变(第一个分支), 保证导入棋谱按原谱顺序推进
enum Sgf {

    struct Node {
        var point: GoPoint?      // nil 表示 PASS 或无着子
        var color: GoColor = .empty
        var comment: String?
    }

    struct Game {
        var event = ""
        var blackName = ""
        var whiteName = ""
        var blackRank = ""
        var whiteRank = ""
        var result = ""
        var date = ""
        var size = 19
        var handicap = 0
        var komi = 7.5
        var playerToMove: GoColor = .empty
        var setupBlack: [GoPoint] = []
        var setupWhite: [GoPoint] = []
        var setupEmpty: [GoPoint] = []
        var nodes: [Node] = []
    }

    // MARK: - 保存

    static func save(_ game: GoGame, blackName: String, whiteName: String, result: String?) -> String {
        var out = "(;GM[1]FF[4]CA[UTF-8]SZ[\(game.size)]AP[清弈iOS:1.0]"
        out += "PB[\(esc(blackName))]PW[\(esc(whiteName))]"
        out += "KM[\(game.komi)]"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        out += "DT[\(formatter.string(from: Date()))]"
        if let result { out += "RE[\(esc(result))]" }
        out += "\n"
        for m in game.history where m.color != .empty {
            out += ";\(m.color == .black ? "B" : "W")["
            if let p = m.point { out += GoGame.toSgf(p.x, p.y) }
            out += "]\n"
        }
        out += ")\n"
        return out
    }

    /// 存到 Documents/清弈, 返回文件 URL
    @discardableResult
    static func saveToDocuments(_ game: GoGame, blackName: String, whiteName: String, result: String?) throws -> URL {
        let dir = documentsDirectory().appendingPathComponent("清弈", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).sgf")
        try save(game, blackName: blackName, whiteName: whiteName, result: result)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
    }

    // MARK: - 加载

    static func load(_ url: URL) throws -> Game {
        let data = try Data(contentsOf: url)
        return parse(decode(data))
    }

    static func load(data: Data) -> Game {
        parse(decode(data))
    }

    /// 编码识别: UTF-8 优先(BOM 剥掉), 失败退 GB18030(GBK 超集)
    static func decode(_ data: Data) -> String {
        if data.count >= 3, data[data.startIndex] == 0xEF,
           data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // 0x80000632 = GB18030 的 NSStringEncoding(与 CFString GB_18030_2000 对应)
        if let s = String(data: data, encoding: String.Encoding(rawValue: 0x80000632)) { return s }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parse(_ text: String) -> Game {
        var game = Game()
        let chars = Array(text)
        var i = 0
        let n = chars.count
        while i < n && chars[i] != "(" { i += 1 }
        guard i < n else { return game }

        var depth = 0
        while i < n {
            let c = chars[i]
            if c == "(" {
                depth += 1
                i += 1
            } else if c == ")" {
                depth -= 1
                i += 1
                if depth == 0 { break }
            } else if c == ";" {
                i += 1
                var node = Node()
                while i < n {
                    while i < n && chars[i].isWhitespace { i += 1 }
                    guard i < n, chars[i].isUppercase else { break }
                    var prop = ""
                    while i < n && chars[i].isUppercase {
                        prop.append(chars[i])
                        i += 1
                    }
                    while i < n && chars[i] == "[" {
                        i += 1
                        var value = ""
                        while i < n {
                            let vc = chars[i]
                            if vc == "\\", i + 1 < n {
                                value.append(chars[i + 1])
                                i += 2
                                continue
                            }
                            if vc == "]" {
                                i += 1
                                break
                            }
                            value.append(vc)
                            i += 1
                        }
                        if depth == 1 {
                            _ = applyProp(&game, &node, prop, value)
                        }
                    }
                }
                if depth == 1, node.color != .empty || node.comment != nil {
                    game.nodes.append(node)
                }
            } else {
                i += 1
            }
        }
        return game
    }

    @discardableResult
    private static func applyProp(_ game: inout Game, _ node: inout Node, _ prop: String, _ v: String) -> Bool {
        switch prop {
        case "B", "W":
            node.color = prop == "B" ? .black : .white
            if let p = GoGame.fromSgf(v), p.x >= 0, p.x < game.size, p.y >= 0, p.y < game.size {
                node.point = p
            } else {
                node.point = nil
            }
            return true
        case "C", "GC":
            node.comment = v
            return true
        case "AB":
            let size = game.size
            addPoint(&game.setupBlack, v, size: size)
            return true
        case "AW":
            let size = game.size
            addPoint(&game.setupWhite, v, size: size)
            return true
        case "AE":
            let size = game.size
            addPoint(&game.setupEmpty, v, size: size)
            return true
        case "PB": game.blackName = v; return true
        case "PW": game.whiteName = v; return true
        case "BR": game.blackRank = v; return true
        case "WR": game.whiteRank = v; return true
        case "RE": game.result = v; return true
        case "EV": game.event = v; return true
        case "DT": game.date = v; return true
        case "KM":
            if let d = Double(v.trimmingCharacters(in: .whitespaces)) { game.komi = d }
            return true
        case "SZ":
            if let sz = Int(v.trimmingCharacters(in: .whitespaces)), sz >= 2, sz <= 25 { game.size = sz }
            return true
        case "HA":
            if let h = Int(v.trimmingCharacters(in: .whitespaces)) { game.handicap = h }
            return true
        case "PL":
            let t = v.trimmingCharacters(in: .whitespaces).uppercased()
            if t == "B" { game.playerToMove = .black }
            else if t == "W" { game.playerToMove = .white }
            return true
        default:
            return false
        }
    }

    private static func addPoint(_ list: inout [GoPoint], _ v: String, size: Int) {
        guard let p = GoGame.fromSgf(v), p.x >= 0, p.x < size, p.y >= 0, p.y < size else { return }
        list.append(p)
    }
}
