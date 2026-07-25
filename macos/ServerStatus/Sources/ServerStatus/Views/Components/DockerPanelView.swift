import SwiftUI

struct DockerPanelView: View {
    let docker: RawMetricsPayload.DockerInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Docker")
                    .font(.headline)
                Spacer()
                Text(headerMeta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let docker {
                if !docker.available {
                    Text(docker.error ?? "Docker 不可用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else if docker.containers.isEmpty {
                    Text("暂无容器")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            GridRow {
                                Text("状态").fontWeight(.semibold)
                                Text("名称").fontWeight(.semibold)
                                Text("镜像").fontWeight(.semibold)
                                Text("CPU").fontWeight(.semibold)
                                Text("内存").fontWeight(.semibold)
                                Text("端口").fontWeight(.semibold)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Divider()

                            ForEach(docker.containers) { c in
                                GridRow {
                                    stateBadge(c.state)
                                    Text(c.name).lineLimit(1)
                                    Text(c.image).lineLimit(1).foregroundStyle(.secondary)
                                    Text(c.cpu.map { String(format: "%.1f%%", $0) } ?? "—")
                                        .monospacedDigit()
                                    Text(memText(c)).lineLimit(1).monospacedDigit()
                                    Text(c.ports.isEmpty ? "—" : c.ports)
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .frame(minWidth: 720, alignment: .leading)
                    }
                }
            } else {
                Text("等待采集…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.ssCardBackground))
    }

    private var headerMeta: String {
        guard let docker else { return "" }
        if !docker.available {
            return docker.error ?? "不可用"
        }
        var parts: [String] = []
        if let v = docker.version { parts.append("v\(v)") }
        parts.append("运行 \(docker.running)")
        if docker.paused > 0 { parts.append("暂停 \(docker.paused)") }
        parts.append("停止 \(docker.stopped)")
        return parts.joined(separator: " · ")
    }

    private func memText(_ c: RawMetricsPayload.DockerContainer) -> String {
        if !c.mem_usage.isEmpty { return c.mem_usage }
        if let p = c.mem_percent { return String(format: "%.1f%%", p) }
        return "—"
    }

    private func stateBadge(_ state: String) -> some View {
        let color: Color = {
            switch state {
            case "running": return .green
            case "paused": return .orange
            case "restarting": return .yellow
            case "exited", "dead": return .secondary
            default: return .secondary
            }
        }()
        return Text(state.isEmpty ? "—" : state)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
