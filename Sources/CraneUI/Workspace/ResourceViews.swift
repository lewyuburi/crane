import CraneCore
import DockerAPI
import SwiftUI

/// Images: what's on disk, how big, and what's using it.
struct ImagesView: View {
    @Environment(EngineModel.self) private var model
    @State private var selection = Set<ImageSummary.ID>()
    @State private var pullReference = ""
    @State private var isPulling = false
    @State private var pullStatus = ""

    private var store: WorkspaceStore { model.workspace }

    var body: some View {
        Group {
            if store.images.isEmpty {
                ContentUnavailableView("No images", systemImage: "square.stack.3d.up",
                                       description: Text("Pull one below, or run a container and let the daemon fetch it."))
            } else {
                Table(store.images.sorted { $0.displayName < $1.displayName }, selection: $selection) {
                    TableColumn("Image") { image in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(image.displayName).lineLimit(1).truncationMode(.middle)
                            if image.containers > 0 {
                                Text("in use by \(image.containers)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("Size") { image in
                        Text(byteString(image.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(90)
                    TableColumn("Created") { image in
                        Text(image.created.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                    .width(120)
                }
                .contextMenu(forSelectionType: ImageSummary.ID.self) { ids in
                    Button("Remove", role: .destructive) { remove(ids) }
                }
            }
        }
        .navigationTitle("Images")
        .navigationSubtitle(store.images.isEmpty ? "" : "\(store.images.count) images · \(byteString(totalSize))")
        .safeAreaInset(edge: .bottom) { pullBar }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !selection.isEmpty {
                    Button(role: .destructive) { remove(selection) } label: {
                        Label("Remove \(selection.count)", systemImage: "trash")
                    }
                }
                Button { Task { await store.pruneImages() } } label: {
                    Label("Prune unused", systemImage: "trash.slash")
                }
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
                Button("Pull", action: pull).disabled(pullReference.trimmingCharacters(in: .whitespaces).isEmpty)
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

/// Volumes: where a project's data actually lives.
struct VolumesView: View {
    @Environment(EngineModel.self) private var model
    @State private var newName = ""

    private var store: WorkspaceStore { model.workspace }

    var body: some View {
        Group {
            if store.volumes.isEmpty {
                ContentUnavailableView("No volumes", systemImage: "externaldrive",
                                       description: Text("Compose projects create theirs on first run."))
            } else {
                List {
                    ForEach(store.volumes.sorted { $0.name < $1.name }) { volume in
                        HStack(spacing: Metric.snug) {
                            Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(volume.name).fontWeight(.medium)
                                Text(volume.mountpoint).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if let project = volume.composeProject { Pill(project, tint: .blue) }
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(volume.mountpoint, inFileViewerRootedAtPath: "")
                            }
                            Button("Remove", role: .destructive) {
                                Task { await store.removeVolume(volume) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Volumes")
        .navigationSubtitle(store.volumes.isEmpty ? "" : "\(store.volumes.count) volumes")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Metric.snug) {
                TextField("New volume name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("Create", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Metric.snug)
            .background(.bar)
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
}

/// Networks, including the runtime's built-in one.
struct NetworksView: View {
    @Environment(EngineModel.self) private var model

    private var store: WorkspaceStore { model.workspace }

    var body: some View {
        List {
            ForEach(store.networks.sorted { $0.name < $1.name }) { network in
                HStack(spacing: Metric.snug) {
                    Image(systemName: "network").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Metric.tight) {
                            Text(network.name).fontWeight(.medium)
                            if network.isBuiltIn { Pill("built-in") }
                            if network.internalOnly { Pill("internal", tint: .orange) }
                        }
                        Text(network.subnet ?? network.driver)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !network.attached.isEmpty {
                        Pill("\(network.attached.count) attached", tint: .accentColor)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    if !network.isBuiltIn {
                        Button("Remove", role: .destructive) {
                            Task { await store.removeNetwork(network) }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Networks")
        .navigationSubtitle(store.networks.isEmpty ? "" : "\(store.networks.count) networks")
    }
}
