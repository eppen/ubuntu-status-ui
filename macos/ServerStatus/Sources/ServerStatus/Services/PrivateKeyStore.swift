import Foundation

enum PrivateKeyStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ServerStatus/Keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copy imported key into app sandbox and return stored path.
    static func importKey(from sourceURL: URL, serverID: UUID) throws -> String {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: sourceURL)
        let dest = directory.appendingPathComponent("\(serverID.uuidString).pem")
        try data.write(to: dest, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: dest.path
        )
        return dest.path
    }

    static func removeKey(serverID: UUID) {
        let dest = directory.appendingPathComponent("\(serverID.uuidString).pem")
        try? FileManager.default.removeItem(at: dest)
    }
}
