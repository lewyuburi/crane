import Foundation

/// Resolves a Compose file from a path (a file, or a directory to search) and parses it.
/// Lives in CraneKit — shared by the CLI and unit-testable without the executable target.
public enum ComposeLoader {
    public enum LoadError: LocalizedError {
        case notFound(String)
        public var errorDescription: String? {
            switch self {
            case .notFound(let path): return "No compose file found at \(path)"
            }
        }
    }

    /// Standard compose file names, in the order Docker Compose looks for them.
    static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    public static func load(_ path: String) throws -> ComposeProject {
        let fm = FileManager.default
        var file = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { throw LoadError.notFound(path) }
        if isDir.boolValue {
            guard let found = fileNames
                .map({ file.appendingPathComponent($0) })
                .first(where: { fm.fileExists(atPath: $0.path) })
            else { throw LoadError.notFound(path) }
            file = found
        }
        let yaml = try String(contentsOf: file, encoding: .utf8)
        return try ComposeParsing.parse(yaml: yaml, baseDir: file.deletingLastPathComponent())
    }
}
