import CraneCore
import DockerAPI
import SwiftUI

/// Live CPU, memory, network and disk for a running container.
struct StatsTab: View {
    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var session: StatsSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.loose) {
                if let session, let sample = session.latest {
                    Meter(title: "CPU", value: min(session.cpuPercent / 100, 1),
                          caption: String(format: "%.1f %%", session.cpuPercent),
                          history: session.cpuHistory.map { min($0 / 100, 1) }, tint: .blue)
                    Meter(title: "Memory", value: sample.memoryFraction,
                          caption: "\(byteString(sample.memoryUsage)) of \(byteString(sample.memoryLimit))",
                          history: session.memoryHistory, tint: .green)
                    counters(sample)
                } else {
                    HStack(spacing: Metric.snug) {
                        ProgressView().controlSize(.small)
                        Text("Sampling…").foregroundStyle(.secondary)
                    }
                }
                if let failure = session?.failure {
                    Text(failure).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(Metric.loose)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: container.id) {
            let session = StatsSession(client: model.client, containerID: container.id)
            self.session = session
            session.start()
            defer { session.stop() }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
    }

    private func counters(_ sample: StatsSample) -> some View {
        Card {
            CounterRow(symbol: "arrow.down.circle", title: "Network in", value: byteString(sample.networkRx))
            RowDivider()
            CounterRow(symbol: "arrow.up.circle", title: "Network out", value: byteString(sample.networkTx))
            RowDivider()
            CounterRow(symbol: "internaldrive", title: "Disk read", value: byteString(sample.blockRead))
            RowDivider()
            CounterRow(symbol: "internaldrive.fill", title: "Disk written", value: byteString(sample.blockWrite))
            RowDivider()
            CounterRow(symbol: "number", title: "Processes", value: "\(sample.processes)")
        }
    }
}

private struct CounterRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .padding(Metric.regular)
    }
}

/// A labelled bar with the recent history drawn behind it.
private struct Meter: View {
    let title: String
    let value: Double
    let caption: String
    let history: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.tight) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(caption).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Sparkline(values: history, tint: tint)
                .frame(height: 44)
                .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            ProgressView(value: min(max(value, 0), 1)).tint(tint)
        }
    }
}

/// A minimal line chart: no axes, no legend — it exists to show shape over time.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let points = values.suffix(StatsSession.historyLength)
            if points.count > 1 {
                let step = proxy.size.width / CGFloat(max(points.count - 1, 1))
                Path { path in
                    for (index, value) in points.enumerated() {
                        let x = CGFloat(index) * step
                        let y = proxy.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}
