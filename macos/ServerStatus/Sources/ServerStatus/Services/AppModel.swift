import Foundation
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var servers: [ServerProfile] = []
    @Published var selectedServerID: ServerProfile.ID?

    /// Mirrored from the currently selected server slot (for dashboard binding).
    @Published var connectionState: ConnectionState = .idle
    @Published var metrics: MetricsSnapshot = .empty
    @Published var isPolling = false
    @Published var lastError: String?

    /// Sidebar badges: per-server connection state.
    @Published private(set) var connectionBadges: [ServerProfile.ID: ConnectionState] = [:]

    private let store = ServerStore()
    private var slots: [ServerProfile.ID: ServerSlot] = [:]
    private var sceneActive = true

    var selectedServer: ServerProfile? {
        servers.first { $0.id == selectedServerID }
    }

    init() {
        servers = store.load()
        selectedServerID = servers.first?.id
        if let id = selectedServerID {
            _ = slot(for: id)
            publishSelected()
        }
    }

    func saveServers() {
        store.save(servers)
    }

    func connectionState(for id: ServerProfile.ID) -> ConnectionState {
        connectionBadges[id] ?? slots[id]?.connectionState ?? .idle
    }

    func addServer(_ profile: ServerProfile, password: String?, keyURL: URL?) throws {
        var p = profile
        if p.authMethod == .password {
            let account = p.id.uuidString
            try KeychainStore.savePassword(password ?? "", account: account)
            p.credentialRef = account
        } else if let keyURL {
            p.credentialRef = try PrivateKeyStore.importKey(from: keyURL, serverID: p.id)
        }
        servers.append(p)
        selectServer(p.id)
        saveServers()
    }

    func updateServer(_ profile: ServerProfile, password: String?, keyURL: URL?) throws {
        guard let idx = servers.firstIndex(where: { $0.id == profile.id }) else { return }
        var p = profile
        if p.authMethod == .password {
            let account = p.id.uuidString
            if let password, !password.isEmpty {
                try KeychainStore.savePassword(password, account: account)
            }
            p.credentialRef = account
            PrivateKeyStore.removeKey(serverID: p.id)
        } else if let keyURL {
            p.credentialRef = try PrivateKeyStore.importKey(from: keyURL, serverID: p.id)
        } else if p.credentialRef.isEmpty {
            p.credentialRef = servers[idx].credentialRef
        }
        servers[idx] = p
        saveServers()
    }

    func deleteServer(_ id: ServerProfile.ID) {
        Task { await tearDown(id) }
        if let server = servers.first(where: { $0.id == id }) {
            if server.authMethod == .password {
                KeychainStore.deletePassword(account: server.credentialRef)
            } else {
                PrivateKeyStore.removeKey(serverID: id)
            }
        }
        servers.removeAll { $0.id == id }
        connectionBadges[id] = nil
        if selectedServerID == id {
            selectedServerID = servers.first?.id
            publishSelected()
        }
        saveServers()
    }

    /// Switch sidebar selection without dropping other servers' SSH sessions.
    func selectServer(_ id: ServerProfile.ID?) {
        guard id != selectedServerID else { return }
        selectedServerID = id
        if let id {
            _ = slot(for: id)
        }
        publishSelected()
    }

    func connectSelected() async {
        guard let id = selectedServerID, let server = selectedServer else { return }
        let s = slot(for: id)
        s.connectionState = .connecting
        s.lastError = nil
        s.rateState = nil
        s.metrics = .empty
        bumpBadge(id)
        publishSelected()

        do {
            var password: String?
            var keyPath: String?
            switch server.authMethod {
            case .password:
                password = try KeychainStore.loadPassword(account: server.credentialRef)
            case .privateKey:
                keyPath = server.credentialRef
            }
            try await s.session.connect(profile: server, password: password, privateKeyPath: keyPath)
            s.connectionState = .connected
            bumpBadge(id)
            publishSelected()
            startPolling(id)
        } catch {
            s.connectionState = .failed(error.localizedDescription)
            s.lastError = error.localizedDescription
            bumpBadge(id)
            publishSelected()
        }
    }

    func disconnect() async {
        guard let id = selectedServerID else { return }
        await disconnect(id)
    }

    func disconnect(_ id: ServerProfile.ID) async {
        stopPolling(id)
        if let s = slots[id] {
            await s.session.close()
            s.connectionState = .idle
            s.lastError = nil
            // Keep last metrics snapshot for quick glance when switching back
        }
        bumpBadge(id)
        if selectedServerID == id {
            publishSelected()
        }
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if active {
            for (id, s) in slots {
                if case .connected = s.connectionState, s.pollTask == nil {
                    startPolling(id)
                }
            }
        } else {
            for id in slots.keys {
                stopPolling(id)
            }
        }
    }

    // MARK: - Slots

    private func slot(for id: ServerProfile.ID) -> ServerSlot {
        if let existing = slots[id] { return existing }
        let created = ServerSlot(id: id)
        slots[id] = created
        connectionBadges[id] = created.connectionState
        return created
    }

    private func tearDown(_ id: ServerProfile.ID) async {
        stopPolling(id)
        if let s = slots.removeValue(forKey: id) {
            await s.session.close()
        }
        connectionBadges[id] = nil
    }

    private func bumpBadge(_ id: ServerProfile.ID) {
        connectionBadges[id] = slots[id]?.connectionState ?? .idle
    }

    private func publishSelected() {
        guard let id = selectedServerID, let s = slots[id] else {
            connectionState = .idle
            metrics = .empty
            isPolling = false
            lastError = nil
            return
        }
        connectionState = s.connectionState
        metrics = s.metrics
        isPolling = s.pollTask != nil
        lastError = s.lastError
    }

    private func startPolling(_ id: ServerProfile.ID) {
        stopPolling(id)
        guard let s = slots[id] else { return }
        s.pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollOnce(id)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                await self.pollOnce(id)
            }
        }
        if selectedServerID == id {
            isPolling = true
        }
    }

    private func stopPolling(_ id: ServerProfile.ID) {
        slots[id]?.pollTask?.cancel()
        slots[id]?.pollTask = nil
        if selectedServerID == id {
            isPolling = false
        }
    }

    private func pollOnce(_ id: ServerProfile.ID) async {
        guard sceneActive, let s = slots[id] else { return }
        do {
            let session = s.session
            let previous = s.rateState
            let raw = try await withTimeout(seconds: 20) {
                try await session.fetchRawMetrics()
            }
            let (snap, state) = MetricsMath.buildSnapshot(raw: raw, previous: previous)
            s.rateState = state
            s.metrics = snap
            if case .failed = s.connectionState {
                s.connectionState = .connected
            }
            s.lastError = nil
            bumpBadge(id)
            if selectedServerID == id {
                publishSelected()
            } else {
                objectWillChange.send()
            }
        } catch is CancellationError {
            return
        } catch {
            s.lastError = error.localizedDescription
            s.connectionState = .failed(error.localizedDescription)
            stopPolling(id)
            await s.session.close()
            bumpBadge(id)
            if selectedServerID == id {
                publishSelected()
            } else {
                objectWillChange.send()
            }
        }
    }
}

@MainActor
final class ServerSlot {
    let id: ServerProfile.ID
    let session = SSHSession()
    var connectionState: ConnectionState = .idle
    var metrics: MetricsSnapshot = .empty
    var rateState: RateState?
    var lastError: String?
    var pollTask: Task<Void, Never>?

    init(id: ServerProfile.ID) {
        self.id = id
    }
}

struct ServerStore {
    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = dir.appendingPathComponent("ServerStatus", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("servers.json")
    }

    func load() -> [ServerProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ServerProfile].self, from: data)) ?? []
    }

    func save(_ servers: [ServerProfile]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "请求超时" }
}
