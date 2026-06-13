import ArgumentParser
import CraneKit
import Foundation

@main
struct CraneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crane",
        abstract: "Manage Apple containers from the command line.",
        version: "0.1.0",
        subcommands: [Ps.self, Up.self, Down.self]
    )
}

// MARK: - ps

struct Ps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List containers.")

    @Flag(name: .shortAndLong, help: "Show stopped containers too.") var all = false

    func run() async throws {
        let containers = try await ContainerCLI.shared.listContainers()
        let rows = (all ? containers : containers.filter(\.isRunning)).sorted { $0.id < $1.id }
        guard !rows.isEmpty else { print("No containers."); return }
        let width = rows.map(\.id.count).max() ?? 0
        for c in rows {
            let dot = c.isRunning ? "●" : "○"
            print("\(dot) \(c.id.padding(toLength: width, withPad: " ", startingAt: 0))  \(c.image)")
        }
    }
}

// MARK: - up / down

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build, (re)create, and start a Compose project.")

    @Argument(help: "Path to a compose file or its directory (default: current directory).")
    var path: String = "."

    func run() async throws {
        let project = try ComposeLoader.load(path)
        let engine = ComposeEngine(cli: ContainerCLI.shared)
        var failed = false
        for await event in engine.up(project) {
            switch event {
            case .log(let line): print(line)
            case .failure(let message):
                failed = true
                FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
            }
        }
        if failed { throw ExitCode.failure }
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop and remove a Compose project's containers.")

    @Argument(help: "Project name, or path to its compose file/directory.")
    var project: String = "."

    func run() async throws {
        // Accept either a bare project name or a path to resolve the name from.
        let name = FileManager.default.fileExists(atPath: project)
            ? try ComposeLoader.load(project).name
            : ProjectName.sanitize(project)
        print("▸ Stopping \(name)…")
        await ComposeEngine(cli: ContainerCLI.shared).down(name)
        print("Done.")
    }
}

