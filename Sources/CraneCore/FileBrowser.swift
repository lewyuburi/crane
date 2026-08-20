import AppleContainer
import DockerAPI
import Foundation

/// One entry in a container's filesystem.
public struct RemoteFile: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case directory, file, link, other }

    public let name: String
    public let kind: Kind
    public let size: Int64
    public let modified: String
    public let permissions: String

    public var id: String { name }
    public var isDirectory: Bool { kind == .directory }

    public init(name: String, kind: Kind, size: Int64, modified: String, permissions: String) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

/// Reads and writes files inside a container.
///
/// Listing goes through `container exec ls` — the Docker API has no directory listing at all, and
/// a browser is user-paced, so a process per navigation is a fair price. Transfers go through the
/// API's tar endpoint, which is what `docker cp` uses.
public struct FileBrowser: Sendable {
    private let client: DockerClient
    private let runtime: ContainerRuntime
    /// Apple's `container exec` name. The Docker SHA is not a valid runtime ID.
    private let execID: String
    /// Docker API ID (SHA or name) for the tar copy endpoints.
    private let archiveID: String

    public init(client: DockerClient, runtime: ContainerRuntime,
                execID: String, archiveID: String) {
        self.client = client
        self.runtime = runtime
        self.execID = execID
        self.archiveID = archiveID
    }

    /// When one identifier works for both exec and the Docker archive endpoints (the container
    /// name, in live tests against socktainer).
    public init(client: DockerClient, runtime: ContainerRuntime, containerID: String) {
        self.init(client: client, runtime: runtime, execID: containerID, archiveID: containerID)
    }

    public func list(_ path: String) async throws -> [RemoteFile] {
        let output = try await runtime.output(containerID: execID, command: ["/bin/ls", "-la", path])
        return ListingParser.parse(output)
    }

    /// Copies a file or directory out of the container to `destination` on the host.
    ///
    /// The endpoint always hands back a tar, even for one file, so it's unpacked into place.
    public func download(_ path: String, to destination: URL) async throws {
        let tar = try await client.archive(archiveID, path: path)
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "crane-download-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let archive = staging.appending(path: "payload.tar", directoryHint: .notDirectory)
        try tar.write(to: archive)
        try await ProcessRunner.check("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])
        try FileManager.default.removeItem(at: archive)

        // The tar's single top-level entry is the thing that was asked for.
        let unpacked = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard let item = unpacked.first else { return }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: item, to: destination)
    }

    /// Copies host files into a directory inside the container.
    public func upload(_ sources: [URL], to directory: String) async throws {
        guard !sources.isEmpty else { return }
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "crane-upload-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let archive = staging.appending(path: "payload.tar", directoryHint: .notDirectory)
        // `-C` per source keeps the archive flat: entries land directly in the target directory
        // instead of recreating the host's path inside the container.
        var arguments = ["-cf", archive.path]
        for source in sources {
            arguments += ["-C", source.deletingLastPathComponent().path, source.lastPathComponent]
        }
        try await ProcessRunner.check("/usr/bin/tar", arguments)
        try await client.extractArchive(archiveID, to: directory, tar: try Data(contentsOf: archive))
    }
}

/// Parses `ls -la` output. Pure, because the column layout differs between busybox and GNU and
/// getting it wrong turns a file browser into a liar.
public enum ListingParser {
    public static func parse(_ output: String) -> [RemoteFile] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> RemoteFile? in
            let text = String(line)
            // Skip `total 156` and anything too short to be an entry.
            guard let first = text.first, "dl-bcps".contains(first) else { return nil }
            let fields = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 9 else { return nil }

            let permissions = fields[0]
            let size = Int64(fields[4]) ?? 0
            let modified = fields[5...7].joined(separator: " ")
            // The name is everything after the timestamp — it may contain spaces.
            let name = Self.name(in: text, after: fields[7])
            guard !name.isEmpty, name != ".", name != ".." else { return nil }

            let kind: RemoteFile.Kind
            switch first {
            case "d": kind = .directory
            case "l": kind = .link
            case "-": kind = .file
            default: kind = .other
            }
            // `a -> b` for symlinks: show the link's own name.
            let displayName = kind == .link ? String(name.split(separator: " -> ").first ?? "") : name
            return RemoteFile(name: displayName, kind: kind, size: size,
                              modified: modified, permissions: permissions)
        }
        .sorted { lhs, rhs in
            lhs.isDirectory == rhs.isDirectory
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : lhs.isDirectory
        }
    }

    /// Everything after the timestamp field, which is where the name starts.
    private static func name(in line: String, after timeField: String) -> String {
        guard let range = line.range(of: " \(timeField) ") else { return "" }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}
