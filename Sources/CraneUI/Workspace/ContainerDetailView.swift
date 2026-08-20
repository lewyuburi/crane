import AppKit
import CraneCore
import DockerAPI
import SwiftUI

/// The detail pane for one container.
struct ContainerDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", stats = "Stats", logs = "Logs", terminal = "Terminal", files = "Files"
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
            case .files:
                if container.isRunning {
                    FilesTab(container: container)
                } else {
                    // The archive endpoint needs a running container, and so does `ls`.
                    notRunning("Files can only be browsed while the container runs.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(container.service ?? container.name)
        .navigationSubtitle(container.state.label)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) {
                if let port = container.publishedPorts.first?.hostPort,
                   let url = URL(string: "http://localhost:\(port)") {
                    Button("Open", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        .help("Open localhost:\(port)")
                }
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
            .paneEmptyState()
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
                HStack(spacing: Metric.regular) {
                    ContainerAvatar(image: container.image, state: container.state,
                                    health: container.health, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.service ?? container.name)
                            .font(.title2.weight(.semibold))
                        Text(container.image)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Status") {
                DetailRow("State", statusText)
                DetailRow("Container ID", String(container.id.prefix(12)), monospaced: true)
                if let project = container.project {
                    DetailRow("Compose project", project)
                    if let service = container.service {
                        DetailRow("Service", service)
                    }
                }
                if let address = container.addresses.values.sorted().first {
                    DetailRow("Address", address, monospaced: true)
                }
                if let policy = detail?.restartPolicy {
                    DetailRow("Restart policy", policy)
                }
                if let detail, detail.restartCount > 0 {
                    DetailRow("Restarts", "\(detail.restartCount)")
                }
                if let workdir = detail?.config.workingDirectory, !workdir.isEmpty {
                    DetailRow("Working directory", workdir, monospaced: true)
                }
                DetailRow("Created", container.created.formatted(date: .abbreviated, time: .shortened))
            }

            if !container.publishedPorts.isEmpty {
                Section("Ports") {
                    ForEach(Array(container.publishedPorts.enumerated()), id: \.offset) { _, port in
                        if let host = port.hostPort {
                            DetailRow("localhost:\(host)", "\(port.containerPort)/\(port.proto)",
                                      monospaced: true)
                        }
                    }
                }
            }

            Section("Reachable as") {
                ReachableAsRows(names: ReachableNames(of: container, among: model.workspace.containers))
            }

            if let detail, !detail.mounts.isEmpty {
                Section("Mounts") {
                    ForEach(Array(detail.mounts.enumerated()), id: \.offset) { _, mount in
                        DetailRow(mount.name ?? abbreviate(mount.source),
                                  mount.destination + (mount.readOnly ? " (ro)" : ""),
                                  monospaced: true)
                    }
                }
            }

            if let detail, !detail.config.environment.isEmpty {
                Section("Environment") {
                    ForEach(Array(detail.config.environment.enumerated()), id: \.offset) { _, entry in
                        let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                        DetailRow(parts.first ?? entry, parts.count > 1 ? parts[1] : "",
                                  monospaced: true)
                    }
                }
            }

            if !container.labels.isEmpty {
                Section("Labels") {
                    ForEach(container.labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        DetailRow(key, value, monospaced: true)
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

    /// Home-relative paths read better than absolute ones, and they're what the user typed.
    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count - 1) : path
    }
}
