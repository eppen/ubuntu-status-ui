import SwiftUI

struct ServerListView: View {
    @EnvironmentObject private var model: AppModel
    var onAdd: () -> Void
    var onEdit: (ServerProfile) -> Void
    /// iPhone：用 NavigationLink 进入详情；iPad/Mac：用列表 selection
    var usesNavigationLink: Bool = false

    var body: some View {
        List(selection: usesNavigationLink ? nil : Binding(
            get: { model.selectedServerID },
            set: { model.selectServer($0) }
        )) {
            Section("服务器") {
                ForEach(model.servers) { server in
                    if usesNavigationLink {
                        NavigationLink(value: server.id) {
                            serverLabel(server)
                        }
                        .contextMenu { contextMenu(for: server) }
                    } else {
                        serverLabel(server)
                            .tag(server.id as ServerProfile.ID?)
                            .contextMenu { contextMenu(for: server) }
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        model.deleteServer(model.servers[i].id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ServerStatus")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private func serverLabel(_ server: ServerProfile) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(badgeColor(for: model.connectionState(for: server.id)))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayTitle)
                    .font(.headline)
                Text(badgeSubtitle(server))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func badgeColor(for state: ConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .idle: return .secondary.opacity(0.45)
        }
    }

    private func badgeSubtitle(_ server: ServerProfile) -> String {
        let state = model.connectionState(for: server.id)
        switch state {
        case .connected: return "已连接 · \(server.subtitle)"
        case .connecting: return "连接中… · \(server.subtitle)"
        case .failed: return "失败 · \(server.subtitle)"
        case .idle: return server.subtitle
        }
    }

    @ViewBuilder
    private func contextMenu(for server: ServerProfile) -> some View {
        Button("编辑") { onEdit(server) }
        Button("删除", role: .destructive) {
            model.deleteServer(server.id)
        }
    }
}
