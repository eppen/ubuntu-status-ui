import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showAdd = false
    @State private var editing: ServerProfile?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var phonePath: [ServerProfile.ID] = []

    var body: some View {
        Group {
            if sizeClass == .compact {
                phoneNavigation
            } else {
                padOrMacNavigation
            }
        }
        .sheet(isPresented: $showAdd) {
            AddServerView(mode: .add) { profile, password, keyURL in
                try model.addServer(profile, password: password, keyURL: keyURL)
            }
        }
        .sheet(item: $editing) { server in
            AddServerView(mode: .edit(server)) { profile, password, keyURL in
                try model.updateServer(profile, password: password, keyURL: keyURL)
            }
        }
        .onChange(of: showAdd) { _, open in
            if open { AppBootstrap.focusKeyWindow() }
        }
        .onChange(of: editing) { _, value in
            if value != nil { AppBootstrap.focusKeyWindow() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setSceneActive(phase == .active)
        }
    }

    /// iPad / Mac：侧栏 + 详情
    private var padOrMacNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ServerListView(
                onAdd: { showAdd = true },
                onEdit: { editing = $0 }
            )
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            #endif
        } detail: {
            DashboardView()
        }
    }

    /// iPhone：列表推进详情
    private var phoneNavigation: some View {
        NavigationStack(path: $phonePath) {
            ServerListView(
                onAdd: { showAdd = true },
                onEdit: { editing = $0 },
                usesNavigationLink: true
            )
            .navigationDestination(for: ServerProfile.ID.self) { id in
                DashboardView()
                    .onAppear {
                        if model.selectedServerID != id {
                            model.selectServer(id)
                        }
                    }
            }
        }
        .onChange(of: phonePath) { _, path in
            if let id = path.last, model.selectedServerID != id {
                model.selectServer(id)
            }
        }
    }
}
