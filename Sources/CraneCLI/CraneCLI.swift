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
        Crane runs Apple's `container` runtime behind a Docker-compatible socket. This tool
        sets that engine up. `docker` and `docker compose` are optional — install them with
        `crane setup --cli` when no other Docker CLI is on PATH.
        """,
        version: CraneVersion.stackSummary,
        subcommands: [Status.self, Setup.self, Restore.self]
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

    @Flag(name: .customLong("cli"),
          help: "Also install the official Docker CLI and Compose (refused if another docker is on PATH).")
    var cli = false

    func run() async throws {
        let engine = Engine()
        let console = ConsoleProgress()
        try await engine.provision { console.report($0) }
        if cli {
            do {
                try await engine.provisionCLI { console.report($0) }
                print("\u{1B}[2K\rEngine ready. `docker` is on PATH via Crane — open a new terminal.")
            } catch let error as EngineError {
                print("\u{1B}[2K\rEngine ready, but the CLI pack was not installed: \(error.localizedDescription)")
                throw ExitCode(1)
            }
        } else {
            print("\u{1B}[2K\rEngine ready. Point `docker` at the `crane` context, or run `crane setup --cli`.")
        }
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore-context",
        abstract: "Point the Docker CLI back at the context it used before Crane.")

    func run() async throws {
        let engine = Engine()
        let previous = await engine.previousContext
        try await engine.restorePreviousContext()
        print("Docker context restored to `\(previous ?? "default")`. Crane's context is still registered.")
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
