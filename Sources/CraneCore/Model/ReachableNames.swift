import Foundation

/// How a container is addressed from this Mac and from other containers.
///
/// Pure: labels, published ports and attached networks already on `Container`. socktainer's
/// short Compose name (`redis`) is global, so a collision warning is computed against the
/// workspace list rather than guessed from one row.
public struct ReachableNames: Equatable, Sendable {
    /// `localhost:<hostPort>` for each published port, lowest host port first.
    public var host: [String]
    /// Names other containers can resolve: Compose `service`, `service.project`, then `name`.
    public var peers: [String]
    /// Attached network names, sorted.
    public var networks: [String]
    /// Set when another *running* Compose project uses the same short `service` name.
    public var collisionWarning: String?

    public init(of container: Container, among: [Container]) {
        host = container.publishedPorts.compactMap { port in
            guard let hostPort = port.hostPort else { return nil }
            return "localhost:\(hostPort)"
        }
        peers = Self.peerNames(for: container)
        networks = container.addresses.keys.sorted()
        collisionWarning = Self.warning(for: container, among: among)
    }

    /// Unique short-name warnings for a stack, service-name order, one per colliding service.
    public static func stackWarnings(in project: Project, among: [Container]) -> [String] {
        var seen: Set<String> = []
        var warnings: [String] = []
        let ordered = project.containers.sorted {
            ($0.service ?? $0.name, $0.name) < ($1.service ?? $1.name, $1.name)
        }
        for container in ordered {
            guard let service = container.service,
                  seen.insert(service).inserted,
                  let warning = ReachableNames(of: container, among: among).collisionWarning else { continue }
            warnings.append(warning)
        }
        return warnings
    }

    private static func peerNames(for container: Container) -> [String] {
        var names: [String] = []
        func append(_ name: String) {
            guard !name.isEmpty, !names.contains(name) else { return }
            names.append(name)
        }
        if let service = container.service, let project = container.project {
            append(service)
            append("\(service).\(project)")
        }
        append(container.name)
        return names
    }

    private static func warning(for container: Container, among: [Container]) -> String? {
        guard container.isRunning,
              let service = container.service, !service.isEmpty,
              let project = container.project else { return nil }
        let others = Set(
            among.compactMap { other -> String? in
                guard other.isRunning,
                      other.service == service,
                      let otherProject = other.project,
                      otherProject != project else { return nil }
                return otherProject
            }
        ).sorted()
        guard !others.isEmpty else { return nil }
        return "`\(service)` also names \(others.joined(separator: ", ")). Use `\(service).\(project)`."
    }
}
