import SwiftUI
import UIKit

/// 默认竖屏；只有暗棋页临时切到横屏。
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

@main
struct QingYiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
