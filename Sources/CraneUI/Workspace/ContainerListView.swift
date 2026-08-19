import AppKit
import CraneCore
import SwiftUI

/// Compose projects as outline rows, then loose containers — `List(children:)` is the SwiftUI outline.
struct ContainerListView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: WorkspaceItem?
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", running = "Running", stopped = "Stopped"
        var id: String { rawValue }

        func accepts(_ container: Container) -> Bool {
            switch self {
            case .all: return true
            case .running: return container.isRunning
            case .stopped: return !container.isRunning
            }
        }
    }

    private var store: WorkspaceStore { model.workspace }

    private var grouping: ContainerGrouping {
        ContainerGrouping(store.containers.filter { filter.accepts($0) && matches($0) })
    }

    private var outline: [OutlineItem] {
        grouping.projects.map(OutlineItem.project)
            + grouping.standalone.map { OutlineItem.container($0) }
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
                                       description: Text("From a project folder run `docker compose up -d`. Install the CLI pack under Engine if `docker` isn’t on PATH."))
            } else if grouping.projects.isEmpty && grouping.standalone.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(outline, children: \.children, selection: $selection) { item in
                    if let project = item.project {
                        ProjectRow(project: project)
                    } else if let container = item.container {
                        ContainerRow(container: container)
                    }
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 34)
            }
        }
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
        .safeAreaInset(edge: .top, spacing: 0) { ColumnFilter(text: $query) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Filter by state")
            }
        }
    }

    private var subtitle: String {
        let running = store.containers.filter(\.isRunning).count
        return running == 0 ? "None running" : "\(running) of \(store.containers.count) running"
    }
}

private struct OutlineItem: Identifiable, Hashable {
    let id: WorkspaceItem
    let project: Project?
    let container: Container?
    let children: [OutlineItem]?

    static func project(_ project: Project) -> OutlineItem {
        OutlineItem(id: .project(project.name), project: project, container: nil,
                    children: project.containers.map { container($0) })
    }

    static func container(_ container: Container) -> OutlineItem {
        OutlineItem(id: .container(container.id), project: nil, container: container, children: nil)
    }
}

private struct ProjectRow: View {
    @Environment(EngineModel.self) private var model
    let project: Project
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Metric.snug) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(project.isFullyUp ? Color.accentColor : .secondary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(project.runningCount) of \(project.containers.count) running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Metric.tight)
            if hovering {
                if project.runningCount < project.containers.count {
                    IconButton("play.fill", "Start every service") {
                        await model.workspace.start(project.containers)
                    }
                }
                if project.runningCount > 0 {
                    IconButton("stop.fill", "Stop every service") {
                        await model.workspace.stop(project.containers)
                    }
                }
                IconButton("trash", "Remove every container in this project") {
                    await model.workspace.remove(project.containers)
                }
            }
        }
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
    }
}

private struct ContainerRow: View {
    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var hovering = false

    private var isBusy: Bool { model.workspace.busy.contains(container.id) }

    var body: some View {
        HStack(spacing: Metric.snug) {
            ContainerAvatar(image: container.image, state: container.state,
                            health: container.health, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.service ?? container.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(shortImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Metric.tight)
            trailing
        }
        .padding(.vertical, 1)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    /// The registry prefix is noise in a list — `docker.io/library/` on every row tells nobody
    /// anything. The full reference is one click away in Info.
    private var shortImage: String {
        var text = container.image
        for prefix in ["docker.io/library/", "docker.io/", "ghcr.io/", "registry.hub.docker.com/"] {
            if text.hasPrefix(prefix) { text.removeFirst(prefix.count); break }
        }
        return text
    }

    /// Ports and actions share one trailing slot, so nothing shifts when the pointer arrives.
    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else if hovering {
            HStack(spacing: 1) {
                if container.isRunning {
                    IconButton("stop.fill", "Stop") { await model.workspace.stop(container) }
                    IconButton("arrow.clockwise", "Restart") { await model.workspace.restart(container) }
                } else {
                    IconButton("play.fill", "Start") { await model.workspace.start(container) }
                }
                IconButton("trash", "Remove") { await model.workspace.remove(container) }
            }
        } else if let port = container.publishedPorts.first?.hostPort {
            Text(verbatim: ":\(port)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
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
        if !container.publishedPorts.isEmpty {
            Divider()
            ForEach(container.publishedPorts, id: \.hostPort) { port in
                if let host = port.hostPort, let url = URL(string: "http://localhost:\(host)") {
                    Button("Open localhost:\(host)") { NSWorkspace.shared.open(url) }
                }
            }
        }
        Divider()
        Button("Copy container ID") { copy(container.id) }
        Button("Copy image") { copy(container.image) }
        Divider()
        Button("Remove", role: .destructive) { Task { await model.workspace.remove(container) } }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () async -> Void

    init(_ symbol: String, _ help: String, action: @escaping () async -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 20, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
