import SwiftUI

@main
struct QingYiApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(app)
                .preferredColorScheme(.light)
        }
    }
}
