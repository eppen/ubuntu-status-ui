import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if model.selectedServer == nil {
                emptyState
            } else {
                ScrollView {
                    metricsGrid
                        .padding(20)
                }
            }
        }
        .background(Color.ssWindowBackground)
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedServer?.displayTitle ?? "未选择服务器")
                        .font(.title2.bold())
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(connectButtonTitle) {
                    Task {
                        if case .connected = model.connectionState {
                            await model.disconnect()
                        } else {
                            await model.connectSelected()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedServer == nil || model.connectionState == .connecting)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Uptime", Formatters.uptime(model.metrics.uptimeSeconds))
                    chip("温度", model.metrics.tempC.map { String(format: "%.1f°C", $0) } ?? "—")
                    chip("Load", String(format: "%.2f / %.2f / %.2f", model.metrics.load1, model.metrics.load5, model.metrics.load15))
                    chip("Docker", dockerChipText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusLine: String {
        var parts = [model.connectionState.label]
        if let err = model.lastError, case .failed = model.connectionState {
            parts = [model.connectionState.label]
            _ = err
        }
        if model.isPolling {
            parts.append("刷新中")
        }
        if model.metrics.ts != .distantPast {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            parts.append("更新 \(f.string(from: model.metrics.ts))")
        }
        return parts.joined(separator: " · ")
    }

    private var connectButtonTitle: String {
        switch model.connectionState {
        case .connected, .connecting: return model.connectionState == .connecting ? "连接中…" : "断开"
        default: return "连接"
        }
    }

    private func chip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("添加一台 Ubuntu 服务器开始监控")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var metricsGrid: some View {
        let m = model.metrics
        return VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                GaugeCard(
                    title: "CPU",
                    percent: m.cpuPercent,
                    bigText: Formatters.percent(m.cpuPercent),
                    smallText: "\(m.cpuCores) 核",
                    rows: [
                        ("系统负载", String(format: "%.2f", m.load1)),
                        ("时间", timeString(m.ts))
                    ]
                )
                GaugeCard(
                    title: "内存",
                    percent: m.memPercent,
                    bigText: Formatters.percent(m.memPercent),
                    smallText: "可用 \(Formatters.bytes(m.memAvailable))",
                    rows: [
                        ("已用", Formatters.bytes(m.memUsed)),
                        ("Swap", "\(Formatters.bytes(m.swapUsed)) (\(Formatters.percent(m.swapPercent)))")
                    ]
                )
                GaugeCard(
                    title: "磁盘",
                    percent: m.diskPercent,
                    bigText: Formatters.percent(m.diskPercent),
                    smallText: "剩余 \(Formatters.bytes(m.diskFree))",
                    rows: [
                        ("读", Formatters.rateBps(m.diskReadBps)),
                        ("写", Formatters.rateBps(m.diskWriteBps))
                    ]
                )
                NetworkCard(up: m.netOutBps, down: m.netInBps)
            }

            ProcessTableView(items: m.top)
            DockerPanelView(docker: m.docker)
        }
    }

    private var dockerChipText: String {
        guard let d = model.metrics.docker else { return "—" }
        if !d.available { return "不可用" }
        return "\(d.running) 运行"
    }

    private func timeString(_ date: Date) -> String {
        guard date != .distantPast else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

struct GaugeCard: View {
    let title: String
    let percent: Double
    let bigText: String
    let smallText: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            HStack(spacing: 20) {
                GaugeView(percent: percent, bigText: bigText, smallText: smallText)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.0) { row in
                        HStack {
                            Text(row.0).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.1).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.ssCardBackground))
    }
}

struct NetworkCard: View {
    let up: Double
    let down: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网络")
                .font(.headline)
            rateRow(label: "↑ 上传", value: up, color: .orange)
            rateRow(label: "↓ 下载", value: down, color: .teal)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.ssCardBackground))
    }

    private func rateRow(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(Formatters.rateBps(value)).monospacedDigit()
            }
            .font(.callout)
            GeometryReader { geo in
                let ratio = min(1.0, value / (50 * 1024 * 1024))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 8)
        }
    }
}
