import AppKit
import CraneCore
import DockerAPI
import SwiftUI

/// Images: what's on disk, how big, and what's using it.
struct ImagesView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Set<ImageSummary.ID>
    @State private var sortOrder = [KeyPathComparator(\ImageSummary.displayName)]
    @State private var query = ""
    @State private var pullReference = ""
    @State private var isPulling = false
    @State private var pullStatus = ""

    private var store: WorkspaceStore { model.workspace }

    private var images: [ImageSummary] {
        store.images.filter { image in
            query.isEmpty
                || image.displayName.localizedStandardContains(query)
                || image.id.localizedStandardContains(query)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if store.images.isEmpty {
                ContentUnavailableView("No images", systemImage: "square.stack.3d.up",
                                       description: Text("Pull one below, or run a container and let the daemon fetch it."))
                    .paneEmptyState()
            } else if images.isEmpty {
                ContentUnavailableView.search(text: query)
                    .paneEmptyState()
            } else {
                Table(images, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Image", value: \.displayName) { image in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(image.displayName).lineLimit(1).truncationMode(.middle)
                            if image.containers > 0 {
                                Text("In use by \(image.containers)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("Size", value: \.size) { image in
                        Text(byteString(image.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(90)
                    TableColumn("Created", value: \.created) { image in
                        Text(image.created.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                    .width(140)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: ImageSummary.ID.self) { ids in
                    Button("Remove", role: .destructive) { remove(ids) }
                }
            }
        }
        .navigationTitle("Images")
        .navigationSubtitle(store.images.isEmpty ? "" : "\(store.images.count) · \(byteString(totalSize))")
        .safeAreaBar(edge: .top, spacing: 0) { ColumnFilter(text: $query) }
        .safeAreaInset(edge: .bottom) { pullBar }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !selection.isEmpty {
                    Button("Remove", role: .destructive) { remove(selection) }
                }
                Button("Prune unused") { Task { await store.pruneImages() } }
            }
        }
    }

    private var totalSize: Int64 { store.images.reduce(0) { $0 + $1.size } }

    private var pullBar: some View {
        HStack(spacing: Metric.snug) {
            TextField("Pull an image, e.g. postgres:17-alpine", text: $pullReference)
                .textFieldStyle(.roundedBorder)
                .onSubmit(pull)
            if isPulling {
                ProgressView().controlSize(.small)
                Text(pullStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Button("Pull", action: pull)
                    .buttonStyle(.borderedProminent)
                    .disabled(pullReference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Metric.snug)
        .background(.bar)
    }

    private func pull() {
        let reference = pullReference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { return }
        isPulling = true
        pullStatus = "Starting…"
        Task {
            do {
                for try await progress in store.pull(reference) {
                    pullStatus = progress.status
                }
                pullReference = ""
            } catch {
                store.failure = error.localizedDescription
            }
            isPulling = false
            pullStatus = ""
            await store.reloadAll()
        }
    }

    private func remove(_ ids: Set<ImageSummary.ID>) {
        let images = store.images.filter { ids.contains($0.id) }
        Task {
            for image in images { await store.removeImage(image) }
            selection.subtract(ids)
        }
    }
}

/// Detail pane for one image — the same Form shape as a container's Info tab.
struct ImageDetailView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Set<ImageSummary.ID>
    var onSelectContainer: (Container.ID) -> Void = { _ in }

    private var store: WorkspaceStore { model.workspace }

    private var image: ImageSummary? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.images.first { $0.id == id }
    }

    private var users: [Container] {
        guard let image else { return [] }
        return store.containers.filter { $0.uses(image) }
    }

    var body: some View {
        Group {
            if let image {
                Form {
                    Section {
                        identity(image)
                    }
                    Section("Image") {
                        DetailRow("ID", String(image.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)),
                                  monospaced: true)
                        DetailRow("Size", byteString(image.size), monospaced: true)
                        DetailRow("Created", image.created.formatted(date: .abbreviated, time: .shortened))
                        DetailRow("In use", users.isEmpty ? "Unused" : "\(users.count) containers")
                    }
                    let tags = image.repoTags.filter { $0 != "<none>:<none>" }
                    if !tags.isEmpty {
                        Section("Tags") {
                            ForEach(tags, id: \.self) { tag in
                                DetailRow("Tag", tag, monospaced: true)
                            }
                        }
                    }
                    if !users.isEmpty {
                        Section("Using") {
                            ForEach(users) { container in
                                Button {
                                    onSelectContainer(container.id)
                                } label: {
                                    DetailRow(container.service ?? container.name, container.state.label)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !image.labels.isEmpty {
                        Section("Labels") {
                            ForEach(image.labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                DetailRow(key, value, monospaced: true)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .navigationTitle(image.displayName)
                .navigationSubtitle(byteString(image.size))
            } else if selection.count > 1 {
                ContentUnavailableView("\(selection.count) images selected", systemImage: "square.stack.3d.up",
                                       description: Text("Pick one to see tags and size, or remove them from the list."))
                    .paneEmptyState()
            } else {
                ContentUnavailableView("No selection", systemImage: "square.stack.3d.up",
                                       description: Text("Pick an image."))
                    .paneEmptyState()
            }
        }
    }

    private func identity(_ image: ImageSummary) -> some View {
        HStack(spacing: Metric.regular) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(image.displayName)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(byteString(image.size))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// Volumes: where a project's data actually lives.
struct VolumesView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Set<VolumeSummary.ID>
    @State private var sortOrder = [KeyPathComparator(\VolumeSummary.name)]
    @State private var query = ""
    @State private var newName = ""

    private var store: WorkspaceStore { model.workspace }

    private var volumes: [VolumeSummary] {
        store.volumes.filter { volume in
            query.isEmpty
                || volume.name.localizedStandardContains(query)
                || (volume.composeProject?.localizedStandardContains(query) ?? false)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if store.volumes.isEmpty {
                ContentUnavailableView("No volumes", systemImage: "externaldrive",
                                       description: Text("Compose projects create theirs on first run."))
                    .paneEmptyState()
            } else if volumes.isEmpty {
                ContentUnavailableView.search(text: query)
                    .paneEmptyState()
            } else {
                Table(volumes, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { volume in
                        Text(volume.name).lineLimit(1)
                    }
                    TableColumn("Driver", value: \.driver) { volume in
                        Text(volume.driver).foregroundStyle(.secondary)
                    }
                    .width(100)
                    TableColumn("Project") { volume in
                        Text(volume.composeProject ?? "—").foregroundStyle(.secondary)
                    }
                    .width(140)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: VolumeSummary.ID.self) { ids in
                    if ids.count == 1, let volume = store.volumes.first(where: { ids.contains($0.id) }) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(volume.mountpoint, inFileViewerRootedAtPath: "")
                        }
                    }
                    Button("Remove", role: .destructive) { remove(ids) }
                }
            }
        }
        .navigationTitle("Volumes")
        .navigationSubtitle(store.volumes.isEmpty ? "" : "\(store.volumes.count) volumes")
        .safeAreaBar(edge: .top, spacing: 0) { ColumnFilter(text: $query) }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Metric.snug) {
                TextField("New volume name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Metric.snug)
            .background(.bar)
        }
        .toolbar {
            if !selection.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Remove", role: .destructive) { remove(selection) }
                }
            }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            await store.createVolume(name: name)
            newName = ""
            await store.reloadAll()
        }
    }

    private func remove(_ ids: Set<VolumeSummary.ID>) {
        let volumes = store.volumes.filter { ids.contains($0.id) }
        Task {
            for volume in volumes { await store.removeVolume(volume) }
            selection.subtract(ids)
        }
    }
}

struct VolumeDetailView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Set<VolumeSummary.ID>
    var onSelectContainer: (Container.ID) -> Void = { _ in }

    private var store: WorkspaceStore { model.workspace }

    private var volume: VolumeSummary? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.volumes.first { $0.id == id }
    }

    private var users: [Container] {
        guard let volume else { return [] }
        return store.containers.filter { $0.uses(volume) }
    }

    var body: some View {
        Group {
            if let volume {
                Form {
                    Section {
                        identity(volume)
                    }
                    Section("Volume") {
                        DetailRow("Driver", volume.driver)
                        if let project = volume.composeProject {
                            DetailRow("Compose project", project)
                        }
                        if !volume.createdAt.isEmpty {
                            DetailRow("Created", formattedDate(volume.createdAt))
                        }
                    }
                    Section("Mount") {
                        DetailRow("Path", volume.mountpoint, monospaced: true)
                    }
                    if !users.isEmpty {
                        Section("Using") {
                            ForEach(users) { container in
                                Button {
                                    onSelectContainer(container.id)
                                } label: {
                                    DetailRow(container.service ?? container.name, container.state.label)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .navigationTitle(volume.name)
                .navigationSubtitle(volume.driver)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Reveal in Finder", systemImage: "folder") {
                            NSWorkspace.shared.selectFile(volume.mountpoint, inFileViewerRootedAtPath: "")
                        }
                    }
                }
            } else if selection.count > 1 {
                ContentUnavailableView("\(selection.count) volumes selected", systemImage: "externaldrive",
                                       description: Text("Pick one to see where it lives on disk."))
                    .paneEmptyState()
            } else {
                ContentUnavailableView("No selection", systemImage: "externaldrive",
                                       description: Text("Pick a volume."))
                    .paneEmptyState()
            }
        }
    }

    private func identity(_ volume: VolumeSummary) -> some View {
        HStack(spacing: Metric.regular) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.title2.weight(.semibold))
                Text(volume.composeProject ?? volume.driver)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func formattedDate(_ raw: String) -> String {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? raw
    }
}

/// Networks, including the runtime's built-in one.
struct NetworksView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Set<NetworkSummary.ID>
    @State private var sortOrder = [KeyPathComparator(\NetworkSummary.name)]
    @State private var query = ""

    private var store: WorkspaceStore { model.workspace }

    private var networks: [NetworkSummary] {
        store.networks.filter { network in
            query.isEmpty
                || network.name.localizedStandardContains(query)
                || (network.subnet?.localizedStandardContains(query) ?? false)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if store.networks.isEmpty {
                ContentUnavailableView("No networks", systemImage: "network",
                                       description: Text("The runtime creates a default network when it starts."))
                    .paneEmptyState()
            } else if networks.isEmpty {
                ContentUnavailableView.search(text: query)
                    .paneEmptyState()
            } else {
                Table(networks, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { network in
                        HStack(spacing: Metric.tight) {
                            Text(network.name).lineLimit(1)
                            if network.isBuiltIn {
                                Text("built-in").foregroundStyle(.tertiary)
                            } else if network.internalOnly {
                                Text("internal").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    TableColumn("Driver", value: \.driver) { network in
                        Text(network.driver).foregroundStyle(.secondary)
                    }
                    .width(90)
                    TableColumn("Subnet") { network in
                        Text(network.subnet ?? "—")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Attached") { network in
                        Text(network.attached.isEmpty ? "—" : "\(network.attached.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: NetworkSummary.ID.self) { ids in
                    let removable = store.networks.filter { ids.contains($0.id) && !$0.isBuiltIn }
                    if !removable.isEmpty {
                        Button("Remove", role: .destructive) { remove(ids) }
                    }
                }
            }
        }
        .navigationTitle("Networks")
        .navigationSubtitle(store.networks.isEmpty ? "" : "\(store.networks.count) networks")
        .safeAreaBar(edge: .top, spacing: 0) { ColumnFilter(text: $query) }
        .toolbar {
            if !removableSelection.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Remove", role: .destructive) { remove(selection) }
                }
            }
        }
    }

    private var removableSelection: [NetworkSummary] {
        store.networks.filter { selection.contains($0.id) && !$0.isBuiltIn }
    }

    private func remove(_ ids: Set<NetworkSummary.ID>) {
        let networks = store.networks.filter { ids.contains($0.id) && !$0.isBuiltIn }
        Task {
            for network in networks { await store.removeNetwork(network) }
            selection.subtract(ids)
        }
    }
}

struct NetworkDetailView: View {
    @Environment(EngineModel.self) private var model
    @Binding var selection: Set<NetworkSummary.ID>
    var onSelectContainer: (Container.ID) -> Void = { _ in }

    private var store: WorkspaceStore { model.workspace }

    private var network: NetworkSummary? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.networks.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let network {
                Form {
                    Section {
                        identity(network)
                    }
                    Section("Network") {
                        DetailRow("Driver", network.driver)
                        DetailRow("Scope", network.scope)
                        if let subnet = network.subnet {
                            DetailRow("Subnet", subnet, monospaced: true)
                        }
                        if let gateway = network.gateway {
                            DetailRow("Gateway", gateway, monospaced: true)
                        }
                        DetailRow("Kind", network.isBuiltIn ? "Built-in" : (network.internalOnly ? "Internal" : "Custom"))
                    }
                    if !network.attached.isEmpty {
                        Section("Attached") {
                            ForEach(network.attached.keys.sorted(), id: \.self) { name in
                                if let container = store.containers.first(where: { $0.name == name }) {
                                    Button {
                                        onSelectContainer(container.id)
                                    } label: {
                                        DetailRow(name, network.attached[name] ?? "", monospaced: true)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    DetailRow(name, network.attached[name] ?? "", monospaced: true)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .navigationTitle(network.name)
                .navigationSubtitle(network.subnet ?? network.driver)
            } else if selection.count > 1 {
                ContentUnavailableView("\(selection.count) networks selected", systemImage: "network",
                                       description: Text("Pick one to see its subnet and attachments."))
                    .paneEmptyState()
            } else {
                ContentUnavailableView("No selection", systemImage: "network",
                                       description: Text("Pick a network."))
                    .paneEmptyState()
            }
        }
    }

    private func identity(_ network: NetworkSummary) -> some View {
        HStack(spacing: Metric.regular) {
            Image(systemName: "network")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(network.name)
                    .font(.title2.weight(.semibold))
                Text(network.subnet ?? network.driver)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
