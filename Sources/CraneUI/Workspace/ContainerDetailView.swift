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
        .navigationTitle(container.service ?? container.name)
        .navigationSubtitle(container.image)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) {
                if container.isRunning {
                    Button("Restart", systemImage: "arrow.clockwise") {
                        Task { await model.workspace.restart(container) }
                    }
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await model.workspace.stop(container) }
                    }
                } else {
                    Button("Start", systemImage: "play.fill") {
                        Task { await model.workspace.start(container) }
                    }
                }
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
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: Metric.tight) {
                        StatusDot(state: container.state, health: container.health)
                        Text(statusText)
                    }
                }
                DetailRow("Image", container.image, monospaced: false)
                DetailRow("Container ID", String(container.id.prefix(12)))
                if let project = container.project {
                    DetailRow("Compose project", project, monospaced: false)
                    if let service = container.service {
                        DetailRow("Service", service, monospaced: false)
                    }
                }
                if let address = container.addresses.values.sorted().first {
                    DetailRow("Address", address)
                }
                if let policy = detail?.restartPolicy {
                    DetailRow("Restart policy", policy, monospaced: false)
                }
                DetailRow("Created",
                          container.created.formatted(date: .abbreviated, time: .shortened),
                          monospaced: false)
            }

            if !container.publishedPorts.isEmpty {
                Section("Published ports") {
                    ForEach(container.publishedPorts, id: \.hostPort) { port in
                        LabeledContent {
                            if let host = port.hostPort, let url = URL(string: "http://localhost:\(host)") {
                                Link("Open", destination: url)
                            }
                        } label: {
                            Text("localhost:\(port.hostPort ?? 0) → \(port.containerPort)/\(port.proto)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }

            if let detail, !detail.mounts.isEmpty {
                Section("Mounts") {
                    ForEach(Array(detail.mounts.enumerated()), id: \.offset) { _, mount in
                        DetailRow(mount.destination + (mount.readOnly ? "  (ro)" : ""),
                                  mount.name ?? mount.source)
                    }
                }
            }

            if let detail, !detail.config.environment.isEmpty {
                Section("Environment") {
                    ForEach(Array(detail.config.environment.enumerated()), id: \.offset) { _, entry in
                        let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                        DetailRow(parts.first ?? entry, parts.count > 1 ? parts[1] : "")
                    }
                }
            }

            if !container.labels.isEmpty {
                Section("Labels") {
                    ForEach(container.labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        DetailRow(key, value)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: container.id) { detail = await model.workspace.detail(container.id) }
    }

    private var statusText: String {
        var text = container.statusText.isEmpty ? container.state.label : container.statusText
        if let health = container.health { text += " · \(health.rawValue)" }
        return text
    }
}
