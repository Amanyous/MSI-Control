import SwiftUI
import ECControl

struct CPUFrequencyDetails: View {
    @ObservedObject var monitor: SystemMonitor
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) {
                    Label("返回仪表盘", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                Text("CPU 频率").font(.headline)
                Spacer()
                Text("APERF / MPERF").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(monitor.coreFrequencyRows.count) 个逻辑核心")
                Spacer()
                Text("\(monitor.coreFrequencyRows.filter { $0.frequency != nil }.count) 个频率有效")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let issue = monitor.coreDetailsIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Table(monitor.coreFrequencyRows) {
                TableColumn("逻辑核心") { row in Text("\(row.id)").monospacedDigit() }
                TableColumn("APIC") { row in
                    Text(row.apic.map { String($0) } ?? "—").monospacedDigit()
                }
                TableColumn("类型") { row in Text(row.kind) }
                TableColumn("运行频率") { row in
                    Text(row.frequency.map { frequency in
                        frequency.activeGHz.map { String(format: "%.2f GHz", $0) } ?? "空闲"
                    } ?? "等待采样").monospacedDigit()
                }
                TableColumn("有效频率") { row in
                    Text(row.frequency.map { String(format: "%.2f GHz", $0.effectiveGHz) }
                         ?? "等待采样").monospacedDigit()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
