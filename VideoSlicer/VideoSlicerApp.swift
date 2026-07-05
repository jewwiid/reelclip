import SwiftUI

@main
struct ReelClipApp: App {
    init() {
        ExportNotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    TikTokOpenSDKURLRouter.handle(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    TikTokOpenSDKURLRouter.handle(userActivity.webpageURL)
                }
        }
    }
}
