import SwiftUI

@main
struct QingYiApp: App {
    @StateObject private var app = AppState()

    init() {
        // 上次建房若没走到 ready（卡死/被强杀），这里把它记下来给联机大厅提示
        LanStage.bootstrapOnce()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(app)
                .preferredColorScheme(.light)
        }
    }
}
