import SwiftUI

struct RootView: View {
    enum AppTab: Hashable {
        case home, clip, settings
    }

    @StateObject private var viewModel = VideoSplitterViewModel()
    @State private var selectedTab: AppTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            AnyView(HomeView(selectedTab: $selectedTab))
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
    }
}

#Preview {
    RootView()
}
