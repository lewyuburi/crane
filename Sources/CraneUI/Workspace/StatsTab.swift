import Charts
import CraneCore
import DockerAPI
import SwiftUI

/// Live CPU, memory, network and disk for a running container.
struct StatsTab: View {
    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var session: StatsSession?

    var body: some View {
        Form {
            if let session, let sample = session.latest {
                Section {
                    Trend(title: "CPU",
                          caption: String(format: "%.1f %%", session.cpuPercent),
                          values: session.cpuHistory.map { min($0 / 100, 1) },
                          tint: .blue)
                }
                Section {
                    Trend(title: "Memory",
                          caption: "\(byteString(sample.memoryUsage)) of \(byteString(sample.memoryLimit))",
                          values: session.memoryHistory,
                          tint: .green)
                }
                Section("Totals since start") {
                    LabeledContent("Network in") { Text(byteString(sample.networkRx)).monospacedDigit() }
                    LabeledContent("Network out") { Text(byteString(sample.networkTx)).monospacedDigit() }
                    LabeledContent("Disk read") { Text(byteString(sample.blockRead)).monospacedDigit() }
                    LabeledContent("Disk written") { Text(byteString(sample.blockWrite)).monospacedDigit() }
                    LabeledContent("Processes") { Text("\(sample.processes)").monospacedDigit() }
                }
            } else {
                Section {
                    HStack(spacing: Metric.snug) {
                        ProgressView().controlSize(.small)
                        Text("Sampling…").foregroundStyle(.secondary)
                    }
                }
            }
            if let failure = session?.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: container.id) {
            let session = StatsSession(client: model.client, containerID: container.id)
            self.session = session
            session.start()
            defer { session.stop() }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
    }
}

/// A headline number with its recent shape underneath.
///
/// Swift Charts rather than a hand-drawn path: it handles the scale, the fill and the animation,
/// and the result matches every other chart on the system.
private struct Trend: View {
    let title: String
    let caption: String
    /// 0…1, oldest first.
    let values: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.snug) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(caption)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            Chart(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Sample", index), y: .value("Use", value))
                    .foregroundStyle(tint.opacity(0.18).gradient)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Sample", index), y: .value("Use", value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...1)
            .chartXScale(domain: 0...Double(max(values.count - 1, StatsSession.historyLength / 4)))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 64)
            .animation(.easeOut(duration: 0.25), value: values.count)
        }
        .padding(.vertical, Metric.tight)
    }
}
