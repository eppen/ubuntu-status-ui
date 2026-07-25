import Foundation

struct RawMetricsPayload: Codable {
    var ts: Double
    var uptime_s: Int
    var load: LoadAvg
    var cpu: CPURaw
    var mem: MemInfo
    var swap: SwapInfo
    var disk: DiskInfo
    var net_bytes: [String: NetBytes]
    var disk_bytes: DiskBytes
    var temp_c: Double?
    var top: [ProcessInfo]
    var docker: DockerInfo?
    var openclaw: OpenClawInfo?

    struct LoadAvg: Codable {
        var l1: Double
        var l5: Double
        var l15: Double
    }

    struct CPURaw: Codable {
        var total: UInt64
        var idle: UInt64
        var cores: Int
    }

    struct MemInfo: Codable {
        var total: UInt64
        var used: UInt64
        var available: UInt64
        var percent: Double
    }

    struct SwapInfo: Codable {
        var total: UInt64
        var used: UInt64
        var percent: Double
    }

    struct DiskInfo: Codable {
        var mount: String
        var total: UInt64
        var used: UInt64
        var free: UInt64
        var percent: Double
    }

    struct NetBytes: Codable {
        var rx: UInt64
        var tx: UInt64
    }

    struct DiskBytes: Codable {
        var read: UInt64
        var write: UInt64
    }

    struct ProcessInfo: Codable, Identifiable, Equatable {
        var pid: Int
        var name: String
        var user: String
        var cpu: Double
        var rss: UInt64

        var id: Int { pid }
    }

    struct DockerInfo: Codable, Equatable {
        var available: Bool
        var version: String?
        var error: String?
        var running: Int
        var paused: Int
        var stopped: Int
        var containers: [DockerContainer]
    }

    struct DockerContainer: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var image: String
        var state: String
        var status: String
        var ports: String
        var cpu: Double?
        var mem_percent: Double?
        var mem_usage: String
        var net_io: String
    }

    struct OpenClawInfo: Codable, Equatable {
        var available: Bool
        var error: String?
        var version: String?
        var update_channel: String?
        var gateway: OpenClawGateway?
        var service: OpenClawService?
        var sessions_count: Int
        var default_model: String?
        var agents: [OpenClawAgent]
        var tasks: OpenClawTasks?
        var channels: [OpenClawChannel]
        var recent_sessions: [OpenClawSession]
    }

    struct OpenClawGateway: Codable, Equatable {
        var mode: String
        var url: String
        var reachable: Bool
        var misconfigured: Bool
        var latency_ms: Int?
        var host: String
        var ip: String
        var version: String
        var error: String?
    }

    struct OpenClawService: Codable, Equatable {
        var label: String
        var installed: Bool
        var loaded: Bool
        var status: String
        var state: String
        var pid: Int?
        var short: String
    }

    struct OpenClawAgent: Codable, Identifiable, Equatable {
        var id: String
        var sessions: Int
        var last_active_ms: Int?
        var bootstrap_pending: Bool
    }

    struct OpenClawTasks: Codable, Equatable {
        var total: Int
        var active: Int
        var failures: Int
        var running: Int
        var queued: Int
        var succeeded: Int
        var failed: Int
    }

    struct OpenClawChannel: Codable, Identifiable, Equatable {
        var name: String
        var status: String

        var id: String { "\(name)|\(status)" }
    }

    struct OpenClawSession: Codable, Identifiable, Equatable {
        var agent_id: String
        var key: String
        var kind: String
        var model: String
        var age_ms: Int?
        var percent_used: Int?
        var total_tokens: Int?
        var aborted: Bool

        var id: String { "\(agent_id):\(key):\(kind)" }
    }
}

struct MetricsSnapshot: Equatable {
    var ts: Date
    var uptimeSeconds: Int
    var load1: Double
    var load5: Double
    var load15: Double
    var cpuPercent: Double
    var cpuCores: Int
    var memTotal: UInt64
    var memUsed: UInt64
    var memAvailable: UInt64
    var memPercent: Double
    var swapTotal: UInt64
    var swapUsed: UInt64
    var swapPercent: Double
    var diskMount: String
    var diskTotal: UInt64
    var diskUsed: UInt64
    var diskFree: UInt64
    var diskPercent: Double
    var netInBps: Double
    var netOutBps: Double
    var diskReadBps: Double
    var diskWriteBps: Double
    var tempC: Double?
    var top: [RawMetricsPayload.ProcessInfo]
    var docker: RawMetricsPayload.DockerInfo?
    var openclaw: RawMetricsPayload.OpenClawInfo?

    static let empty = MetricsSnapshot(
        ts: .distantPast,
        uptimeSeconds: 0,
        load1: 0, load5: 0, load15: 0,
        cpuPercent: 0, cpuCores: 0,
        memTotal: 0, memUsed: 0, memAvailable: 0, memPercent: 0,
        swapTotal: 0, swapUsed: 0, swapPercent: 0,
        diskMount: "/", diskTotal: 0, diskUsed: 0, diskFree: 0, diskPercent: 0,
        netInBps: 0, netOutBps: 0,
        diskReadBps: 0, diskWriteBps: 0,
        tempC: nil,
        top: [],
        docker: nil,
        openclaw: nil
    )
}

struct RateState {
    var time: Date
    var cpuTotal: UInt64
    var cpuIdle: UInt64
    var net: [String: (rx: UInt64, tx: UInt64)]
    var diskRead: UInt64
    var diskWrite: UInt64
}

enum MetricsMath {
    static let ignoredIfacePrefixes = [
        "lo", "lo0", "docker", "br-", "veth", "virbr", "tailscale", "cni", "flannel", "cali",
        "awdl", "llw", "utun", "ap", "bridge", "gif", "stf", "anpi", "vmenet", "docker"
    ]

    static func isRealIface(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "lo" || lower == "lo0" { return false }
        for p in ignoredIfacePrefixes {
            if lower == p || lower.hasPrefix(p) { return false }
        }
        return true
    }

    static func buildSnapshot(raw: RawMetricsPayload, previous: RateState?) -> (MetricsSnapshot, RateState) {
        let now = Date(timeIntervalSince1970: raw.ts)
        let netMap = raw.net_bytes.mapValues { (rx: $0.rx, tx: $0.tx) }
        let current = RateState(
            time: now,
            cpuTotal: raw.cpu.total,
            cpuIdle: raw.cpu.idle,
            net: netMap,
            diskRead: raw.disk_bytes.read,
            diskWrite: raw.disk_bytes.write
        )

        var cpuPercent = 0.0
        var netIn = 0.0
        var netOut = 0.0
        var diskRead = 0.0
        var diskWrite = 0.0

        if let prev = previous {
            let dt = max(0.25, now.timeIntervalSince(prev.time))
            let dTotal = Double(current.cpuTotal &- prev.cpuTotal)
            let dIdle = Double(current.cpuIdle &- prev.cpuIdle)
            if dTotal > 0 {
                cpuPercent = max(0, min(100, (1.0 - dIdle / dTotal) * 100.0))
            }

            for (iface, cur) in current.net where isRealIface(iface) {
                let prevBytes = prev.net[iface] ?? cur
                netIn += max(0, Double(cur.rx &- prevBytes.rx) / dt)
                netOut += max(0, Double(cur.tx &- prevBytes.tx) / dt)
            }

            diskRead = max(0, Double(current.diskRead &- prev.diskRead) / dt)
            diskWrite = max(0, Double(current.diskWrite &- prev.diskWrite) / dt)
        }

        let snapshot = MetricsSnapshot(
            ts: now,
            uptimeSeconds: raw.uptime_s,
            load1: raw.load.l1,
            load5: raw.load.l5,
            load15: raw.load.l15,
            cpuPercent: (cpuPercent * 10).rounded() / 10,
            cpuCores: raw.cpu.cores,
            memTotal: raw.mem.total,
            memUsed: raw.mem.used,
            memAvailable: raw.mem.available,
            memPercent: raw.mem.percent,
            swapTotal: raw.swap.total,
            swapUsed: raw.swap.used,
            swapPercent: raw.swap.percent,
            diskMount: raw.disk.mount,
            diskTotal: raw.disk.total,
            diskUsed: raw.disk.used,
            diskFree: raw.disk.free,
            diskPercent: raw.disk.percent,
            netInBps: netIn,
            netOutBps: netOut,
            diskReadBps: diskRead,
            diskWriteBps: diskWrite,
            tempC: raw.temp_c,
            top: raw.top,
            docker: raw.docker,
            openclaw: raw.openclaw
        )
        return (snapshot, current)
    }
}
