import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    enum AppTab: Hashable {
        case home, clip, settings
    }

    @StateObject private var viewModel = VideoSplitterViewModel()
    @State private var selectedTab: AppTab = .home
    @State private var shouldPresentSourceChooser = false
    @AppStorage("onboarding.completed") private var hasCompletedOnboarding = false

    var body: some View {
        TabView(selection: $selectedTab) {
            AnyView(
                HomeView(
                    selectedTab: $selectedTab,
                    shouldPresentSourceChooser: $shouldPresentSourceChooser
                )
            )
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(AppTab.home)

            AnyView(ClipView(selectedTab: $selectedTab))
                .tabItem {
                    Label("Clip", systemImage: "scissors")
                }
                .tag(AppTab.clip)

            AnyView(SettingsView())
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        .environmentObject(viewModel)
        .tint(AppPalette.accent)
        // Most editing mutations persist immediately, but iOS may suspend the
        // process before a user leaves the editor through another route. Flush
        // the current scene snapshot on both lifecycle transitions so imports,
        // scenes, plans, orders, and recipe fields survive returning later.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive, .background:
                viewModel.persistCurrentProject()
            case .active:
                break
            @unknown default:
                viewModel.persistCurrentProject()
            }
        }
        .overlay {
            if !hasCompletedOnboarding {
                ReelClipOnboardingView { shouldStartProject in
                    selectedTab = .home
                    hasCompletedOnboarding = true

                    if shouldStartProject {
                        // Home remains mounted behind onboarding, so this
                        // change reliably opens its app-owned source chooser
                        // after the overlay has been dismissed.
                        DispatchQueue.main.async {
                            shouldPresentSourceChooser = true
                        }
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.2), value: hasCompletedOnboarding)
    }
}

#Preview {
    RootView()
}
