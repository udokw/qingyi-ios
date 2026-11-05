import SwiftUI

enum GameKind: String {
    case go
    case xiangqi
}

final class AppState: ObservableObject {
    @Published var themeID: ThemeID {
        didSet { UserDefaults.standard.set(themeID.rawValue, forKey: "ui.theme") }
    }
    @Published var kind: GameKind {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "ui.kind") }
    }
    @Published var goSound: Bool {
        didSet { UserDefaults.standard.set(goSound, forKey: "ui.goSound") }
    }
    @Published var xqHints: Bool {
        didSet { UserDefaults.standard.set(xqHints, forKey: "ui.xqHints") }
    }

    var theme: Theme { Theme.of(themeID) }

    init() {
        let defaults = UserDefaults.standard
        let savedTheme = defaults.string(forKey: "ui.theme")
        themeID = ThemeID(rawValue: savedTheme ?? "") ?? .hara
        let savedKind = defaults.string(forKey: "ui.kind")
        kind = GameKind(rawValue: savedKind ?? "") ?? .go
        if defaults.object(forKey: "ui.goSound") == nil {
            goSound = true
        } else {
            goSound = defaults.bool(forKey: "ui.goSound")
        }
        if defaults.object(forKey: "ui.xqHints") == nil {
            xqHints = true
        } else {
            xqHints = defaults.bool(forKey: "ui.xqHints")
        }
    }

    func toggleTheme() {
        themeID = themeID == .hara ? .monument : .hara
    }
}
