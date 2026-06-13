import SwiftUI

private func bytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

// MARK: - Volumes

struct VolumesView: View {
    @Environment(AppModel.self) private var model
    @State private var showingCreate = false

    var body: some View {
        Group {
            if !model.isInstalled || !model.isSystemRunning {
                ContentUnavailableView("Container system not running", systemImage: "externaldrive",
                                       description: Text("Start the system from the Containers tab first."))
            } else if model.volumes.isEmpty {
                ContentUnavailableView {
                    Label("No volumes", systemImage: "externaldrive")
                } description: {
                    Text("Create persistent storage for your containers.")
                } actions: {
                    Button("Create volume") { showingCreate = true }.buttonStyle(.glassProminent)
                }
            } else {
                List(model.volumes) { volume in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name).font(.body.weight(.medium))
                            Text(volume.source).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(volume.format) · \(bytes(volume.sizeInBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            Task { await model.deleteVolume(volume) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Volumes")
        .navigationSubtitle(model.volumes.isEmpty ? "" : "\(model.volumes.count) volumes")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingCreate = true } label: { Label("Create volume", systemImage: "plus") }
                    .disabled(!model.isSystemRunning)
                Button { Task { await model.pruneVolumes() } } label: { Label("Prune unused volumes", systemImage: "trash.slash") }
                    .disabled(model.volumes.isEmpty)
                Button { Task { await model.refreshVolumes() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .task { await model.refreshVolumes() }
        .sheet(isPresented: $showingCreate) {
            CreateResourceSheet(title: "Create volume", nameLabel: "Volume name",
                                secondLabel: "Size (optional, e.g. 1G)") { name, size in
                await model.createVolume(name: name, size: size.isEmpty ? nil : size)
            }
        }
    }
}

// MARK: - Networks

struct NetworksView: View {
    @Environment(AppModel.self) private var model
    @State private var showingCreate = false

    var body: some View {
        Group {
            if !model.isInstalled || !model.isSystemRunning {
                ContentUnavailableView("Container system not running", systemImage: "network",
                                       description: Text("Start the system from the Containers tab first."))
            } else if model.networks.isEmpty {
                ContentUnavailableView("No networks", systemImage: "network")
            } else {
                List(model.networks) { network in
                    HStack(spacing: 12) {
                        Image(systemName: "network").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(network.name).font(.body.weight(.medium))
                            Text("\(network.mode) · \(network.plugin)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let subnet = network.ipv4Subnet {
                            Text(subnet).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        if network.name != "default" {
                            Button(role: .destructive) {
                                Task { await model.deleteNetwork(network) }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Networks")
        .navigationSubtitle(model.networks.isEmpty ? "" : "\(model.networks.count) networks")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingCreate = true } label: { Label("Create network", systemImage: "plus") }
                    .disabled(!model.isSystemRunning)
                Button { Task { await model.refreshNetworks() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .task { await model.refreshNetworks() }
        .sheet(isPresented: $showingCreate) {
            CreateResourceSheet(title: "Create network", nameLabel: "Network name",
                                secondLabel: "Subnet (optional, e.g. 192.168.70.0/24)") { name, subnet in
                await model.createNetwork(name: name, subnet: subnet.isEmpty ? nil : subnet)
            }
        }
    }
}

// MARK: - Storage

struct StorageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.isInstalled || !model.isSystemRunning {
                ContentUnavailableView("Container system not running", systemImage: "internaldrive",
                                       description: Text("Start the system from the Containers tab first."))
            } else if let usage = model.diskUsage {
                ScrollView {
                    VStack(spacing: 12) {
                        UsageCard(title: "Images", icon: "square.stack.3d.up", entry: usage.images) {
                            Task { await model.pruneImages() }
                        }
                        UsageCard(title: "Containers", icon: "shippingbox", entry: usage.containers) {
                            Task { await model.pruneContainers() }
                        }
                        UsageCard(title: "Volumes", icon: "externaldrive", entry: usage.volumes) {
                            Task { await model.pruneVolumes() }
                        }
                    }
                    .padding()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Storage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshDiskUsage() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await model.refreshDiskUsage() }
    }
}

private struct UsageCard: View {
    let title: String
    let icon: String
    let entry: DiskUsage.Entry
    let prune: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.headline)
                Spacer()
                Text(bytes(entry.sizeInBytes)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            HStack(spacing: 16) {
                stat("Total", "\(entry.total)")
                stat("Active", "\(entry.active)")
                stat("Reclaimable", bytes(entry.reclaimableInBytes))
                Spacer()
                Button("Prune", action: prune)
                    .disabled(entry.reclaimableInBytes == 0)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

// MARK: - Shared create sheet

private struct CreateResourceSheet: View {
    let title: String
    let nameLabel: String
    let secondLabel: String
    let create: (String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var second = ""
    @State private var working = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
            Divider()
            Form {
                TextField(nameLabel, text: $name)
                TextField(secondLabel, text: $second)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button {
                    working = true
                    Task { if await create(name, second) { dismiss() }; working = false }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Create") }
                }
                .buttonStyle(.glassProminent)
                .disabled(name.isEmpty || working)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 240)
    }
}
