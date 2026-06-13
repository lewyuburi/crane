import SwiftUI
import CraneKit

struct ImagesView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPull = false
    @State private var selection = Set<ContainerImage.ID>()

    private func delete(_ ids: Set<ContainerImage.ID>) {
        let refs = model.images.filter { ids.contains($0.id) }.flatMap(\.references)
        Task {
            await model.deleteImages(references: refs)
            selection.subtract(ids)
        }
    }

    var body: some View {
        Group {
            if !model.isInstalled {
                ContentUnavailableView(
                    "`container` not found",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Install Apple's container CLI to manage images.")
                )
            } else if model.images.isEmpty {
                ContentUnavailableView {
                    Label("No images", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Pull an image to get started.")
                } actions: {
                    Button("Pull an image") { showingPull = true }.buttonStyle(.glassProminent)
                }
            } else {
                Table(model.images, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Tags") { image in
                        Text(image.displayTags).foregroundStyle(.secondary)
                    }
                    TableColumn("Size") { image in
                        Text(image.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu(forSelectionType: ContainerImage.ID.self) { ids in
                    Button("Delete \(ids.count) image\(ids.count == 1 ? "" : "s")", role: .destructive) {
                        delete(ids)
                    }
                } primaryAction: { ids in
                    delete(ids)
                }
            }
        }
        .navigationTitle("Images")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !selection.isEmpty {
                    Button(role: .destructive) { delete(selection) } label: {
                        Label("Delete \(selection.count) selected", systemImage: "trash")
                    }
                }
                Button { showingPull = true } label: { Label("Pull image", systemImage: "arrow.down.circle") }
                    .disabled(!model.isInstalled)
                Button { Task { await model.pruneImages() } } label: {
                    Label("Prune unused", systemImage: "trash.slash")
                }
                .disabled(model.images.isEmpty)
                Button { Task { await model.refreshImages() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await model.refreshImages() }
        .sheet(isPresented: $showingPull) { PullImageSheet() }
    }

    private var subtitle: String {
        if !selection.isEmpty { return "\(selection.count) of \(model.images.count) selected" }
        return model.images.isEmpty ? "" : "\(model.images.count) images"
    }
}

private struct PullImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reference = "docker.io/library/"
    @State private var puller = ImagePuller()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Pull image", systemImage: "arrow.down.circle")
                    .font(.headline)
                Spacer()
                Button(puller.didFinish ? "Done" : "Cancel") {
                    puller.cancel()
                    dismiss()
                }
            }
            .padding()
            Divider()

            Form {
                Section("Reference") {
                    TextField("e.g. docker.io/library/nginx:latest", text: $reference)
                        .disabled(puller.isPulling)
                }
                if puller.isPulling || puller.didFinish || puller.errorMessage != nil {
                    Section("Progress") {
                        ProgressView(value: puller.fraction)
                        Text(puller.errorMessage ?? puller.statusLine)
                            .font(.caption)
                            .foregroundStyle(puller.errorMessage != nil ? .red : .secondary)
                            .lineLimit(2)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button {
                    puller.pull(reference: reference.trimmingCharacters(in: .whitespaces))
                } label: {
                    if puller.isPulling {
                        HStack { ProgressView().controlSize(.small); Text("Pulling…") }
                    } else {
                        Text("Pull")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(reference.isEmpty || puller.isPulling)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 300)
        .onChange(of: puller.didFinish) { _, finished in
            if finished { Task { await model.refreshImages() } }
        }
    }
}
