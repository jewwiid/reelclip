import SwiftUI

struct RootView: View {
    enum AppTab: Hashable {
        case home, clip, settings
    }

    @StateObject private var viewModel = VideoSplitterViewModel()
    @State private var selectedTab: AppTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(AppTab.home)

            ClipView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Clip", systemImage: "scissors")
                }
                .tag(AppTab.clip)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        .environmentObject(viewModel)
        .tint(AppPalette.accent)
    }
}

#Preview {
    RootView()
}