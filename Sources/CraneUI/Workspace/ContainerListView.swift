import CraneCore
import SwiftUI

/// The container list: Compose projects as sections, loose containers below.
///
/// Rows are dense on purpose — status, name, image and published ports at a glance, with actions
/// appearing on hover so the list stays quiet until you reach for it.
struct ContainerListView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Container.ID?
    @State private var query = ""
    @State private var showsStopped = true

    private var store: WorkspaceStore { model.workspace }

    private var grouping: ContainerGrouping {
        let filtered = store.containers.filter { container in
            (showsStopped || container.isRunning) && matches(container)
        }
        return ContainerGrouping(filtered)
    }

    private func matches(_ container: Container) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()
        return container.name.lowercased().contains(needle)
            || container.image.lowercased().contains(needle)
            || (container.project?.lowercased().contains(needle) ?? false)
    }

    var body: some View {
        Group {
            if !store.isLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.containers.isEmpty {
                ContentUnavailableView("No containers", systemImage: "shippingbox",
                                       description: Text("Run one with `docker run`, or bring a project up with `docker compose up`."))
            } else {
                list
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Filter containers")
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showsStopped) {
                    Label("Show stopped", systemImage: showsStopped ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .help(showsStopped ? "Hide stopped containers" : "Show stopped containers")
            }
        }
    }

    private var subtitle: String {
        let running = store.containers.filter(\.isRunning).count
        return "\(running) running · \(store.containers.count) total"
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(grouping.projects) { project in
                Section {
                    ForEach(project.containers) { container in
                        ContainerRow(container: container).tag(container.id)
                    }
                } header: {
                    ProjectHeader(project: project)
                }
            }
            if !grouping.standalone.isEmpty {
                Section(grouping.projects.isEmpty ? "" : "Standalone") {
                    ForEach(grouping.standalone) { container in
                        ContainerRow(container: container).tag(container.id)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct ProjectHeader: View {
    @Environment(EngineModel.self) private var model
    let project: Project

    var body: some View {
        HStack(spacing: Metric.tight) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.blue)
            Text(project.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Pill("\(project.runningCount)/\(project.containers.count)",
                 tint: project.isFullyUp ? .green : .secondary)
            Spacer()
            Menu {
                Button("Start all") { act(model.workspace.start) }
                Button("Restart all") { act { for c in project.containers { await model.workspace.restart(c) } } }
                Button("Stop all") { act(model.workspace.stop) }
                Divider()
                Button("Remove all", role: .destructive) { act(model.workspace.remove) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func act(_ action: @escaping ([Container]) async -> Void) {
        Task { await action(project.containers) }
    }

    private func act(_ action: @escaping () async -> Void) {
        Task { await action() }
    }
}

private struct ContainerRow: View {
    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var hovering = false

    private var isBusy: Bool { model.workspace.busy.contains(container.id) }

    var body: some View {
        HStack(spacing: Metric.snug) {
            StatusDot(state: container.state, health: container.health)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.service ?? container.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Metric.tight)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if hovering {
                actions
            } else {
                ports
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var ports: some View {
        HStack(spacing: 4) {
            if let health = container.health {
                Image(systemName: health.symbol).font(.caption2).foregroundStyle(health.tint)
            }
            ForEach(container.publishedPorts.prefix(2), id: \.hostPort) { port in
                Pill("\(port.hostPort ?? 0)", tint: .accentColor)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            if container.isRunning {
                iconButton("stop.fill", "Stop") { await model.workspace.stop(container) }
                iconButton("arrow.clockwise", "Restart") { await model.workspace.restart(container) }
            } else {
                iconButton("play.fill", "Start") { await model.workspace.start(container) }
            }
            iconButton("trash", "Remove") { await model.workspace.remove(container) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if container.isRunning {
            Button("Stop") { Task { await model.workspace.stop(container) } }
            Button("Restart") { Task { await model.workspace.restart(container) } }
            Button("Force kill") { Task { await model.workspace.kill(container) } }
        } else {
            Button("Start") { Task { await model.workspace.start(container) } }
        }
        Divider()
        ForEach(container.publishedPorts, id: \.hostPort) { port in
            if let host = port.hostPort, let url = URL(string: "http://localhost:\(host)") {
                Button("Open localhost:\(host)") { NSWorkspace.shared.open(url) }
            }
        }
        Button("Copy container ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        }
        Divider()
        Button("Remove", role: .destructive) { Task { await model.workspace.remove(container) } }
    }

    private func iconButton(_ symbol: String, _ help: String,
                            _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
