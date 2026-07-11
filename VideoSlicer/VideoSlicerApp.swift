import SwiftUI

@main
struct ReelClipApp: App {
    @StateObject private var subscriptionStore = SubscriptionStore()
    @State private var isShowingLaunchOverlay = true

    init() {
        ExportNotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(subscriptionStore)
                    .onOpenURL { url in
                        // Route `.reelclip` files (Files app, AirDrop, share
                        // sheets) to the project URL router.
                        if url.pathExtension.lowercased() == "reelclip" {
                            ReelClipProjectURLRouter.shared.handle(url: url)
                        }
                    }

                if isShowingLaunchOverlay {
                    ReelClipLaunchOverlay {
                        isShowingLaunchOverlay = false
                    }
                }
            }
        }
    }
}

private struct ReelClipLaunchOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinished: () -> Void

    @State private var markScale: CGFloat = 1
    @State private var overlayOpacity = 1.0

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.058, blue: 0.066)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 168, height: 168)
                    .scaleEffect(markScale)

                Text("Really clip with ReelClips")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.77, green: 0.94, blue: 0.20))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: 28)
            }
            .offset(y: -8)
        }
        .opacity(overlayOpacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.32)) {
                    markScale = 1.06
                }
                try? await Task.sleep(nanoseconds: 320_000_000)

                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                    markScale = 1
                }
                try? await Task.sleep(nanoseconds: 480_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            withAnimation(.easeOut(duration: 0.25)) {
                overlayOpacity = 0
            }
            try? await Task.sleep(nanoseconds: 260_000_000)
            onFinished()
        }
    }
}
