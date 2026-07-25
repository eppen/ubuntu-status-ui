import Foundation

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "密码"
        case .privateKey: return "私钥文件"
        }
    }
}

struct ServerProfile: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    /// Keychain account key for password, or absolute path for private key file.
    var credentialRef: String

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        credentialRef: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.credentialRef = credentialRef
    }

    var displayTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(username)@\(host)" : trimmed
    }

    var subtitle: String {
        "\(username)@\(host):\(port)"
    }
}

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .failed(let msg): return "失败：\(msg)"
        }
    }
}
