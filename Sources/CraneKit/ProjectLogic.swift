import Foundation

/// Sanitizes a user-provided name into a valid Compose project / network name: lowercase ASCII
/// alphanumerics and dashes, collapsed and trimmed, with a fallback when nothing remains.
public enum ProjectName: Sendable {
    public static func sanitize(_ raw: String, fallback: String = "app") -> String {
        let cleaned = raw.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        let collapsed = String(cleaned).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// Renders the files a deployed app-template materializes. Pure (no filesystem) so it can be
/// unit-tested and reused headlessly — e.g. by a future docker-compose-compatible CLI.
public enum TemplateRenderer: Sendable {
    /// The `.env` (sorted KEY=VALUE) with PROJECT injected, so multi-service templates can
    /// address siblings by their real container name (`@${PROJECT}-db`).
    public static func envFile(values: [String: String], project: String) -> String {
        var env = values
        env["PROJECT"] = project
        return env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n") + "\n"
    }
}

/// Builds the `/etc/hosts` entries used to give Compose stacks Docker-style name resolution when
/// Apple's internal DNS misses. Pure so it can be unit-tested apart from `container exec`.
public enum HostsWiring: Sendable {
    public struct Member: Hashable, Sendable {
        let containerID: String
        let service: String
        let ip: String
    }

    /// For each member, the host lines mapping every *other* member's service name and container
    /// id to its IP. Returns empty when there's nothing to wire (0 or 1 member).
    public static func entries(members: [Member]) -> [String: [String]] {
        guard members.count > 1 else { return [:] }
        var result: [String: [String]] = [:]
        for m in members {
            let lines = members
                .filter { $0.ip != m.ip }
                .flatMap { ["\($0.ip)\t\($0.service)", "\($0.ip)\t\($0.containerID)"] }
            if !lines.isEmpty { result[m.containerID] = lines }
        }
        return result
    }
}
