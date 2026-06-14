import SwiftUI
import CraneKit
import AppKit
import UniformTypeIdentifiers

/// The middle column: the container list with its own toolbar zone (run/refresh +
/// bulk actions on the multi-selection).
struct ContainersListColumn: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<Container.ID>
    @Binding var tab: DetailTab
    @State private var showingRun = false
    @State private var collapsed = Set<String>()

    private func expanded(_ name: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(name) },
                set: { isOpen in
                    if isOpen { collapsed.remove(name) } else { collapsed.insert(name) }
                })
    }

    private var selected: [Container] { model.containers.filter { selection.contains($0.id) } }
    private var standalone: [Container] { model.containers.filter { $0.composeProject == nil } }

    /// Compose groups to show: added projects (even when down) plus any project that
    /// only exists as running containers (e.g. started outside the saved list).
    private var composeGroups: [(name: String, ref: ComposeProjectRef?)] {
        let refs = model.composeProjects
        let refNames = Set(refs.map(\.projectName))
        let containerOnly = Set(model.containers.compactMap(\.composeProject))
            .subtracting(refNames).sorted()
        return refs.map { ($0.projectName, Optional($0)) } + containerOnly.map { ($0, nil) }
    }

    private var isEmpty: Bool {
        model.containers.isEmpty && model.composeProjects.isEmpty && !model.isLoading
    }

    var body: some View {
        listContent
            .navigationTitle("Containers")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Bulk actions only for a multi-selection; a single container is
                    // managed from its row (hover) and the detail pane.
                    if selection.count > 1 {
                        if selected.contains(where: { !$0.isRunning }) {
                            Button { bulk(model.bulkStart) } label: { Label("Start", systemImage: "play.fill") }
                        }
                        if selected.contains(where: { $0.isRunning }) {
                            Button { bulk(model.bulkStop) } label: { Label("Stop", systemImage: "stop.fill") }
                        }
                        Button(role: .destructive) { bulk(model.bulkDelete) } label: {
                            Label("Delete \(selection.count)", systemImage: "trash")
                        }
                        Divider()
                    }
                    Button { showingRun = true } label: { Label("Run a container", systemImage: "plus") }
                        .disabled(!model.isSystemRunning)
                    Button { addCompose() } label: { Label("Add Compose…", systemImage: "square.stack.3d.down.right") }
                    Button { Task { await model.refreshContainers() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                }
            }
            .sheet(isPresented: $showingRun) { RunContainerView() }
            .overlay(alignment: .bottom) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error) { model.errorMessage = nil }
                }
            }
            .task {
                // Poll status while the containers view is visible so a container that
                // fails/exits after launch stops showing as running.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    await model.pollContainers()
                }
            }
    }

    private func addCompose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.yaml, UTType(filenameExtension: "yml") ?? .yaml, .data]
        panel.message = "Select a docker-compose.yml or compose.yaml"
        if panel.runModal() == .OK, let url = panel.url {
            model.addComposeProject(url: url)
        }
    }

    private var subtitle: String {
        if selection.count > 1 { return "\(selection.count) of \(model.containers.count) selected" }
        return model.isSystemRunning ? "\(model.containers.count) running" : ""
    }

    private func bulk(_ action: @escaping ([String]) async -> Void) {
        let ids = Array(selection)
        Task { await action(ids) }
    }

    @ViewBuilder
    private var listContent: some View {
        if !model.isInstalled {
            NotInstalledView()
        } else if !model.isSystemRunning {
            SystemStoppedView()
        } else if isEmpty {
            ContentUnavailableView {
                Label("No containers", systemImage: "shippingbox")
            } description: {
                Text("Run a container, or add a Compose project with the toolbar.")
            } actions: {
                Button("Run a container") { showingRun = true }.buttonStyle(.borderedProminent)
            }
        } else {
            // Flat rows (not DisclosureGroup) so every row — group header, child, standalone —
            // gets the List's uniform full-width selection/hover and a consistent trailing
            // action column. DisclosureGroup styled header vs children inconsistently.
            List(selection: $selection) {
                ForEach(rows) { row in
                    switch row {
                    case let .group(name, ref):
                        GroupHeaderRow(project: name, ref: ref, expanded: expanded(name)) {
                            selection = [Self.composeTag(name)]
                            tab = .logs
                            if let ref { Task { await model.composeUp(ref) } }
                        }
                        .tag(Self.composeTag(name))
                    case let .container(c):
                        ContainerListRow(container: c, indented: c.composeProject != nil).tag(c.id)
                    case let .placeholder(project, service, image):
                        ComposeServiceRow(service: service, image: image) {
                            selection = [Self.composeTag(project)]
                            tab = .logs
                            Task { await model.composeUpService(project: project, service: service) }
                        }
                        .selectionDisabled()
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    /// One visual row in the list: a compose-group header, a real container, or a
    /// not-created compose service placeholder.
    private enum Row: Identifiable {
        case group(name: String, ref: ComposeProjectRef?)
        case container(Container)
        case placeholder(project: String, service: String, image: String?)

        var id: String {
            switch self {
            case let .group(name, _): return ContainersListColumn.composeTag(name)
            case let .container(c): return c.id
            case let .placeholder(project, service, _): return "placeholder://\(project)/\(service)"
            }
        }
    }

    /// Flattened rows: each compose group's header, its children (when expanded), then standalone.
    private var rows: [Row] {
        var out: [Row] = []
        for group in composeGroups {
            out.append(.group(name: group.name, ref: group.ref))
            guard expanded(group.name).wrappedValue else { continue }
            for row in serviceRows(group.name) {
                if let c = row.container { out.append(.container(c)) }
                else { out.append(.placeholder(project: group.name, service: row.service, image: row.image)) }
            }
        }
        out.append(contentsOf: standalone.map(Row.container))
        return out
    }

    /// Selection sentinel that makes the inspector show a compose project's detail
    /// (services + live log) instead of a single container.
    nonisolated static func composeTag(_ project: String) -> Container.ID { "compose://\(project)" }

    private struct SvcRow: Identifiable { let id: String; let service: String; let image: String?; let container: Container? }

    /// Rows for a project: one per defined service (container if present, else a
    /// not-created placeholder). Falls back to raw containers if the file isn't parsed.
    private func serviceRows(_ project: String) -> [SvcRow] {
        let services = model.services(forProject: project)
        if !services.isEmpty {
            return services.map { svc in
                let c = model.containers.first { $0.composeProject == project && $0.composeService == svc.name }
                return SvcRow(id: c?.id ?? "\(project)-\(svc.name)", service: svc.name, image: svc.image, container: c)
            }
        }
        return model.containers(inProject: project).map {
            SvcRow(id: $0.id, service: $0.composeService ?? $0.id, image: $0.image, container: $0)
        }
    }
}

/// A compose service that has no container yet (project added but not up'd). Hovering
/// reveals a Start action that creates just this service.
private struct ComposeServiceRow: View {
    let service: String
    let image: String?
    let onStart: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 20)   // align under the group header, like real children
            Circle().fill(Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(service).font(.body.weight(.medium)).foregroundStyle(.secondary)
                Text(image ?? "(build)").font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hovering {
                Button(action: onStart) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).help("Start this service")
            } else {
                Text("not created").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hovering = h } }
    }
}

/// A compose project's header row: chevron + icon + name + count + Up / Down / Remove.
/// A normal List row (not a DisclosureGroup) for consistent full-width selection styling.
private struct GroupHeaderRow: View {
    @Environment(AppModel.self) private var model
    let project: String
    let ref: ComposeProjectRef?
    @Binding var expanded: Bool
    let onUp: () -> Void
    @State private var confirmingDelete = false

    private var running: Int { model.containers(inProject: project).filter(\.isRunning).count }
    private var total: Int { model.services(forProject: project).count }
    private var hasContainers: Bool { !model.containers(inProject: project).isEmpty }
    private var busy: Bool { model.busyComposeProjects.contains(project) }
    /// Every defined service is already running — nothing left to bring up.
    private var allRunning: Bool { total > 0 && running == total }

    var body: some View {
        HStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
            }
            .buttonStyle(.plain)

            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.blue)
            Text(project).font(.body.weight(.semibold))
            if total > 0 {
                Text("\(running)/\(total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                if ref != nil, !allRunning {
                    iconButton("play.fill", "Up (start all services)", action: onUp)
                        .disabled(!model.isSystemRunning)
                }
                if hasContainers {
                    iconButton("stop.fill", "Down (stop & remove)") { Task { await model.composeDown(project) } }
                }
                if ref != nil || hasContainers {
                    iconButton("trash", "Remove project") { confirmingDelete = true }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .confirmationDialog("Remove “\(project)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove project", role: .destructive) {
                Task { await model.deleteComposeProject(project, ref: ref) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hasContainers
                ? "This stops and deletes the project’s containers and removes it from Crane."
                : "This removes the project from Crane.")
        }
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.borderless).help(help)
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case info = "Info", stats = "Stats", logs = "Logs", terminal = "Terminal"
    var id: String { rawValue }
}

// MARK: - Detail column with tabs

/// The trailing (wide) column: the selected container's detail, with the tab
/// switcher in its own toolbar zone.
struct ContainerDetailColumn: View {
    @Environment(AppModel.self) private var model
    let selection: Set<Container.ID>
    @Binding var tab: DetailTab

    /// The single selected container (only when exactly one is selected).
    private var container: Container? {
        guard selection.count == 1, let id = selection.first, !id.hasPrefix("compose://") else { return nil }
        return model.containers.first(where: { $0.id == id })
    }

    /// The selected compose project name (when a group is selected), if any.
    private var composeSelection: String? {
        guard selection.count == 1, let id = selection.first, id.hasPrefix("compose://") else { return nil }
        return String(id.dropFirst("compose://".count))
    }

    var body: some View {
        Group {
            if let container {
                tabContent(for: container)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let project = composeSelection {
                composeTabContent(project)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selection.count > 1 {
                ContentUnavailableView("\(selection.count) containers selected", systemImage: "shippingbox.fill",
                                       description: Text("Use the toolbar to start, stop, or delete them."))
            } else {
                ContentUnavailableView("No Selection", systemImage: "shippingbox",
                                       description: Text("Select a container to see its details."))
            }
        }
        .toolbar {
            // Centered in the inspector column's toolbar zone. Containers get all tabs;
            // compose projects get the relevant ones (Info / Logs).
            ToolbarItem(placement: .principal) {
                if composeSelection != nil {
                    Picker("View", selection: composeTab) {
                        Text("Info").tag(DetailTab.info)
                        Text("Logs").tag(DetailTab.logs)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                } else {
                    Picker("View", selection: $tab) {
                        ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(container == nil)
                }
            }
        }
    }

    /// Tab binding for compose projects, clamped to the two relevant tabs.
    private var composeTab: Binding<DetailTab> {
        Binding(get: { tab == .logs ? .logs : .info }, set: { tab = $0 })
    }

    @ViewBuilder
    private func composeTabContent(_ project: String) -> some View {
        if tab == .logs {
            ComposeLogTab()
        } else {
            ComposeInfoTab(project: project)
        }
    }

    @ViewBuilder
    private func tabContent(for container: Container) -> some View {
        switch tab {
        case .info:
            InfoTab(container: container)
        case .stats:
            if container.isRunning {
                ScrollView { LiveStatsSection(container: container).padding() }
            } else {
                ContentUnavailableView("Not running", systemImage: "pause",
                                       description: Text("Stats are available for running containers."))
            }
        case .logs:
            LogConsoleView(container: container)
        case .terminal:
            if container.isRunning {
                PTYTerminalView {
                    try await ContainerCLI.shared.execInvocation(id: container.id, command: ["/bin/sh"])
                }
                .id(container.id)
            } else {
                ContentUnavailableView("Not running", systemImage: "pause",
                                       description: Text("Start the container to open a shell."))
            }
        }
    }
}

// MARK: - Info tab

private struct InfoTab: View {
    let container: Container

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                KVTable(rows: infoRows)

                ResourcesSection(container: container)

                if !container.ports.isEmpty {
                    DataSection(title: "Port Forwards",
                                columns: ["Host Port", "Container Port", "Protocol"],
                                rows: container.ports.map {
                                    [linkCell("\($0.hostPort)", url: "http://localhost:\($0.hostPort)"),
                                     .text("\($0.containerPort)"), .text($0.proto.uppercased())]
                                })
                }
                if !container.mounts.isEmpty {
                    DataSection(title: "Mounts", columns: ["Source", "Destination"],
                                rows: container.mounts.map {
                                    [.text($0.source + ($0.readOnly ? "  (ro)" : "")), .text($0.destination)]
                                })
                }
                if !container.sortedLabels.isEmpty {
                    DataSection(title: "Labels", columns: ["Key", "Value"],
                                rows: container.sortedLabels.map { [.text($0.key), .text($0.value)] })
                }
            }
            .padding()
        }
    }

    private var infoRows: [(String, Cell)] {
        var rows: [(String, Cell)] = [
            ("Name", .text(container.id)),
            ("Image", .text(container.image)),
            ("Status", .text(container.status.displayName)),
        ]
        if let host = container.hostname { rows.append(("Hostname", .text(host))) }
        if let ip = container.addresses.first { rows.append(("IP", .mono(ip))) }
        if let os = container.os, let arch = container.arch {
            rows.append(("Platform", .text("\(os)/\(arch)")))
        }
        return rows
    }

    private func linkCell(_ text: String, url: String) -> Cell {
        URL(string: url).map { .link(text, $0) } ?? .text(text)
    }
}

/// Editable memory / CPU limits via sliders. Apple `container` sets these only at creation,
/// so a change recreates the container in place (preserving everything else). The sliders
/// drive local values and auto-apply shortly after the drag settles: `.task(id:)` debounces
/// on the chosen value, restarting only when the value changes — so the 3 s status poll, which
/// rebuilds the view, can't interrupt it (the failure mode of an `onEditingChanged` commit).
private struct ResourcesSection: View {
    @Environment(AppModel.self) private var model
    let container: Container

    @State private var memoryMB: Double = 1024
    @State private var cpus: Double = 1

    private var isBusy: Bool { model.busyContainerIDs.contains(container.id) }
    private var hostMB: Double { Double(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
    private var hostCores: Double { Double(ProcessInfo.processInfo.activeProcessorCount) }

    private var currentMB: Int? { container.memoryBytes.map { Int($0 / 1_048_576) } }
    private var dirty: Bool { Int(memoryMB) != (currentMB ?? -1) || Int(cpus) != (container.cpus ?? -1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Resources").font(.headline)
                Spacer()
                if isBusy {
                    Label("Recreating…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
            VStack(spacing: 14) {
                sliderRow(label: "Memory", value: memFormatted(memoryMB),
                          binding: $memoryMB, range: 512...max(hostMB, 1024), step: 512)
                sliderRow(label: "CPUs", value: "\(Int(cpus))",
                          binding: $cpus, range: 1...max(hostCores, 1), step: 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))

            Text("Adjusting a limit recreates the container.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .onAppear(perform: sync)
        .onChange(of: container.id) { sync() }
        // Re-sync from the runtime only when there's no pending edit, so the poll can't
        // stomp a value the user is in the middle of choosing.
        .onChange(of: container.memoryBytes) { if !isBusy && !dirty { sync() } }
        .onChange(of: container.cpus) { if !isBusy && !dirty { sync() } }
        // Debounced auto-apply: re-armed on every value change, so it fires once the slider
        // settles. Unaffected by view rebuilds since the id only tracks the chosen value.
        .task(id: "\(Int(memoryMB))x\(Int(cpus))") {
            guard dirty, !isBusy else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, dirty, !isBusy else { return }
            await model.setResources(container, memory: "\(Int(memoryMB))M", cpus: Int(cpus))
        }
    }

    @ViewBuilder
    private func sliderRow(label: String, value: String, binding: Binding<Double>,
                           range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout.weight(.medium))
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step).disabled(isBusy)
        }
    }

    private func sync() {
        memoryMB = container.memoryBytes.map { Double($0 / 1_048_576) } ?? 1024
        cpus = Double(container.cpus ?? 1)
    }

    private func memFormatted(_ mb: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .memory)
    }
}

// MARK: - Reusable tables

enum Cell {
    case text(String)
    case mono(String)
    case link(String, URL)
}

private struct CellView: View {
    let cell: Cell
    var body: some View {
        switch cell {
        case .text(let s): Text(s).textSelection(.enabled)
        case .mono(let s): Text(s).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        case .link(let s, let u): Link(s, destination: u)
        }
    }
}

/// Key/value list like OrbStack's Info rows, with alternating row backgrounds.
private struct KVTable: View {
    let rows: [(String, Cell)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    CellView(cell: row.1).multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DataSection: View {
    let title: String
    let columns: [String]
    let rows: [[Cell]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(spacing: 0) {
                HStack {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                        Text(c).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)

                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    HStack {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            CellView(cell: cell)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(idx.isMultiple(of: 2) ? Color.primary.opacity(0.035) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - List row

private struct ContainerListRow: View {
    @Environment(AppModel.self) private var model
    let container: Container
    var indented = false
    @State private var hovering = false

    private var isBusy: Bool { model.busyContainerIDs.contains(container.id) }

    var body: some View {
        HStack(spacing: 10) {
            if indented { Spacer().frame(width: 20) }   // nest compose children under their group header
            StatusDot(status: container.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.id).font(.body.weight(.medium))
                Text(container.image).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if hovering {
                HStack(spacing: 6) {
                    if container.isRunning {
                        rowButton("stop.fill", "Stop") { Task { await model.stop(container) } }
                    } else {
                        rowButton("play.fill", "Start") { Task { await model.start(container) } }
                    }
                    rowButton("trash", "Delete", role: .destructive) { Task { await model.delete(container) } }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hovering = h } }
    }

    private func rowButton(_ icon: String, _ help: String, role: ButtonRole? = nil,
                           _ action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { Image(systemName: icon) }.help(help)
    }
}

// MARK: - Live stats

private struct LiveStatsSection: View {
    let container: Container
    @State private var poller: StatsPoller

    init(container: Container) {
        self.container = container
        _poller = State(initialValue: StatsPoller(containerID: container.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live stats").font(.headline)
            MeterRow(label: "CPU", value: poller.cpuPercent / 100,
                     caption: String(format: "%.1f%%", poller.cpuPercent), tint: .blue)
            if let s = poller.latest {
                MeterRow(label: "Memory", value: s.memoryFraction,
                         caption: "\(byteString(s.memoryUsageBytes)) / \(byteString(s.memoryLimitBytes))",
                         tint: .green)
                HStack {
                    StatBadge(icon: "arrow.down", text: byteString(s.networkRxBytes))
                    StatBadge(icon: "arrow.up", text: byteString(s.networkTxBytes))
                    StatBadge(icon: "internaldrive", text: byteString(s.blockReadBytes + s.blockWriteBytes))
                    StatBadge(icon: "number", text: "\(s.numProcesses) proc")
                }
            } else {
                Text("Sampling…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { poller.start() }
        .onDisappear { poller.stop() }
        .id(container.id)
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .memory)
    }
}

private struct MeterRow: View {
    let label: String
    let value: Double
    let caption: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption.weight(.medium))
                Spacer()
                Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(max(value, 0), 1)).tint(tint)
        }
    }
}

private struct StatBadge: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Status visuals

private struct StatusDot: View {
    let status: ContainerStatus
    var body: some View {
        Circle().fill(status.tint).frame(width: 9, height: 9)
            .overlay(Circle().stroke(status.tint.opacity(0.3), lineWidth: 3))
    }
}

private struct StatusPill: View {
    let status: ContainerStatus
    var body: some View {
        Text(status.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(status.tint)
    }
}

// MARK: - Empty / system states

private struct SystemStoppedView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "power").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Container system is stopped").font(.title2.bold())
            Text("Start the container service to manage containers. The first start downloads the default Linux kernel, which can take a moment.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button {
                Task { await model.startSystem() }
            } label: {
                if model.isStartingSystem {
                    HStack { ProgressView().controlSize(.small); Text("Starting…") }
                } else { Text("Start system") }
            }
            .buttonStyle(.glassProminent).disabled(model.isStartingSystem)
        }
        .padding(40)
    }
}

private struct NotInstalledView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No runtime installed").font(.title2.bold())
            Text("Crane drives Apple's `container` tool. Install a runtime from the Runtimes tab, or install Apple's `.pkg`.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack {
                Link("Get container", destination: URL(string: "https://github.com/apple/container")!)
                    .buttonStyle(.glassProminent)
                Button("Recheck") { Task { await model.refreshContainers() } }
            }
        }
        .padding(40)
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout).lineLimit(3)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding().shadow(radius: 4)
    }
}

/// Inspector "Info" tab for a compose project: header + services with status.
private struct ComposeInfoTab: View {
    @Environment(AppModel.self) private var model
    let project: String

    private var ref: ComposeProjectRef? { model.composeProjects.first { $0.projectName == project } }
    private var services: [ComposeService] { model.services(forProject: project) }
    private var busy: Bool { model.busyComposeProjects.contains(project) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.title).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project).font(.title3.bold())
                        if let path = ref?.path {
                            Text(path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Services").font(.headline)
                    ForEach(services) { svc in
                        let c = model.containers.first { $0.composeProject == project && $0.composeService == svc.name }
                        HStack(spacing: 8) {
                            Circle().fill((c?.status ?? .stopped).tint).frame(width: 8, height: 8)
                            Text(svc.name)
                            Text(svc.image ?? "(build)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(c?.status.displayName ?? "not created")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

/// Inspector "Logs" tab for a compose project: the live `up`/`down` output.
private struct ComposeLogTab: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            Text(model.composeLog.isEmpty ? "No output yet — press ▶ Up on the project." : model.composeLog)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(model.composeLog.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
