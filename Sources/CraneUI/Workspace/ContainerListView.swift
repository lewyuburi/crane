import AppKit
import CraneCore
import SwiftUI

/// The container list: Compose projects as collapsible groups, loose containers below.
///
/// Every row shows the same three things in the same places — image tile with its state, name
/// over image tag, and a fixed slot on the right for ports and actions — so scanning down the
/// list never requires re-reading the layout.
struct ContainerListView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Container.ID?
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var collapsed: Set<String> = []

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
            } else if grouping.projects.isEmpty && grouping.standalone.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                list
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter")
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Filter by state")
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.containers.count)
    }

    private var subtitle: String {
        let running = store.containers.filter(\.isRunning).count
        return running == 0 ? "None running" : "\(running) of \(store.containers.count) running"
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(grouping.projects) { project in
                ProjectSection(project: project,
                               isExpanded: expansion(for: project.name))
            }
            if !grouping.standalone.isEmpty {
                Section {
                    ForEach(grouping.standalone) { container in
                        ContainerRow(container: container).tag(container.id)
                    }
                } header: {
                    if !grouping.projects.isEmpty { Text("Standalone") }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 38)
    }

    private func expansion(for project: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(project) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(project) } else { collapsed.insert(project) }
            })
    }
}

/// A Compose project and its services, collapsible like a folder.
private struct ProjectSection: View {
    @Environment(EngineModel.self) private var model
    let project: Project
    @Binding var isExpanded: Bool
    @State private var hovering = false

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(project.containers) { container in
                ContainerRow(container: container).tag(container.id)
            }
        } header: {
            HStack(spacing: Metric.tight) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(project.isFullyUp ? Color.accentColor : .secondary)
                    .symbolRenderingMode(.hierarchical)
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(project.runningCount)/\(project.containers.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: Metric.tight)
                if hovering {
                    if project.runningCount < project.containers.count {
                        HeaderButton("play.fill", "Start every service") {
                            await model.workspace.start(project.containers)
                        }
                    }
                    if project.runningCount > 0 {
                        HeaderButton("stop.fill", "Stop every service") {
                            await model.workspace.stop(project.containers)
                        }
                    }
                    HeaderButton("trash", "Remove every container in this project") {
                        await model.workspace.remove(project.containers)
                    }
                }
            }
            .padding(.vertical, 1)
            .contentShape(.rect)
            .onHover { hovering = $0 }
        }
    }
}

private struct HeaderButton: View {
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
            Image(systemName: symbol).font(.caption)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct ContainerRow: View {
    @Environment(EngineModel.self) private var model
    let container: Container
    @State private var hovering = false

    private var isBusy: Bool { model.workspace.busy.contains(container.id) }

    var body: some View {
        HStack(spacing: Metric.snug) {
            ContainerAvatar(image: container.image, state: container.state, health: container.health)
            VStack(alignment: .leading, spacing: 0) {
                Text(container.service ?? container.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(shortImage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Metric.tight)
            trailing
        }
        .padding(.vertical, 2)
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
                    RowButton("stop.fill", "Stop") { await model.workspace.stop(container) }
                    RowButton("arrow.clockwise", "Restart") { await model.workspace.restart(container) }
                } else {
                    RowButton("play.fill", "Start") { await model.workspace.start(container) }
                }
                RowButton("trash", "Remove") { await model.workspace.remove(container) }
            }
        } else if let port = container.publishedPorts.first?.hostPort {
            Text(":\(String(port))")
                .font(.system(size: 10.5, design: .monospaced))
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

private struct RowButton: View {
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
