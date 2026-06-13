import Foundation

/// User-specified options for `container run`. Kept separate from the UI so the
/// argument construction is unit-testable.
struct RunSpec {
    var image: String = ""
    var name: String = ""
    /// Init-process arguments, space-separated (naive split — no shell quoting yet).
    var command: String = ""
    var detach: Bool = true
    var removeOnExit: Bool = false
    /// "KEY=VALUE" entries.
    var env: [String] = []
    /// "[host-ip:]host-port:container-port[/proto]" entries.
    var ports: [String] = []
    /// "host:container" bind mounts.
    var volumes: [String] = []
    var cpus: String = ""
    var memory: String = ""

    var isValid: Bool {
        !image.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The arguments to pass after `container run`.
    func arguments() -> [String] {
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
