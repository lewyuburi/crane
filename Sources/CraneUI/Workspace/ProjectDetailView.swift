import CraneCore
import SwiftUI

/// Overview of a Compose project: the same chrome as a container, minus Terminal and Files.
struct ProjectDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", stats = "Stats", logs = "Logs"
        var id: String { rawValue }
    }

    @Environment(EngineModel.self) private var model
    let project: Project
    @Binding var selection: WorkspaceItem?
    @State private var tab: Tab = .info

    var body: some View {
        Group {
            switch tab {
            case .info:
                ProjectInfoTab(project: project, selection: $selection)
            case .stats:
                ProjectStatsTab(project: project, selection: $selection)
            case .logs:
                LogsTab(project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(project.name)
        .navigationSubtitle(project.statusLabel)
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
                if let port = project.publishedPorts.first?.hostPort,
                   let url = URL(string: "http://localhost:\(port)") {
                    Button("Open", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        .help("Open localhost:\(port)")
                }
                if !project.isFullyStopped {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await model.workspace.stop(project.containers) }
                    }
                }
                if !project.isFullyUp {
                    Button("Start", systemImage: "play.fill") {
                        Task { await model.workspace.start(project.containers) }
                    }
                }
            }
        }
    }
}

private struct ProjectInfoTab: View {
    @Environment(EngineModel.self) private var model
    let project: Project
    @Binding var selection: WorkspaceItem?

    var body: some View {
        Form {
            Section {
                HStack(spacing: Metric.regular) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(project.isFullyUp ? Color.accentColor : .secondary)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.title2.weight(.semibold))
                        Text(project.statusLabel)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Status") {
                DetailRow("State", project.statusLabel)
                DetailRow("Services", "\(project.runningCount) of \(project.containers.count) running")
            }

            Section("Services") {
                ForEach(project.containers) { container in
                    Button {
                        selection = .container(container.id)
                    } label: {
                        DetailRow(container.service ?? container.name, container.state.label)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !project.publishedPorts.isEmpty {
                Section("Ports") {
                    ForEach(Array(project.publishedPorts.enumerated()), id: \.offset) { _, port in
                        if let host = port.hostPort {
                            DetailRow("localhost:\(host)", "\(port.containerPort)/\(port.proto)",
                                      monospaced: true)
                        }
                    }
                }
            }

            if !collisionWarnings.isEmpty {
                Section("Short names") {
                    ForEach(Array(collisionWarnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            ForEach(services) { container in
                Section(container.service ?? container.name) {
                    ReachableAsRows(
                        names: ReachableNames(of: container, among: among),
                        showCollision: false)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var among: [Container] { model.workspace.containers }

    private var collisionWarnings: [String] {
        ReachableNames.stackWarnings(in: project, among: among)
    }

    private var services: [Container] {
        project.containers.sorted {
            ($0.service ?? $0.name, $0.name) < ($1.service ?? $1.name, $1.name)
        }
    }
}

private struct ProjectStatsTab: View {
    @Environment(EngineModel.self) private var model
    let project: Project
    @Binding var selection: WorkspaceItem?
    @State private var sessions: [String: StatsSession] = [:]

    var body: some View {
        Form {
            Section("Stack") {
                DetailRow("Services", "\(project.runningCount) of \(project.containers.count) running")
                DetailRow("CPU", String(format: "%.1f %%", totalCPU), monospaced: true)
                DetailRow("Memory", byteString(totalMemory), monospaced: true)
            }
            Section("Services") {
                ForEach(project.containers) { container in
                    Button {
                        selection = .container(container.id)
                    } label: {
                        DetailRow(container.service ?? container.name, line(for: container))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: project.containers.map(\.id)) {
            let running = project.containers.filter(\.isRunning)
            let next = Dictionary(uniqueKeysWithValues: running.map {
                ($0.id, StatsSession(client: model.client, containerID: $0.runtimeID))
            })
            next.values.forEach { $0.start() }
            sessions = next
            defer { next.values.forEach { $0.stop() } }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private var totalCPU: Double {
        project.containers.compactMap { sessions[$0.id]?.cpuPercent }.reduce(0, +)
    }

    private var totalMemory: Int64 {
        project.containers.compactMap { sessions[$0.id]?.latest?.memoryUsage }.reduce(0, +)
    }

    private func line(for container: Container) -> String {
        guard container.isRunning else { return container.state.label }
        guard let session = sessions[container.id], let sample = session.latest else {
            return "Sampling…"
        }
        return String(format: "%.1f %% · %@", session.cpuPercent, byteString(sample.memoryUsage))
    }
}

#Preview("Stack detail") {
    let model = CranePreview.model()
    let project = model.workspace.grouping.projects.first { $0.name == "shop" }!
    return NavigationStack {
        ProjectDetailView(project: project, selection: .constant(.project("shop")))
    }
    .environment(model)
    .frame(width: 520, height: 640)
}
