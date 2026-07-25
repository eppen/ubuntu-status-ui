import Foundation

enum Formatters {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))))
    }

    static func rateBps(_ value: Double) -> String {
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1024 * 1024 { return String(format: "%.1f KB/s", value / 1024) }
        if value < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", value / 1024 / 1024) }
        return String(format: "%.2f GB/s", value / 1024 / 1024 / 1024)
    }

    static func uptime(_ seconds: Int) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func compactCount(_ value: Int) -> String {
        let v = abs(value)
        if v < 1000 { return "\(value)" }
        if v < 1_000_000 { return String(format: "%.1fk", Double(value) / 1000) }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
}
