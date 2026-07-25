import SwiftUI

struct OpenClawPanelView: View {
    let openclaw: RawMetricsPayload.OpenClawInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OpenClaw")
                    .font(.headline)
                Spacer()
                Text(headerMeta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let openclaw {
                if !openclaw.available {
                    Text(openclaw.error ?? "OpenClaw 不可用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    summaryRow(openclaw)

                    if let tasks = openclaw.tasks {
                        taskRow(tasks)
                    }

                    if !openclaw.agents.isEmpty {
                        agentSection(openclaw.agents)
                    }

                    if !openclaw.channels.isEmpty {
                        channelSection(openclaw.channels)
                    }

                    if !openclaw.recent_sessions.isEmpty {
                        sessionSection(openclaw.recent_sessions)
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
        guard let openclaw else { return "" }
        if !openclaw.available {
            return openclaw.error ?? "不可用"
        }
        var parts: [String] = []
        if let v = openclaw.version { parts.append("v\(v)") }
        if let ch = openclaw.update_channel, !ch.isEmpty { parts.append(ch) }
        if let svc = openclaw.service, !svc.status.isEmpty {
            parts.append(svc.status)
        } else if let gw = openclaw.gateway {
            parts.append(gw.reachable ? "可达" : "不可达")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func summaryRow(_ info: RawMetricsPayload.OpenClawInfo) -> some View {
        let gw = info.gateway
        let svc = info.service
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metaCell("Gateway", gatewayText(gw))
            metaCell("服务", serviceText(svc))
            metaCell("会话", "\(info.sessions_count)")
            metaCell("模型", info.default_model ?? "—")
        }
        if let err = gw?.error, !err.isEmpty {
            Text(err)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if gw?.misconfigured == true {
            Text("Gateway 配置异常")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func taskRow(_ tasks: RawMetricsPayload.OpenClawTasks) -> some View {
        HStack(spacing: 8) {
            taskChip("任务", "\(tasks.total)")
            taskChip("活跃", "\(tasks.active)")
            taskChip("成功", "\(tasks.succeeded)")
            taskChip("失败", "\(tasks.failures)")
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func agentSection(_ agents: [RawMetricsPayload.OpenClawAgent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agents")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(agents) { a in
                HStack {
                    Text(a.id.isEmpty ? "—" : a.id)
                        .font(.callout.weight(.medium))
                    if a.bootstrap_pending {
                        Text("bootstrap")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("\(a.sessions) 会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ageText(a.last_active_ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func channelSection(_ channels: [RawMetricsPayload.OpenClawChannel]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Channels")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(channels) { ch in
                HStack {
                    Text(ch.name.isEmpty ? "—" : ch.name)
                        .font(.callout)
                    Spacer()
                    Text(ch.status.isEmpty ? "—" : ch.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func sessionSection(_ sessions: [RawMetricsPayload.OpenClawSession]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近会话")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("类型").fontWeight(.semibold)
                        Text("名称").fontWeight(.semibold)
                        Text("模型").fontWeight(.semibold)
                        Text("用量").fontWeight(.semibold)
                        Text("活跃").fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    ForEach(sessions) { s in
                        GridRow {
                            kindBadge(s.kind, aborted: s.aborted)
                            Text(s.key.isEmpty ? "—" : s.key).lineLimit(1)
                            Text(s.model.isEmpty ? "—" : s.model)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Text(usageText(s)).monospacedDigit()
                            Text(ageText(s.age_ms)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .frame(minWidth: 560, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private func metaCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func taskChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func gatewayText(_ gw: RawMetricsPayload.OpenClawGateway?) -> String {
        guard let gw else { return "—" }
        var parts: [String] = []
        parts.append(gw.reachable ? "可达" : "不可达")
        if let ms = gw.latency_ms { parts.append("\(ms)ms") }
        if !gw.mode.isEmpty { parts.append(gw.mode) }
        return parts.joined(separator: " · ")
    }

    private func serviceText(_ svc: RawMetricsPayload.OpenClawService?) -> String {
        guard let svc else { return "—" }
        if !svc.short.isEmpty { return svc.short }
        var parts: [String] = []
        if !svc.status.isEmpty { parts.append(svc.status) }
        if let pid = svc.pid { parts.append("pid \(pid)") }
        if !svc.label.isEmpty { parts.append(svc.label) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func usageText(_ s: RawMetricsPayload.OpenClawSession) -> String {
        if let p = s.percent_used {
            return "\(p)%"
        }
        if let t = s.total_tokens {
            return Formatters.compactCount(t)
        }
        return "—"
    }

    private func ageText(_ ms: Int?) -> String {
        guard let ms, ms >= 0 else { return "—" }
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    private func kindBadge(_ kind: String, aborted: Bool) -> some View {
        let color: Color = {
            if aborted { return .orange }
            switch kind {
            case "direct": return .green
            case "group": return .teal
            case "cron": return .blue
            default: return .secondary
            }
        }()
        return Text(kind.isEmpty ? "—" : kind)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
