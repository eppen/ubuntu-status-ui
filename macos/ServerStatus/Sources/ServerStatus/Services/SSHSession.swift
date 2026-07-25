import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH

actor SSHSession {
    private var client: SSHClient?
    private(set) var isConnected = false

    func connect(profile: ServerProfile, password: String?, privateKeyPath: String?) async throws {
        await close()

        let auth: SSHAuthenticationMethod
        switch profile.authMethod {
        case .password:
            guard let password, !password.isEmpty else {
                throw SSHSessionError.missingCredential("缺少密码")
            }
            auth = .passwordBased(username: profile.username, password: password)
        case .privateKey:
            let path = privateKeyPath ?? profile.credentialRef
            guard !path.isEmpty else {
                throw SSHSessionError.missingCredential("缺少私钥路径")
            }
            auth = try Self.makePrivateKeyAuth(username: profile.username, path: path)
        }

        var algorithms = SSHAlgorithms.all

        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { auth },
            hostKeyValidator: .acceptAnything()
        )
        settings.algorithms = algorithms

        let connected = try await SSHClient.connect(to: settings)
        self.client = connected
        self.isConnected = true
    }

    func execute(_ command: String, maxBytes: Int = 512 * 1024) async throws -> String {
        guard let client else { throw SSHSessionError.notConnected }
        let buffer = try await client.executeCommand(
            command,
            maxResponseSize: maxBytes,
            mergeStreams: true,
            inShell: false
        )
        return String(buffer: buffer)
    }

    func fetchRawMetrics() async throws -> RawMetricsPayload {
        let output = try await execute(RemoteCollectorScript.remoteCommand())
        guard let jsonText = RemoteCollectorScript.extractJSONObject(from: output),
              let data = jsonText.data(using: .utf8) else {
            let preview = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            throw SSHSessionError.invalidMetrics("未找到 JSON 输出：\n\(preview)")
        }
        do {
            return try JSONDecoder().decode(RawMetricsPayload.self, from: data)
        } catch {
            let preview = String(jsonText.prefix(500))
            throw SSHSessionError.invalidMetrics("JSON 解码失败：\(error)\n\(preview)")
        }
    }

    func close() async {
        if let client {
            try? await client.close()
        }
        self.client = nil
        self.isConnected = false
    }

    private static func makePrivateKeyAuth(username: String, path: String) throws -> SSHAuthenticationMethod {
        let expanded = (path as NSString).expandingTildeInPath
        let contents: String
        do {
            contents = try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw SSHSessionError.missingCredential("无法读取私钥：\(expanded)")
        }

        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: contents) {
            return .ed25519(username: username, privateKey: key)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: contents) {
            return .rsa(username: username, privateKey: key)
        }
        throw SSHSessionError.missingCredential("不支持的私钥格式（需 OpenSSH ed25519 或 RSA）")
    }
}

enum SSHSessionError: LocalizedError {
    case notConnected
    case missingCredential(String)
    case invalidMetrics(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接"
        case .missingCredential(let m): return m
        case .invalidMetrics(let m): return m
        }
    }
}
