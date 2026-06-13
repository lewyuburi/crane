import Foundation

/// User-specified options for `container run`. Kept separate from the UI so the
/// argument construction is unit-testable.
public struct RunSpec: Sendable {
    public var image: String = ""
    public var name: String = ""
    /// Init-process arguments, space-separated (naive split — no shell quoting yet).
    public var command: String = ""
    public var detach: Bool = true
    public var removeOnExit: Bool = false
    /// "KEY=VALUE" entries.
    public var env: [String] = []
    /// "[host-ip:]host-port:container-port[/proto]" entries.
    public var ports: [String] = []
    /// "host:container" bind mounts.
    public var volumes: [String] = []
    public var cpus: String = ""
    public var memory: String = ""

    public init(image: String = "", name: String = "", command: String = "", detach: Bool = true,
                removeOnExit: Bool = false, env: [String] = [], ports: [String] = [],
                volumes: [String] = [], cpus: String = "", memory: String = "") {
        self.image = image; self.name = name; self.command = command; self.detach = detach
        self.removeOnExit = removeOnExit; self.env = env; self.ports = ports; self.volumes = volumes
        self.cpus = cpus; self.memory = memory
    }

    public var isValid: Bool {
        !image.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The arguments to pass after `container run`.
    public func arguments() -> [String] {
        var args: [String] = []
        if detach { args.append("--detach") }
        if removeOnExit { args.append("--rm") }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { args += ["--name", trimmedName] }

        for entry in env where !entry.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--env", entry]
        }
        for spec in ports where !spec.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--publish", spec]
        }
        for vol in volumes where !vol.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--volume", vol]
        }

        let trimmedCPUs = cpus.trimmingCharacters(in: .whitespaces)
        if !trimmedCPUs.isEmpty { args += ["--cpus", trimmedCPUs] }
        let trimmedMemory = memory.trimmingCharacters(in: .whitespaces)
        if !trimmedMemory.isEmpty { args += ["--memory", trimmedMemory] }

        args.append(image.trimmingCharacters(in: .whitespaces))
        args += command.split(separator: " ").map(String.init)
        return args
    }
}
