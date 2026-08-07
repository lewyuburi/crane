import ArgumentParser
import CraneCore
import EngineControl
import Foundation

/// `crane` is a convenience, not a compatibility layer: it manages the engine Crane installs.
/// For containers you use `docker` — the real one, against Crane's context.
@main
struct Crane: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crane",
        abstract: "Manage the Crane container engine.",
        discussion: """
        Crane runs Apple's `container` runtime behind a Docker-compatible socket, so the regular
        `docker` and `docker compose` commands work against it. This tool sets that stack up and
        tells you when something is wrong with it.
        """,
        version: CraneVersion.stackSummary,
        subcommands: [Status.self, Setup.self]
    )
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the engine's health.")

    func run() async throws {
        let status = await Engine().status()
        for check in status.diagnostics {
            print("\(glyph(check.severity)) \(check.title.padding(toLength: 18, withPad: " ", startingAt: 0)) \(check.detail)")
        }
        print("")
        if status.isFresh {
            print("Nothing is installed yet. Run `crane setup`.")
        } else if status.isReady {
            print("Ready. \(CraneVersion.stackSummary)")
        } else {
            print("Not ready. Run `crane setup` to install or repair what's missing.")
            throw ExitCode(1)
        }
    }

    private func glyph(_ severity: Diagnostic.Severity) -> String {
        switch severity {
        case .ok: return "✓"
        case .warning: return "!"
        case .blocking: return "✗"
        }
    }
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or repair the engine, then start it.")

    func run() async throws {
        let console = ConsoleProgress()
        try await Engine().provision { console.report($0) }
        print("\u{1B}[2K\rEngine ready. `docker` now talks to Crane.")
    }
}

/// Prints install progress on a single rewritten line per component, keeping the finished ones.
/// Progress callbacks arrive off the installer's actor, hence the lock.
private final class ConsoleProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLine = ""

    func report(_ progress: StackInstaller.Progress) {
        let line: String
        switch progress.phase {
        case .downloading:
            line = "▸ \(progress.component.displayName): downloading \(Int((progress.fraction ?? 0) * 100))%"
        case .done:
            line = "✓ \(progress.component.displayName)"
        default:
            line = "▸ \(progress.component.displayName): \(progress.phase.rawValue)"
        }
        lock.lock()
        defer { lock.unlock() }
        guard line != lastLine else { return }
        lastLine = line
        print("\u{1B}[2K\r\(line)", terminator: progress.phase == .done ? "\n" : "")
        fflush(stdout)
    }
}
