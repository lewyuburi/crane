import AppKit
import CraneCore
import SwiftUI
import UniformTypeIdentifiers

/// Browse a container's filesystem, and move files in and out of it.
///
/// Copying uses the same tar endpoint `docker cp` does; listing shells out to `ls` because the
/// Docker API has no directory listing at all. A browser is paced by the person using it, so a
/// process per navigation is a fair price for not inventing a protocol.
struct FilesTab: View {
    @Environment(EngineModel.self) private var model
    let container: Container

    @State private var path = "/"
    @State private var entries: [RemoteFile] = []
    @State private var isLoading = false
    @State private var failure: String?
    @State private var selection: RemoteFile.ID?
    @State private var isTargeted = false
    @State private var browser: FileBrowser?

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
        }
        .background(.clear)
        .dropDestination(for: URL.self) { urls, _ in
            upload(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(Metric.snug)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Upload…", systemImage: "arrow.up.doc") { pickAndUpload() }
                    .help("Copy files from the Mac into \(path)")
            }
        }
        .task(id: container.id) {
            browser = FileBrowser(client: model.client,
                                  runtime: model.engine.runtime,
                                  execID: container.runtimeID,
                                  archiveID: container.id)
            await load("/")
        }
    }

    // MARK: - Pieces

    private var pathBar: some View {
        HStack(spacing: Metric.tight) {
            Button {
                Task { await load(parent(of: path)) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(path == "/")
            .help("Up one directory")

            Text(path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, Metric.snug)
        .padding(.vertical, Metric.tight)
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            ContentUnavailableView("Can't read \(path)", systemImage: "folder.badge.questionmark",
                                   description: Text(failure))
                .paneEmptyState()
        } else if entries.isEmpty && !isLoading {
            ContentUnavailableView("Empty directory", systemImage: "folder",
                                   description: Text("Drop files here to copy them into \(path)."))
                .paneEmptyState()
        } else {
            Table(entries, selection: $selection) {
                TableColumn("Name") { file in
                    Label {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: symbol(for: file))
                            .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                    }
                }
                TableColumn("Size") { file in
                    Text(file.isDirectory ? "—" : byteString(file.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Modified") { file in
                    Text(file.modified).foregroundStyle(.secondary)
                }
                .width(120)
                TableColumn("Mode") { file in
                    Text(file.permissions)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(100)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
                if let file = entries.first(where: { ids.contains($0.id) }) {
                    if file.isDirectory {
                        Button("Open") { Task { await load(join(path, file.name)) } }
                    }
                    Button("Save to…") { download(file) }
                }
            } primaryAction: { ids in
                guard let file = entries.first(where: { ids.contains($0.id) }) else { return }
                if file.isDirectory {
                    Task { await load(join(path, file.name)) }
                } else {
                    download(file)
                }
            }
        }
    }

    private func symbol(for file: RemoteFile) -> String {
        switch file.kind {
        case .directory: return "folder.fill"
        case .link: return "arrow.turn.up.right"
        case .file: return "doc"
        case .other: return "questionmark.square.dashed"
        }
    }

    // MARK: - Actions

    private func load(_ target: String) async {
        guard let browser else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await browser.list(target)
            path = target
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func download(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url, let browser else { return }
        Task {
            do {
                try await browser.download(join(path, file.name), to: destination)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Copy into \(path)"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    private func upload(_ urls: [URL]) {
        guard let browser, !urls.isEmpty else { return }
        Task {
            do {
                try await browser.upload(urls, to: path)
                await load(path)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    // MARK: - Paths

    private func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private func parent(of directory: String) -> String {
        guard directory != "/" else { return "/" }
        let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }
}
