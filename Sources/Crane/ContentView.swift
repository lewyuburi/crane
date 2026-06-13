import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case containers, images, volumes, networks, storage, runtimes
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var group: String {
        switch self {
        case .containers, .images, .volumes, .networks: return "Containers"
        case .storage, .runtimes: return "System"
        }
    }

    static var groups: [(name: String, items: [SidebarItem])] {
        let order = ["Containers", "System"]
        return order.map { name in (name, allCases.filter { $0.group == name }) }
            .filter { !$0.items.isEmpty }
    }
    var systemImage: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .storage: return "internaldrive"
        case .runtimes: return "cpu"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .containers
    @State private var containerSelection = Set<Container.ID>()
    @State private var tab: DetailTab = .info

    var body: some View {
        if (selection ?? .containers) == .containers {
            // Containers gets a true 3-column layout: sidebar · narrow list · wide
            // detail. Each column owns its toolbar zone (native, Liquid Glass).
            // `.prominentDetail` keeps the detail dominant so the list column width
            // stays constant whether or not a container is selected.
            NavigationSplitView {
                sidebar
            } content: {
                ContainersListColumn(selection: $containerSelection, tab: $tab)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
            } detail: {
                ContainerDetailColumn(selection: containerSelection, tab: $tab)
            }
            .navigationSplitViewStyle(.prominentDetail)
        } else {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.items) { item in
                        Label {
                            HStack {
                                Text(item.title)
                                Spacer()
                                if let count = count(for: item) {
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        } icon: {
                            Image(systemName: item.systemImage)
                        }
                        .tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        .navigationTitle("Crane")
    }

    private func count(for item: SidebarItem) -> Int? {
        switch item {
        case .containers: return model.isSystemRunning ? model.containers.count : nil
        case .images: return model.images.isEmpty ? nil : model.images.count
        case .volumes: return model.volumes.isEmpty ? nil : model.volumes.count
        case .networks: return model.networks.isEmpty ? nil : model.networks.count
        case .runtimes: return model.runtimes.isEmpty ? nil : model.runtimes.count
        case .storage: return nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .containers {
        case .containers:
            ContainersListColumn(selection: $containerSelection, tab: $tab)  // not reached (handled above)
        case .images:
            ImagesView()
        case .volumes:
            VolumesView()
        case .networks:
            NetworksView()
        case .storage:
            StorageView()
        case .runtimes:
            RuntimesView()
        }
    }
}

struct ComingSoonView: View {
    let title: String
    var body: some View {
        ContentUnavailableView(
            "\(title) coming soon",
            systemImage: "hammer",
            description: Text("This section isn't wired up yet.")
        )
        .navigationTitle(title)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}
