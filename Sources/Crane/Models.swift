import Foundation
import SwiftUI

struct PortForward: Hashable {
    let hostPort: Int
    let containerPort: Int
    let proto: String
    let hostAddress: String
}

struct MountPoint: Hashable {
    let source: String
    let destination: String
    let readOnly: Bool
}

/// A container as shown in Crane's UI.
struct Container: Identifiable, Hashable {
    let id: String
    var image: String
    var status: ContainerStatus
    var addresses: [String]
    var os: String?
    var arch: String?
    var hostname: String?
    var ports: [PortForward] = []
    var mounts: [MountPoint] = []
    var labels: [String: String] = [:]

    // Fields needed to faithfully recreate the container with a new resource limit
    // (Apple `container` sets memory/cpus only at creation — no live resize).
    var memoryBytes: Int64?
    var cpus: Int?
    var environment: [String] = []
    var network: String?
    var entrypoint: String?
    var commandArgs: [String] = []

    var isRunning: Bool { status == .running }

    /// Arguments after `container run` to recreate this container with the given
    /// resource limits, preserving its image, env, ports, mounts, network and labels.
    func recreateArguments(memory: String?, cpus: Int?) -> [String] {
        var args = ["--detach", "--name", id]
        if let network, !network.isEmpty { args += ["--network", network] }
        for p in ports {
            let host = (p.hostAddress.isEmpty || p.hostAddress == "0.0.0.0") ? "" : "\(p.hostAddress):"
            args += ["--publish", "\(host)\(p.hostPort):\(p.containerPort)/\(p.proto)"]
        }
        for m in mounts { args += ["--volume", m.source + ":" + m.destination + (m.readOnly ? ":ro" : "")] }
        for e in environment { args += ["--env", e] }
        for (k, v) in sortedLabels { args += ["--label", "\(k)=\(v)"] }
        if let memory, !memory.isEmpty { args += ["--memory", memory] }
        if let cpus { args += ["--cpus", "\(cpus)"] }
        if let entrypoint, !entrypoint.isEmpty { args += ["--entrypoint", entrypoint] }
        args.append(image)
        args += commandArgs
        return args
    }

    /// Labels sorted by key for stable display.
    var sortedLabels: [(key: String, value: String)] {
        labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Compose project this container belongs to (from the standard label), if any.
    var composeProject: String? { labels["com.docker.compose.project"] }
    var composeService: String? { labels["com.docker.compose.service"] }
}

enum ContainerStatus: String, Hashable {
    case running
    case stopped
    case created
    case unknown

    init(rawValue raw: String) {
        switch raw.lowercased() {
        case "running": self = .running
        case "stopped", "exited": self = .stopped
        case "created": self = .created
        default: self = .unknown
        }
    }

    var displayName: String { rawValue.capitalized }

    var tint: Color {
        switch self {
        case .running: return .green
        case .stopped: return .secondary
        case .created: return .orange
        case .unknown: return .gray
        }
    }
}

/// A local OCI image, grouped by digest id (one row even when multi-tagged).
struct ContainerImage: Identifiable, Hashable {
    let id: String              // image digest id (same image → same id)
    var name: String            // repository, e.g. docker.io/library/alpine
    var tags: [String]          // all tags pointing at this image
    var references: [String]    // full refs (name:tag) for deletion
    var size: Int64?

    var displayTags: String { tags.sorted().joined(separator: ", ") }
}

/// Resilient decoding of the `container --format json` output.
///
/// The CLI's JSON shape has shifted across releases, so rather than a strict
/// Codable model we walk the parsed JSON and pull fields from several known
/// key paths. A missing field degrades one row, never the whole list.
enum ContainerDecoding {
    static func decodeContainers(from data: Data) throws -> [Container] {
        let objects = try topLevelObjects(data)
        return objects.compactMap(container(from:))
    }

    static func decodeImages(from data: Data) throws -> [ContainerImage] {
        // Apple `container image ls` returns one entry per tag; group by digest id so a
        // multi-tagged image (e.g. :java25 and :latest) is a single row.
        var byID: [String: ContainerImage] = [:]
        var order: [String] = []
        for obj in try topLevelObjects(data) {
            guard let p = imageEntry(from: obj) else { continue }
            if var existing = byID[p.id] {
                if !existing.tags.contains(p.tag) { existing.tags.append(p.tag) }
                if !existing.references.contains(p.reference) { existing.references.append(p.reference) }
                existing.size = existing.size ?? p.size
                byID[p.id] = existing
            } else {
                byID[p.id] = ContainerImage(id: p.id, name: p.name, tags: [p.tag],
                                            references: [p.reference], size: p.size)
                order.append(p.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    // MARK: - Helpers

    private static func topLevelObjects(_ data: Data) throws -> [[String: Any]] {
        guard !data.isEmpty else { return [] }
        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [[String: Any]] { return array }
        if let single = json as? [String: Any] { return [single] }
        return []
    }

    private static func container(from obj: [String: Any]) -> Container? {
        let config = obj["configuration"] as? [String: Any] ?? obj

        guard let id = string(config["id"]) ?? string(obj["id"]) ?? string(obj["name"]) else {
            return nil
        }

        // `status` is an object { state, networks, startedDate } in container 1.0;
        // tolerate a bare string for forward/backward compatibility.
        let statusObj = obj["status"] as? [String: Any]
        let statusString = string(statusObj?["state"]) ?? string(obj["status"]) ?? "unknown"
        let status = ContainerStatus(rawValue: statusString)

        let image = imageReference(from: config["image"]) ?? string(config["image"]) ?? "—"

        // Runtime addresses live in status.networks[].ipv4Address ("192.168.64.2/24").
        let networks = (statusObj?["networks"] as? [[String: Any]])
            ?? (obj["networks"] as? [[String: Any]]) ?? []
        let addresses = networks.compactMap { net -> String? in
            let raw = string(net["ipv4Address"]) ?? string(net["address"])
                ?? string(net["ipv4"]) ?? string(net["ip"])
            return raw.map { String($0.prefix { $0 != "/" }) } // strip CIDR mask
        }

        let hostname = networks.compactMap { string($0["hostname"]) }.first

        let ports: [PortForward] = (config["publishedPorts"] as? [[String: Any]] ?? []).compactMap { p in
            guard let host = (p["hostPort"] as? NSNumber)?.intValue,
                  let cont = (p["containerPort"] as? NSNumber)?.intValue else { return nil }
            return PortForward(
                hostPort: host, containerPort: cont,
                proto: string(p["proto"]) ?? "tcp",
                hostAddress: string(p["hostAddress"]) ?? "0.0.0.0"
            )
        }

        let mounts: [MountPoint] = (config["mounts"] as? [[String: Any]] ?? []).compactMap { m in
            let source = string(m["source"]) ?? string(m["src"]) ?? ""
            let dest = string(m["destination"]) ?? string(m["target"]) ?? string(m["dst"]) ?? ""
            guard !source.isEmpty || !dest.isEmpty else { return nil }
            let ro = (m["readonly"] as? Bool) ?? (m["readOnly"] as? Bool) ?? false
            return MountPoint(source: source, destination: dest, readOnly: ro)
        }

        let labels = (config["labels"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }

        let resources = config["resources"] as? [String: Any]
        let memoryBytes = (resources?["memoryInBytes"] as? NSNumber)?.int64Value
        let cpus = (resources?["cpus"] as? NSNumber)?.intValue

        let initProcess = config["initProcess"] as? [String: Any]
        let environment = (initProcess?["environment"] as? [Any] ?? []).compactMap { $0 as? String }
        let entrypoint = string(initProcess?["executable"])
        let commandArgs = (initProcess?["arguments"] as? [Any] ?? []).compactMap { $0 as? String }

        // Configured network (config.networks[].network); falls back to the runtime one.
        let configNetworks = config["networks"] as? [[String: Any]] ?? []
        let network = configNetworks.compactMap { string($0["network"]) }.first
            ?? networks.compactMap { string($0["network"]) }.first

        let platform = config["platform"] as? [String: Any]
        return Container(
            id: id,
            image: image,
            status: status,
            addresses: addresses,
            os: string(platform?["os"]) ?? string(config["os"]),
            arch: string(platform?["architecture"]) ?? string(config["arch"]),
            hostname: hostname,
            ports: ports,
            mounts: mounts,
            labels: labels,
            memoryBytes: memoryBytes,
            cpus: cpus,
            environment: environment,
            network: network,
            entrypoint: entrypoint,
            commandArgs: commandArgs
        )
    }

    private struct ImageEntry { let id: String; let reference: String; let name: String; let tag: String; let size: Int64? }

    private static func imageEntry(from obj: [String: Any]) -> ImageEntry? {
        let config = obj["configuration"] as? [String: Any] ?? obj
        guard let reference = string(config["name"]) ?? string(config["reference"])
            ?? string(obj["reference"]) ?? string(obj["name"]) else { return nil }
        let (name, tag) = splitReference(reference)
        // Group by digest id; fall back to the reference if no id is present.
        let id = string(obj["id"]) ?? reference

        // Prefer the summed variant sizes (actual image bytes); the descriptor size
        // is just the manifest index, which is tiny and misleading.
        var size: Int64?
        if let variants = obj["variants"] as? [[String: Any]] {
            let total = variants.compactMap { ($0["size"] as? NSNumber)?.int64Value }.reduce(0, +)
            if total > 0 { size = total }
        }
        if size == nil {
            size = (config["descriptor"] as? [String: Any])
                .flatMap { ($0["size"] as? NSNumber)?.int64Value }
        }
        return ImageEntry(id: id, reference: reference, name: name, tag: tag, size: size)
    }

    private static func imageReference(from value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            return string(dict["reference"]) ?? string(dict["name"])
        }
        return nil
    }

    private static func splitReference(_ reference: String) -> (name: String, tag: String) {
        // Split on the last colon that isn't part of a port (i.e., after the last "/").
        let lastSlash = reference.lastIndex(of: "/")
        let searchStart = lastSlash.map { reference.index(after: $0) } ?? reference.startIndex
        if let colon = reference[searchStart...].lastIndex(of: ":") {
            return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
        }
        return (reference, "latest")
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }
}
