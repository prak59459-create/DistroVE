import SwiftUI

@main
struct DistroVEApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
                .dynamicTypeSize(settings.textSize.range)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ContentUpdater.applyPending()
        Diagnostics.shared.start()
        Task.detached(priority: .background) {
            CacheManager.autoClean()
        }
        return true
    }
}
