import CraneCore
import DockerAPI
import SwiftUI
import TipKit

/// The sections of the app.
public enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable {
    case containers, images, volumes, networks, engine

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .engine: return "Engine"
        }
    }

    var symbol: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .engine: return "gauge.with.dots.needle.33percent"
        }
    }

    var group: String { self == .engine ? "System" : "Workspace" }
}

/// What the container list and its detail pane are looking at.
public enum WorkspaceItem: Hashable {
    case project(String)
    case container(Container.ID)
}

/// The main window once the engine is up: sidebar, list, detail.
public struct WorkspaceView: View {
    @Environment(EngineModel.self) private var model
    @State private var section: WorkspaceSection
    @State private var selection: WorkspaceItem?
    @State private var imageSelection = Set<ImageSummary.ID>()
    @State private var volumeSelection = Set<VolumeSummary.ID>()
    @State private var networkSelection = Set<NetworkSummary.ID>()

    /// `selection` is a parameter so a window can open on a specific row — restored state,
    /// a notification, or a snapshot that needs the detail pane populated.
    public init(section: WorkspaceSection = .containers, selection: WorkspaceItem? = nil) {
        _section = State(initialValue: section)
        _selection = State(initialValue: selection)
    }

    private var store: WorkspaceStore { model.workspace }

    public var body: some View {
        split
            .navigationSplitViewStyle(.balanced)
            // Only the first appearance loads: after that the event feed keeps the store current,
            // and reloading on every window would undo that.
            .task { if !model.previewLocked, !store.isLoaded { await store.reloadAll() } }
            .overlay(alignment: .bottom) {
                if let failure = store.failure ?? model.failure {
                    Banner(message: failure) {
                        store.failure = nil
                        model.failure = nil
                    }
                } else if model.shouldOfferCLITip {
                    CLIOfferOverlay()
                }
            }
    }

    /// Containers, images, volumes and networks share the three-column split: a list, then a
    /// detail Form. Engine is a Settings page and only needs the sidebar.
    @ViewBuilder
    private var split: some View {
        if section == .engine {
            NavigationSplitView {
                WorkspaceSidebar(section: $section)
            } detail: {
                EngineView()
            }
        } else {
            NavigationSplitView {
                WorkspaceSidebar(section: $section)
            } content: {
                resourceList
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
            } detail: {
                resourceDetail
            }
        }
    }

    @ViewBuilder
    private var resourceList: some View {
        switch section {
        case .containers: ContainerListView(selection: $selection)
        case .images: ImagesView(selection: $imageSelection)
        case .volumes: VolumesView(selection: $volumeSelection)
        case .networks: NetworksView(selection: $networkSelection)
        case .engine: EmptyView()
        }
    }

    @ViewBuilder
    private var resourceDetail: some View {
        switch section {
        case .containers: containerDetail
        case .images: ImageDetailView(selection: $imageSelection)
        case .volumes: VolumeDetailView(selection: $volumeSelection)
        case .networks: NetworkDetailView(selection: $networkSelection)
        case .engine: EmptyView()
        }
    }

    @ViewBuilder
    private var containerDetail: some View {
        switch selection {
        case let .container(id):
            if let container = store.catalog[id] {
                ContainerDetailView(container: container).id(container.id)
            } else {
                ContentUnavailableView("No selection", systemImage: "shippingbox",
                                       description: Text("Pick a stack or a container."))
            }
        case let .project(name):
            if let project = store.grouping.projects.first(where: { $0.name == name }) {
                ProjectDetailView(project: project, selection: $selection).id(project.name)
            } else {
                ContentUnavailableView("No selection", systemImage: "square.stack.3d.up",
                                       description: Text("Pick a stack or a container."))
            }
        case nil:
            ContentUnavailableView("No selection", systemImage: "shippingbox",
                                   description: Text("Pick a stack or a container."))
        }
    }
}

/// The first column: where in the app you are, and whether the engine is up.
struct WorkspaceSidebar: View {
    @Environment(EngineModel.self) private var model
    @Binding var section: WorkspaceSection

    private var store: WorkspaceStore { model.workspace }

    var body: some View {
        List(selection: $section) {
            ForEach(["Workspace", "System"], id: \.self) { group in
                Section(group) {
                    ForEach(WorkspaceSection.allCases.filter { $0.group == group }) { item in
                        sidebarRow(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        .navigationTitle("Crane")
        .safeAreaInset(edge: .bottom) { EngineBadge() }
    }

    @ViewBuilder
    private func sidebarRow(_ item: WorkspaceSection) -> some View {
        if let n = count(for: item) {
            Label(item.title, systemImage: item.symbol).badge(n).tag(item)
        } else {
            Label(item.title, systemImage: item.symbol).tag(item)
        }
    }

    private func count(for section: WorkspaceSection) -> Int? {
        switch section {
        case .containers: return store.containers.isEmpty ? nil : store.containers.count
        case .images: return store.images.isEmpty ? nil : store.images.count
        case .volumes: return store.volumes.isEmpty ? nil : store.volumes.count
        case .networks: return store.networks.isEmpty ? nil : store.networks.count
        case .engine: return nil
        }
    }
}

/// A quiet footer that says the engine is alive and what it's made of.
private struct EngineBadge: View {
    @Environment(EngineModel.self) private var model

    var body: some View {
        HStack(spacing: Metric.tight) {
            Circle()
                .fill(model.phase == .ready ? Color.green : .orange)
                .frame(width: 6, height: 6)
            Text(model.phase == .ready ? "Engine running" : "Engine needs attention")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Metric.snug)
        .padding(.vertical, Metric.tight)
        .help(CraneVersion.stackSummary)
    }
}

/// TipKit offer for the CLI pack — not the error banner.
private struct CLIOfferOverlay: View {
    @Environment(EngineModel.self) private var model
    private let tip = DockerCLIPTip()

    var body: some View {
        TipView(tip) { action in
            if action.id == "install" {
                Task { await model.provisionCLI() }
            }
            tip.invalidate(reason: .actionPerformed)
        }
        .padding(Metric.regular)
        .frame(maxWidth: 420)
    }
}

/// Error surface that doesn't steal focus: it floats at the bottom until dismissed.
struct Banner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Metric.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .symbolRenderingMode(.hierarchical)
            Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: Metric.snug)
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, Metric.regular)
        .padding(.vertical, Metric.snug)
        .glassEffect(.regular, in: .capsule)
        .padding(Metric.regular)
    }
}

#Preview("Workspace") {
    CranePreview.window(
        WorkspaceView().environment(CranePreview.model()))
}

#Preview("Workspace · container selected") {
    CranePreview.window(
        WorkspaceView(selection: .container("a1b2c3d4e5f6")).environment(CranePreview.model()))
}

#Preview("Workspace · empty") {
    CranePreview.window(
        WorkspaceView().environment(CranePreview.model(fillWorkspace: false)))
}

#Preview("Workspace · stack selected") {
    CranePreview.window(
        WorkspaceView(selection: .project("shop")).environment(CranePreview.model()))
}

#Preview("Workspace · images") {
    CranePreview.window(
        WorkspaceView(section: .images).environment(CranePreview.model()))
}

#Preview("Workspace · volumes") {
    CranePreview.window(
        WorkspaceView(section: .volumes).environment(CranePreview.model()))
}

#Preview("Workspace · networks") {
    CranePreview.window(
        WorkspaceView(section: .networks).environment(CranePreview.model()))
}

#Preview("Workspace · engine") {
    CranePreview.window(
        WorkspaceView(section: .engine).environment(CranePreview.model()))
}
