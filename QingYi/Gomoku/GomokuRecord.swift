import Foundation

/// 移植自 Android `com.sijia.go.GomokuRecord`
/// 源文件：app/src/main/java/com/sijia/go/GomokuRecord.java（只读参考，未做任何修改）
///
/// 方法一一对应：
///   toSgf(_:blackName:whiteName:result:) ← toSgf
///   saveToFile(...directory:)            ← saveToFile(..., File dir)
///   load(file:) / parse(_:)              ← load(File) / 内部 SGF 文本解析
///   list(in:)                            ← list(File dir)
///   coord / esc / prop / readAll         ← 同名私有工具
///
/// 格式与 Android 完全一致：SGF FF[4] 子集、GM[4]（Gomoku / Renju）、.gmk、UTF-8。
/// 坐标编码：首字母 a..s = 列（左→右），次字母 a..s = 行（上→下），(9,9) → "jj"。
/// 根属性顺序：GM FF CA AP SZ RU DT PB PW [RE]；每手一行 ";B[xy]" / ";W[xy]"。
final class GomokuRecord {
    static let recordExtension = ".gmk"
    /// 固定头：GM[4] 表示五子棋 / 连珠。
    static let header = "GM[4]"
    /// AP 应用标识。属性名与顺序和 Android 相同；若需与安卓逐字节一致，改成 "QingYi-Android:1.2.2"。
    static let applicationTag = "QingYi-iOS:1.0"

    struct Data {
        var size = GomokuGame.boardSize
        var renju = false
        var date = ""
        var result = ""
        /// {color, x, y}，按落子顺序。
        var moves: [GomokuGame.Move] = []
    }

    private init() {}

    // ---------------- 保存 ----------------

    static func toSgf(_ game: GomokuGame, blackName: String, whiteName: String,
                      result: String?) -> String {
        var s = "(;\(header)FF[4]CA[UTF-8]AP[\(applicationTag)]SZ[\(game.size)]"
        s += "RU[\(game.isRenju ? "renju" : "freestyle")]"
        s += "DT[\(dateStamp())]"
        s += "PB[\(esc(blackName))]"
        s += "PW[\(esc(whiteName))]"
        if let result = result, !result.isEmpty {
            s += "RE[\(esc(result))]"
        }
        s += "\n"
        for m in game.history {
            s += ";" + (m.color == GomokuGame.black ? "B" : "W")
            s += "[" + coord(m.x, m.y) + "]\n"
        }
        s += ")\n"
        return s
    }

    @discardableResult
    static func saveToFile(_ game: GomokuGame, blackName: String, whiteName: String,
                           result: String?, directory: URL) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let name = "QYG_" + timestamp() + recordExtension
        let url = directory.appendingPathComponent(name)
        try toSgf(game, blackName: blackName, whiteName: whiteName, result: result)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // ---------------- 读取 ----------------

    static func load(file url: URL) throws -> Data {
        parse(try readAll(url))
    }

    /// 解析 SGF 文本（与 Java 的逐字符扫描规则一致）。
    static func parse(_ text: String) -> Data {
        let chars = Array(text)
        let n = chars.count
        var d = Data()

        var size = 19
        let sz = prop(chars, "SZ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sz.isEmpty, let v = Int(sz) {
            size = v
        }
        d.size = max(5, min(25, size))
        d.renju = prop(chars, "RU").lowercased().contains("renju")
        d.date = prop(chars, "DT")
        d.result = prop(chars, "RE")

        var i = 0
        while i < n {
            if chars[i] != ";" || i + 2 >= n {
                i += 1
                continue
            }
            let col = String(chars[i + 1]).uppercased()
            if (col != "B" && col != "W") || chars[i + 2] != "[" {
                i += 1
                continue
            }
            var end = i + 3
            while end < n && chars[end] != "]" { end += 1 }
            if end >= n { break }
            let value = Array(chars[(i + 3)..<end])
            i = end
            if value.count >= 2 && value[0] != "]" {
                let x = Int(value[0].asciiValue ?? 0) - 97
                let y = Int(value[1].asciiValue ?? 0) - 97
                if x >= 0 && y >= 0 && x < d.size && y < d.size {
                    d.moves.append(GomokuGame.Move(color: col == "B" ? GomokuGame.black : GomokuGame.white,
                                                   x: x, y: y))
                }
            }
            i += 1
        }
        return d
    }

    /// 目录下所有 .gmk，按文件名倒序（新存的前面）。
    static func list(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: []) else {
            return []
        }
        let files = all.filter { url -> Bool in
            guard url.lastPathComponent.lowercased().hasSuffix(recordExtension) else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        return files.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // ---------------- 工具 ----------------

    private static func coord(_ x: Int, _ y: Int) -> String {
        String(Character(UnicodeScalar(UInt8(97 + x))))
            + String(Character(UnicodeScalar(UInt8(97 + y))))
    }

    private static func esc(_ s: String?) -> String {
        guard let s = s else { return "" }
        return s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// 读取 SGF 根属性（取第一次出现），\\ 转义与 Java 相同。
    private static func prop(_ text: [Character], _ key: String) -> String {
        let needle = Array(key + "[")
        var from = 0
        while true {
            guard let i = indexOf(text, needle, from: from) else { return "" }
            let boundary = i == 0 || !isLetterOrDigit(text[i - 1])
            if !boundary {
                from = i + key.count
                continue
            }
            var out = ""
            var j = i + needle.count
            while j < text.count {
                let c = text[j]
                if c == "\\" && j + 1 < text.count {
                    out.append(text[j + 1])
                    j += 2
                    continue
                }
                if c == "]" { break }
                out.append(c)
                j += 1
            }
            return out
        }
    }

    private static func indexOf(_ text: [Character], _ needle: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, text.count >= needle.count else { return nil }
        let last = text.count - needle.count
        var i = max(0, from)
        while i <= last {
            var hit = true
            var k = 0
            while k < needle.count {
                if text[i + k] != needle[k] {
                    hit = false
                    break
                }
                k += 1
            }
            if hit { return i }
            i += 1
        }
        return nil
    }

    private static func isLetterOrDigit(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func readAll(_ url: URL) throws -> String {
        var raw = try Foundation.Data(contentsOf: url)
        if raw.count >= 3
            && raw[raw.startIndex] == 0xEF
            && raw[raw.startIndex + 1] == 0xBB
            && raw[raw.startIndex + 2] == 0xBF {
            raw = raw.subdata(in: 3..<raw.count)
        }
        guard let text = String(data: raw, encoding: .utf8) else {
            throw NSError(domain: "GomokuRecord", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "棋谱不是有效的 UTF-8 文本"])
        }
        return text
    }
}
