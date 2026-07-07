import SwiftUI

@main
struct ReelClipApp: App {
    @StateObject private var subscriptionStore = SubscriptionStore()

    init() {
        ExportNotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(subscriptionStore)
                .onOpenURL { url in
                    // Route `.reelclip` files (Files app, AirDrop, share
                    // sheets) to the project URL router.
                    if url.pathExtension.lowercased() == "reelclip" {
                        ReelClipProjectURLRouter.shared.handle(url: url)
                    }
                }
        }
    }
}