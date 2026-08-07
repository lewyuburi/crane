import AppKit
import CraneCore
import DockerAPI
import SwiftUI

/// The detail pane for one container.
struct ContainerDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", logs = "Logs", stats = "Stats", terminal = "Terminal"
        var id: String { rawValue }
    }

    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var tab: Tab = .info

    var body: some View {
        Group {
            switch tab {
            case .info:
                InfoTab(container: container)
            case .logs:
                LogsTab(container: container)
            case .stats:
                if container.isRunning {
                    StatsTab(container: container)
                } else {
                    notRunning("Stats are live-only.")
                }
            case .terminal:
                if container.isRunning {
                    TerminalTab(container: container)
                } else {
                    notRunning("Start the container to open a shell.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(container.name)
        .navigationSubtitle(container.image)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func notRunning(_ message: String) -> some View {
        ContentUnavailableView("Not running", systemImage: "pause.circle", description: Text(message))
    }
}

// MARK: - Info

private struct InfoTab: View {
    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var detail: ContainerDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.loose) {
                header
                if !container.publishedPorts.isEmpty { ports }
                if let detail { environment(detail) }
                if let detail, !detail.mounts.isEmpty { mounts(detail) }
                if !container.labels.isEmpty { labels }
            }
            .padding(Metric.loose)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: container.id) { detail = await model.workspace.detail(container.id) }
    }

    private var header: some View {
        Card {
            KeyValueRow("Status", value: statusText, tint: container.state.tint)
            RowDivider()
            KeyValueRow("Image", value: container.image)
            RowDivider()
            KeyValueRow("Container ID", value: String(container.id.prefix(12)), monospaced: true)
            if let project = container.project {
                RowDivider()
                KeyValueRow("Compose", value: "\(project) · \(container.service ?? "—")")
            }
            if let address = container.addresses.values.sorted().first {
                RowDivider()
                KeyValueRow("Address", value: address, monospaced: true)
            }
            if let detail, let policy = detail.restartPolicy {
                RowDivider()
                KeyValueRow("Restart policy", value: policy)
            }
            RowDivider()
            KeyValueRow("Created", value: container.created.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private var statusText: String {
        var text = container.statusText.isEmpty ? container.state.label : container.statusText
        if let health = container.health { text += " · \(health.rawValue)" }
        return text
    }

    private var ports: some View {
        Section("Published ports") {
            Card {
                ForEach(Array(container.publishedPorts.enumerated()), id: \.offset) { index, port in
                    if index > 0 { RowDivider() }
                    HStack {
                        Text("\(port.hostPort ?? 0) → \(port.containerPort)/\(port.proto)")
                            .font(.body.monospacedDigit())
                        Spacer()
                        if let host = port.hostPort, let url = URL(string: "http://localhost:\(host)") {
                            Link("Open", destination: url)
                        }
                    }
                    .padding(Metric.regular)
                }
            }
        }
    }

    private func environment(_ detail: ContainerDetail) -> some View {
        Section("Environment") {
            Card {
                ForEach(Array(detail.config.environment.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { RowDivider() }
                    let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                    KeyValueRow(parts.first ?? entry, value: parts.count > 1 ? parts[1] : "",
                                monospaced: true)
                }
            }
        }
    }

    private func mounts(_ detail: ContainerDetail) -> some View {
        Section("Mounts") {
            Card {
                ForEach(Array(detail.mounts.enumerated()), id: \.offset) { index, mount in
                    if index > 0 { RowDivider() }
                    KeyValueRow(mount.destination + (mount.readOnly ? "  (ro)" : ""),
                                value: mount.name ?? mount.source, monospaced: true)
                }
            }
        }
    }

    private var labels: some View {
        Section("Labels") {
            Card {
                ForEach(container.labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    KeyValueRow(key, value: value, monospaced: true)
                    if key != container.labels.keys.sorted().last { RowDivider() }
                }
            }
        }
    }
}

/// A titled block; the title is a heading, not a form label.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.snug) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false
    var tint: Color?

    init(_ key: String, value: String, monospaced: Bool = false, tint: Color? = nil) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: Metric.loose)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, Metric.regular)
        .padding(.vertical, Metric.snug)
    }
}
