import Foundation

/// 象棋 PGN / ICCS 棋谱读取
/// 支持 [FEN] 起始局面、a0a9 与 a1a10 两种坐标、花括号与行注释
enum XiangqiPgn {

    struct Game {
        var event = ""
        var redName = ""
        var blackName = ""
        var result = ""
        var date = ""
        var fen = ""
        var moves: [String] = []
    }

    static func load(_ url: URL) throws -> Game {
        let data = try Data(contentsOf: url)
        return parse(Sgf.decode(data))
    }

    static func parse(_ text: String) -> Game {
        var game = Game()
        let cleaned = stripComments(text)
        let lines = cleaned.split(separator: "\n").map(String.init)

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                if let close = t.firstIndex(of: "]") {
                    let body = t.dropFirst().prefix(upTo: close)
                    let parts = body.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count >= 2 else { continue }
                    let key = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    var value = String(parts[1])
                    if let end = value.lastIndex(of: "\"") { value = String(value[..<end]) }
                    switch key.uppercased() {
                    case "FEN": game.fen = value
                    case "EVENT": game.event = value
                    case "RED": game.redName = value
                    case "BLACK": game.blackName = value
                    case "RESULT": game.result = value
                    case "DATE": game.date = value
                    default: break
                    }
                }
            } else if t.hasPrefix("1.") || hasMoveToken(t) {
                game.moves.append(contentsOf: moveTokens(t))
            }
        }
        if game.moves.isEmpty {
            game.moves = moveTokens(cleaned)
        }
        return game
    }

    /// "1. 炮二平五 马8进7 2. ..." / "1. h2e2 h9g7"
    private static func moveTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter, let ascii = c.asciiValue, ascii >= 97, ascii <= 105 {
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                guard !digits.isEmpty else { i += 1; continue }
                var k = j
                if k < chars.count, chars[k] == "-" { k += 1 }
                guard k < chars.count, let f2 = chars[k].asciiValue, f2 >= 97, f2 <= 105 else { i += 1; continue }
                var m = k + 1
                var digits2 = ""
                while m < chars.count, chars[m].isNumber { digits2.append(chars[m]); m += 1 }
                guard !digits2.isEmpty else { i += 1; continue }
                tokens.append("\(c)\(digits)\(chars[k])\(digits2)")
                i = m
            } else {
                i += 1
            }
        }
        return tokens
    }

    private static func hasMoveToken(_ text: String) -> Bool {
        !moveTokens(text).isEmpty
    }

    private static func stripComments(_ text: String) -> String {
        var out = ""
        var inBrace = false
        var inLine = false
        for ch in text {
            if inLine {
                if ch == "\n" { inLine = false; out.append(ch) }
                continue
            }
            if inBrace {
                if ch == "}" { inBrace = false }
                continue
            }
            if ch == "{" { inBrace = true; continue }
            if ch == ";" { inLine = true; continue }
            out.append(ch)
        }
        return out
    }

    /// 依次把着法落到棋局, 返回成功着数
    @discardableResult
    static func apply(_ game: Game, to board: XiangqiGame) -> Int {
        if !game.fen.isEmpty, !board.loadFen(game.fen) { return 0 }
        var count = 0
        for uci in game.moves {
            if board.playUci(uci) {
                count += 1
            } else {
                break
            }
        }
        return count
    }
}
