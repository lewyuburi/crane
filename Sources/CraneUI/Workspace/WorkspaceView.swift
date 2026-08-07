import CraneCore
import SwiftUI

/// The sections of the app.
enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable {
    case containers, images, volumes, networks, engine

    var id: String { rawValue }

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

/// The main window once the engine is up: sidebar, list, detail.
public struct WorkspaceView: View {
    @Environment(EngineModel.self) private var model
    @State private var section: WorkspaceSection = .containers
    @State private var selection: Container.ID?

    public init() {}

    private var store: WorkspaceStore { model.workspace }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 520)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .task { await store.reloadAll() }
        .overlay(alignment: .bottom) {
            if let failure = store.failure ?? model.failure {
                Banner(message: failure) {
                    store.failure = nil
                    model.failure = nil
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            ForEach(["Workspace", "System"], id: \.self) { group in
                Section(group) {
                    ForEach(WorkspaceSection.allCases.filter { $0.group == group }) { item in
                        Label {
                            HStack {
                                Text(item.title)
                                Spacer()
                                if let count = count(for: item) {
                                    Text("\(count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: item.symbol)
                        }
                        .tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        .navigationTitle("Crane")
        .safeAreaInset(edge: .bottom) { EngineBadge() }
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

    @ViewBuilder
    private var content: some View {
        switch section {
        case .containers: ContainerListView(selection: $selection)
        case .images: ImagesView()
        case .volumes: VolumesView()
        case .networks: NetworksView()
        case .engine: DiagnosticsView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if section == .containers {
            if let id = selection, let container = store.catalog[id] {
                ContainerDetailView(container: container)
                    .id(container.id)
            } else {
                ContentUnavailableView("No selection", systemImage: "shippingbox",
                                       description: Text("Pick a container to see its logs, stats and shell."))
            }
        } else {
            ContentUnavailableView("Nothing selected", systemImage: section.symbol)
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

/// Error surface that doesn't steal focus: it sits at the bottom until dismissed.
struct Banner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Metric.snug) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: Metric.snug)
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(Metric.snug)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
        .shadow(radius: 6, y: 2)
        .padding(Metric.regular)
    }
}
