import Foundation

/// The native `container` binary — used only for what the Docker API can't express.
///
/// Crane reads state through the Docker socket, never through this. What lives here is the
/// runtime's own surface: bringing the apiserver up, kernels, DNS domains and machines.
public struct ContainerRuntime: Sendable {
    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    public func version() async -> String? {
        guard let result = try? await ProcessRunner.run(executable, ["--version"]), result.succeeded else {
            return nil
        }
        return result.out
    }

    /// Whether the apiserver is up. `container system status` exits non-zero when it isn't.
    public func isSystemRunning() async -> Bool {
        guard let result = try? await ProcessRunner.run(executable, ["system", "status"]) else { return false }
        return result.succeeded
    }

    /// Starts the apiserver, installing the default kernel on first run.
    ///
    /// Idempotent by design: when the service is already up this is a no-op, which is what lets
    /// it double as the login-time launch agent.
    public func startSystem() async throws {
        if await isSystemRunning() { return }
        try await ProcessRunner.check(executable, ["system", "start", "--enable-kernel-install"])
    }

    public func stopSystem() async throws {
        try await ProcessRunner.check(executable, ["system", "stop"])
    }

    /// The DNS domain configured for container name resolution on the host, if any.
    /// Read straight from the runtime's TOML config — the CLI has no getter for it.
    public func configuredDNSDomain() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/container/config.toml", directoryHint: .notDirectory)
        guard let toml = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        return TOMLValue.string(section: "dns", key: "domain", in: toml)
    }
}

/// A deliberately tiny TOML reader: Crane needs two scalars out of Apple's config file and
/// nothing else, so this stays a pure function instead of a dependency.
public enum TOMLValue {
    public static func string(section: String, key: String, in toml: String) -> String? {
        var inSection = false
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line == "[\(section)]"
                continue
            }
            guard inSection, line.hasPrefix(key) else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                let body = value.dropFirst()
                guard let close = body.firstIndex(of: quote) else { return nil }
                return String(body[body.startIndex..<close])
            }
            if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
            let bare = value.trimmingCharacters(in: .whitespaces)
            return bare.isEmpty ? nil : bare
        }
        return nil
    }
}
