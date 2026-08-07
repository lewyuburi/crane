import AppKit
import CraneCore
import DockerAPI
import SwiftUI

/// The detail pane for one container.
struct ContainerDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", stats = "Stats", logs = "Logs", terminal = "Terminal"
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
                identity
                summary
                if !container.publishedPorts.isEmpty { ports }
                if let detail, !detail.mounts.isEmpty { mounts(detail) }
                if let detail, !detail.config.environment.isEmpty { environment(detail) }
                if !container.labels.isEmpty { labels }
            }
            .padding(Metric.loose)
            .frame(maxWidth: Metric.detailWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: container.id) { detail = await model.workspace.detail(container.id) }
    }

    private var identity: some View {
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
    }

    private var summary: some View {
        InfoTable(rows: summaryRows)
    }

    private var summaryRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Status", statusText),
            ("Container ID", String(container.id.prefix(12))),
        ]
        if let project = container.project {
            rows.append(("Compose project", project))
            if let service = container.service { rows.append(("Service", service)) }
        }
        if let address = container.addresses.values.sorted().first { rows.append(("Address", address)) }
        if let policy = detail?.restartPolicy { rows.append(("Restart policy", policy)) }
        if let detail, detail.restartCount > 0 { rows.append(("Restarts", "\(detail.restartCount)")) }
        if let workdir = detail?.config.workingDirectory, !workdir.isEmpty {
            rows.append(("Working directory", workdir))
        }
        rows.append(("Created", container.created.formatted(date: .abbreviated, time: .shortened)))
        return rows
    }

    private var statusText: String {
        var text = container.statusText.isEmpty ? container.state.label : container.statusText
        if let health = container.health { text += " · \(health.rawValue)" }
        return text
    }

    private var ports: some View {
        Block("Ports") {
            InfoTable(columns: ("Host", "Container"), rows: container.publishedPorts.map { port in
                ("localhost:\(port.hostPort ?? 0)", "\(port.containerPort)/\(port.proto)")
            }, link: { row in URL(string: "http://\(row.0)") })
        }
    }

    private func mounts(_ detail: ContainerDetail) -> some View {
        Block("Mounts") {
            InfoTable(columns: ("Source", "Destination"),
                      rows: detail.mounts.map { mount in
                          (mount.name ?? abbreviate(mount.source),
                           mount.destination + (mount.readOnly ? "  (ro)" : ""))
                      })
        }
    }

    private func environment(_ detail: ContainerDetail) -> some View {
        Block("Environment") {
            InfoTable(columns: ("Variable", "Value"), rows: detail.config.environment.map { entry in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                return (parts.first ?? entry, parts.count > 1 ? parts[1] : "")
            })
        }
    }

    private var labels: some View {
        Block("Labels") {
            InfoTable(columns: ("Key", "Value"),
                      rows: container.labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        }
    }

    /// Home-relative paths read better than absolute ones, and they're what the user typed.
    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count - 1) : path
    }
}

/// A titled group in the detail pane.
private struct Block<Content: View>: View {
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

/// Two aligned columns with hairlines and alternating rows — the shape every table in a Mac app
/// takes, built with `Grid` so it lives inside a scroll view without nesting another one.
private struct InfoTable: View {
    var columns: (String, String)?
    let rows: [(String, String)]
    var link: ((String, String)) -> URL? = { _ in nil }

    init(columns: (String, String)? = nil, rows: [(String, String)],
         link: @escaping ((String, String)) -> URL? = { _ in nil }) {
        self.columns = columns
        self.rows = rows
        self.link = link
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            if let columns {
                GridRow {
                    header(columns.0)
                    header(columns.1)
                }
                Divider().gridCellColumns(2)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 || columns == nil {
                    if index > 0 { Divider().gridCellColumns(2) }
                }
                GridRow {
                    Text(row.0)
                        .foregroundStyle(columns == nil ? .secondary : .primary)
                        .font(columns == nil ? .body : .system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, Metric.snug)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    value(row)
                        .padding(.horizontal, Metric.snug)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: columns == nil ? .trailing : .leading)
                }
                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private func value(_ row: (String, String)) -> some View {
        if let url = link(row) {
            Link(row.1, destination: url).font(.system(.callout, design: .monospaced))
        } else {
            Text(row.1)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.1)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metric.snug)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
