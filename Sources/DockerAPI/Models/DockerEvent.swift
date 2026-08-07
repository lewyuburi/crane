import Foundation

/// One line of `GET /events` — the signal that replaces polling.
///
/// Decoding is deliberately forgiving: an event whose `Type` or `Action` Crane doesn't know
/// must still parse, because the reducer's job is to ignore it, not to break the stream.
public struct DockerEvent: Sendable, Equatable, Decodable {
    public enum Subject: String, Sendable, Equatable, Decodable {
        case container, image, volume, network, daemon, plugin, builder, unknown

        init(raw: String?) {
            self = raw.flatMap(Subject.init(rawValue:)) ?? .unknown
        }
    }

    public let subject: Subject
    /// `start`, `die`, `health_status: healthy`, … Kept as a string on purpose: Docker keeps
    /// adding actions, and an unknown one is data, not an error.
    public let action: String
    /// The id of the thing the event is about (container id, image reference, volume name…).
    public let id: String
    /// `Actor.Attributes` — carries the container name, image, exit code, compose labels.
    public let attributes: [String: String]
    public let time: Date

    public init(subject: Subject, action: String, id: String,
                attributes: [String: String] = [:], time: Date = .distantPast) {
        self.subject = subject
        self.action = action
        self.id = id
        self.attributes = attributes
        self.time = time
    }

    private enum CodingKeys: String, CodingKey {
        case type = "Type", action = "Action", actor = "Actor", id = "id", time, timeNano
    }

    private struct Actor: Decodable {
        let id: String?
        let attributes: [String: String]?
        enum CodingKeys: String, CodingKey { case id = "ID", attributes = "Attributes" }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = Subject(raw: try c.decodeIfPresent(String.self, forKey: .type))
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        let actor = try c.decodeIfPresent(Actor.self, forKey: .actor)
        // Docker's pre-1.22 top-level `id` is still sent by some daemons; prefer the Actor.
        let legacyID = try c.decodeIfPresent(String.self, forKey: .id)
        id = actor?.id ?? legacyID ?? ""
        attributes = actor?.attributes ?? [:]
        // `timeNano` is authoritative when present; `time` is whole seconds.
        if let nano = try c.decodeIfPresent(Int64.self, forKey: .timeNano), nano > 0 {
            time = Date(timeIntervalSince1970: Double(nano) / 1_000_000_000)
        } else if let seconds = try c.decodeIfPresent(Int64.self, forKey: .time) {
            time = Date(timeIntervalSince1970: Double(seconds))
        } else {
            time = .distantPast
        }
    }

    // MARK: - Convenience for the reducer

    /// The container's name, without Docker's leading slash.
    public var name: String? {
        attributes["name"].map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
    }

    /// Compose project this event belongs to, from the standard label.
    public var composeProject: String? { attributes["com.docker.compose.project"] }

    /// `health_status: healthy` → `healthy`. Nil for any other action.
    public var healthStatus: String? {
        let prefix = "health_status:"
        guard action.hasPrefix(prefix) else { return nil }
        return action.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    /// Whether this event can change what the container list shows.
    public var affectsContainerList: Bool {
        guard subject == .container else { return false }
        return !["exec_create", "exec_start", "exec_die", "resize", "attach", "top"]
            .contains { action.hasPrefix($0) }
    }
}
