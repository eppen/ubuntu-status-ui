import Foundation
import Citadel
import Crypto
import NIO
import NIOSSH

actor SSHSession {
    private var client: SSHClient?
    #if canImport(AppKit)
    private var processClient: ProcessSSHSession?
    #endif
    private(set) var isConnected = false

    func connect(profile: ServerProfile, password: String?, privateKeyPath: String?) async throws {
        await close()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.connectCitadel(profile: profile, password: password, privateKeyPath: privateKeyPath)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    throw SSHSessionError.connectFailed("Citadel 连接超时，尝试兼容模式…")
                }
                try await group.next()!
                group.cancelAll()
            }
            isConnected = true
            return
        } catch {
            #if canImport(AppKit)
            // Ancient OpenSSH (e.g. 3.7 on 192.168.3.2) often fails Citadel/NIOSSH negotiation.
            let process = ProcessSSHSession()
            do {
                try await process.connect(profile: profile, password: password, privateKeyPath: privateKeyPath)
                self.processClient = process
                self.isConnected = true
                return
            } catch {
                throw SSHSessionError.connectFailed(Self.describe(error))
            }
            #else
            throw SSHSessionError.connectFailed(Self.describe(error))
            #endif
        }
    }

    func execute(_ command: String, maxBytes: Int = 512 * 1024) async throws -> String {
        #if canImport(AppKit)
        if let processClient {
            return try await processClient.execute(command, maxBytes: maxBytes)
        }
        #endif
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
        #if canImport(AppKit)
        if processClient != nil {
            return try await fetchRawMetricsViaProcessSSH()
        }
        #endif

        let output = try await execute(RemoteCollectorScript.remoteCommand())
        return try Self.decodeMetrics(from: output, stderr: "")
    }

    #if canImport(AppKit)
    private func fetchRawMetricsViaProcessSSH() async throws -> RawMetricsPayload {
        // ProcessSSH is the ancient-OpenSSH fallback: prefer POSIX sh first (no python3 / tiny tools).
        if let shData = RemoteCollectorScript.legacyShellSource.data(using: .utf8) {
            do {
                let shOut = try await execute(
                    RemoteCollectorScript.legacyShellRemoteCommand,
                    stdinData: shData
                )
                if let payload = try? Self.decodeMetrics(from: shOut.stdout, stderr: shOut.stderr) {
                    // Prefer shell result even if disk/top empty; try python only when shell JSON missing.
                    if payload.disk.total > 0 || !payload.top.isEmpty {
                        return payload
                    }
                    // Keep as fallback if python also fails
                    if let pyData = RemoteCollectorScript.source.data(using: .utf8) {
                        do {
                            let pyOut = try await execute(
                                RemoteCollectorScript.pythonStdinRemoteCommand,
                                stdinData: pyData
                            )
                            if let pyPayload = try? Self.decodeMetrics(from: pyOut.stdout, stderr: pyOut.stderr),
                               pyPayload.disk.total > 0 || !pyPayload.top.isEmpty {
                                return pyPayload
                            }
                        } catch {
                            // ignore
                        }
                    }
                    return payload
                }
            } catch {
                // Fall through to python
            }
        }

        if let pyData = RemoteCollectorScript.source.data(using: .utf8) {
            let pyOut = try await execute(
                RemoteCollectorScript.pythonStdinRemoteCommand,
                stdinData: pyData
            )
            return try Self.decodeMetrics(from: pyOut.stdout, stderr: pyOut.stderr)
        }

        throw SSHSessionError.invalidMetrics("无法采集指标（legacy shell / python 均不可用）")
    }

    private func execute(_ command: String, stdinData: Data, maxBytes: Int = 512 * 1024) async throws -> (stdout: String, stderr: String) {
        guard let processClient else { throw SSHSessionError.notConnected }
        return try await processClient.execute(command, stdinData: stdinData, maxBytes: maxBytes)
    }
    #endif

    private static func decodeMetrics(from output: String, stderr: String) throws -> RawMetricsPayload {
        guard let jsonText = RemoteCollectorScript.extractJSONObject(from: output),
              let data = jsonText.data(using: .utf8) else {
            let preview = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            let err = String(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            var msg = "未找到 JSON 输出："
            if !preview.isEmpty { msg += "\n\(preview)" }
            if !err.isEmpty { msg += "\nstderr: \(err)" }
            if preview.isEmpty && err.isEmpty { msg += "（远端无输出，可能缺少 python/sh）" }
            throw SSHSessionError.invalidMetrics(msg)
        }
        do {
            return try JSONDecoder().decode(RawMetricsPayload.self, from: data)
        } catch {
            let preview = String(jsonText.prefix(500))
            throw SSHSessionError.invalidMetrics("JSON 解码失败：\(error)\n\(preview)")
        }
    }

    func close() async {
        #if canImport(AppKit)
        if let processClient {
            await processClient.close()
            self.processClient = nil
        }
        #endif
        if let client {
            try? await client.close()
        }
        self.client = nil
        self.isConnected = false
    }

    // MARK: - Citadel

    private func connectCitadel(profile: ServerProfile, password: String?, privateKeyPath: String?) async throws {
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

        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { auth },
            hostKeyValidator: .acceptAnything()
        )
        settings.algorithms = SSHAlgorithms.all

        let connected = try await SSHClient.connect(to: settings)
        self.client = connected
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

    private static func describe(_ error: Error) -> String {
        if let ssh = error as? NIOSSHError {
            return "SSH 协议错误：\(ssh.type)"
        }
        if let localized = error as? LocalizedError, let d = localized.errorDescription, !d.isEmpty {
            return d
        }
        return error.localizedDescription
    }
}

enum SSHSessionError: LocalizedError {
    case notConnected
    case missingCredential(String)
    case invalidMetrics(String)
    case connectFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "尚未连接"
        case .missingCredential(let m): return m
        case .invalidMetrics(let m): return m
        case .connectFailed(let m): return m
        }
    }
}

#if canImport(AppKit)
/// OpenSSH CLI backend for ancient servers (e.g. OpenSSH 3.x) that Citadel/NIOSSH cannot negotiate with.
actor ProcessSSHSession {
    private var profile: ServerProfile?
    private var privateKeyPath: String?
    private var controlPath: String?
    private var askpassPath: String?
    private(set) var isConnected = false

    func connect(profile: ServerProfile, password: String?, privateKeyPath: String?) async throws {
        await close()

        switch profile.authMethod {
        case .password:
            guard let password, !password.isEmpty else {
                throw SSHSessionError.missingCredential("缺少密码")
            }
            self.askpassPath = try Self.writeAskpassScript(password: password)
            self.privateKeyPath = nil
        case .privateKey:
            let path = (privateKeyPath ?? profile.credentialRef) as NSString
            let expanded = path.expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: expanded) else {
                throw SSHSessionError.missingCredential("无法读取私钥：\(expanded)")
            }
            self.privateKeyPath = expanded
        }

        self.profile = profile
        // Unix domain sockets on macOS are capped at ~104 bytes; avoid long /var/folders/... paths.
        let shortID = String(profile.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        let control = "/tmp/ss-\(shortID).sock"
        self.controlPath = control
        try? FileManager.default.removeItem(atPath: control)

        let probe = try await runSSH(remoteCommand: "true", extraArgs: [])
        if probe.exitCode != 0 {
            let err = probe.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHSessionError.connectFailed(err.isEmpty ? "系统 ssh 连接失败（exit \(probe.exitCode)）" : err)
        }
        isConnected = true
    }

    func execute(_ command: String, maxBytes: Int = 512 * 1024) async throws -> String {
        let result = try await execute(command, stdinData: nil, maxBytes: maxBytes)
        return result.stdout
    }

    func execute(_ command: String, stdinData: Data?, maxBytes: Int = 512 * 1024) async throws -> (stdout: String, stderr: String) {
        guard isConnected, profile != nil else { throw SSHSessionError.notConnected }
        let result = try await runSSH(remoteCommand: command, extraArgs: [], stdinData: stdinData)
        if result.exitCode != 0 && result.stdout.isEmpty {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHSessionError.connectFailed(err.isEmpty ? "远程命令失败（exit \(result.exitCode)）" : err)
        }
        var stdout = result.stdout
        if stdout.utf8.count > maxBytes {
            stdout = String(stdout.prefix(maxBytes))
        }
        return (stdout, result.stderr)
    }

    func close() async {
        if profile != nil {
            _ = try? await runSSH(remoteCommand: nil, extraArgs: ["-O", "exit"], allowFailure: true)
        }
        if let controlPath {
            try? FileManager.default.removeItem(atPath: controlPath)
        }
        if let askpassPath {
            try? FileManager.default.removeItem(atPath: askpassPath)
        }
        profile = nil
        privateKeyPath = nil
        controlPath = nil
        askpassPath = nil
        isConnected = false
    }

    private struct SSHResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func runSSH(
        remoteCommand: String?,
        extraArgs: [String],
        allowFailure: Bool = false,
        stdinData: Data? = nil
    ) async throws -> SSHResult {
        guard let profile else { throw SSHSessionError.notConnected }

        var args: [String] = [
            "-p", "\(profile.port)",
            "-o", "BatchMode=\(profile.authMethod == .privateKey ? "yes" : "no")",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=12",
            // Legacy algorithms for OpenSSH 3.x / early 4.x (e.g. 192.168.3.2)
            // OpenSSH 10+ rejects ssh-dss entirely ("Bad key types"); only re-enable ssh-rsa.
            "-o", "KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1",
            "-o", "HostKeyAlgorithms=+ssh-rsa",
            "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
            "-o", "Ciphers=+aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc",
            "-o", "MACs=+hmac-sha1,hmac-md5",
        ]

        if let controlPath {
            args += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=60",
            ]
        }

        if let privateKeyPath {
            args += ["-i", privateKeyPath, "-o", "IdentitiesOnly=yes"]
        } else {
            args += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        }

        args += extraArgs
        args.append("\(profile.username)@\(profile.host)")
        if let remoteCommand {
            args.append(remoteCommand)
        }

        let askpass = askpassPath
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try Self.launchSSH(args: args, askpassPath: askpass, stdinData: stdinData))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func launchSSH(args: [String], askpassPath: String?, stdinData: Data?) throws -> SSHResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"
        if let askpassPath {
            env["SSH_ASKPASS"] = askpassPath
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? "none"
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let stdinData {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(stdinData)
            try? inPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return SSHResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func writeAskpassScript(password: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("serverstatus-askpass-\(UUID().uuidString).sh")
        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
        let body = "#!/bin/sh\nprintf '%s\\n' '\(escaped)'\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }
}
#endif
