import AppleContainer
import Foundation

/// A user LaunchAgent Crane owns.
///
/// This is what makes the engine "always there": macOS starts the stack at login and restarts
/// socktainer if it dies, which also blunts socktainer's known caveat that restart policies only
/// live as long as its process does.
public struct LaunchAgent: Sendable, Equatable {
    public let label: String
    /// argv — an absolute path plus its arguments.
    public let program: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    /// Seconds launchd waits before restarting the job; the default of 10 keeps a crash-looping
    /// binary from burning the CPU.
    public let throttleInterval: Int
    public let standardOutPath: String?
    public let standardErrorPath: String?

    public init(label: String, program: [String], runAtLoad: Bool = true, keepAlive: Bool = false,
                throttleInterval: Int = 10, standardOutPath: String? = nil,
                standardErrorPath: String? = nil) {
        self.label = label
        self.program = program
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.throttleInterval = throttleInterval
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
    }

    public var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist", directoryHint: .notDirectory)
    }

    /// The plist contents. Pure, so the exact shape launchd receives is unit-tested.
    public func plistData() throws -> Data {
        var dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": program,
            "RunAtLoad": runAtLoad,
            "KeepAlive": keepAlive,
            "ThrottleInterval": throttleInterval,
            "ProcessType": "Interactive",
        ]
        if let standardOutPath { dictionary["StandardOutPath"] = standardOutPath }
        if let standardErrorPath { dictionary["StandardErrorPath"] = standardErrorPath }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
}

/// Talks to `launchctl`. Every operation is idempotent: installing an agent that is already
/// loaded reloads it with the new definition rather than failing.
public enum LaunchControl {
    static let launchctl = "/bin/launchctl"

    public static var domain: String { "gui/\(getuid())" }

    public static func install(_ agent: LaunchAgent) async throws {
        let url = agent.plistURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try agent.plistData().write(to: url, options: .atomic)
        // Bootout first so a changed definition actually takes effect; ignore "not loaded".
        _ = try? await ProcessRunner.run(launchctl, ["bootout", "\(domain)/\(agent.label)"],
                                         timeout: .seconds(8))
        let result = try await ProcessRunner.run(launchctl, ["bootstrap", domain, url.path],
                                                 timeout: .seconds(8))
        guard result.succeeded else {
            throw EngineError.launchd("Couldn't load \(agent.label): \(result.err.isEmpty ? result.out : result.err)")
        }
    }

    public static func uninstall(label: String) async {
        _ = try? await ProcessRunner.run(launchctl, ["bootout", "\(domain)/\(label)"],
                                         timeout: .seconds(8))
        try? FileManager.default.removeItem(
            at: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/LaunchAgents/\(label).plist", directoryHint: .notDirectory))
    }

    /// Whether launchd knows the job and it currently has a PID.
    public static func isRunning(label: String) async -> Bool {
        guard let result = try? await ProcessRunner.run(launchctl, ["print", "\(domain)/\(label)"],
                                                        timeout: .seconds(3)),
              result.succeeded else { return false }
        return JobState.hasPID(in: result.out)
    }

    /// Restarts the job (`-k` kills it first), the repair behind a stopped Docker API.
    public static func restart(label: String) async throws {
        let result = try await ProcessRunner.run(launchctl, ["kickstart", "-k", "\(domain)/\(label)"],
                                                 timeout: .seconds(8))
        guard result.succeeded else {
            throw EngineError.launchd("Couldn't restart \(label): \(result.err.isEmpty ? result.out : result.err)")
        }
    }
}

/// Pure parsing of `launchctl print` output.
public enum JobState {
    /// launchd prints `pid = 1234` only while the job is actually running.
    public static func hasPID(in output: String) -> Bool {
        output.range(of: #"(?m)^\s*pid\s*=\s*\d+"#, options: .regularExpression) != nil
    }
}
