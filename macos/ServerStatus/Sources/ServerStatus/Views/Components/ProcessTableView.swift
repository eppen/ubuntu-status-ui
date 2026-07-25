import SwiftUI

struct ProcessTableView: View {
    let items: [RawMetricsPayload.ProcessInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top 进程")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("PID").fontWeight(.semibold)
                        Text("进程").fontWeight(.semibold)
                        Text("用户").fontWeight(.semibold)
                        Text("CPU%").fontWeight(.semibold)
                        Text("RSS").fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    ForEach(items) { item in
                        GridRow {
                            Text("\(item.pid)").monospacedDigit()
                            Text(item.name).lineLimit(1)
                            Text(item.user).lineLimit(1)
                            Text(String(format: "%.1f", item.cpu)).monospacedDigit()
                            Text(Formatters.bytes(item.rss)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                .frame(minWidth: 520, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.ssCardBackground))
    }
}
