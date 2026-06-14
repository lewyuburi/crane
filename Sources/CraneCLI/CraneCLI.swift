import ArgumentParser
import CraneKit
import Foundation

/// Multi-call entry: one binary, three personalities chosen by how it was invoked. Symlinking the
/// `crane` binary as `docker` / `docker-compose` (see CLIInstaller) makes those commands work too.
@main
struct CraneEntry {
    static func main() async {
        let invokedAs = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "crane"
        let args = Array(CommandLine.arguments.dropFirst())
        switch invokedAs {
        case "docker":
            await DockerShim.run(DockerCompat.docker(args))
        case "docker-compose":
            await DockerShim.run(DockerCompat.compose(args))
        default:
            await CraneCommand.main(args)
        }
    }
}

struct CraneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crane",
        abstract: "Manage Apple containers from the command line.",
        version: "0.1.0",
        subcommands: [Ps.self, Images.self, Logs.self, Run.self, Create.self, Exec.self,
                      Start.self, Stop.self, Rm.self,
                      Up.self, Down.self, Templates.self, Deploy.self]
    )
}

// MARK: - Containers

struct Ps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List containers.")
    @Flag(name: .shortAndLong, help: "Show stopped containers too.") var all = false
    @Flag(name: .shortAndLong, help: "Only display container IDs.") var quiet = false

    func run() async throws {
        let containers = try await ContainerCLI.shared.listContainers()
        let rows = (all ? containers : containers.filter(\.isRunning)).sorted { $0.id < $1.id }
        if quiet { for c in rows { print(c.id) }; return }   // machine-readable: `crane stop $(crane ps -q)`
        guard !rows.isEmpty else { print("No containers."); return }
        let width = rows.map(\.id.count).max() ?? 0
        for c in rows {
            let dot = c.isRunning ? "●" : "○"
            print("\(dot) \(c.id.padding(toLength: width, withPad: " ", startingAt: 0))  \(c.image)")
        }
    }
}

struct Images: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List images.")

    func run() async throws {
        let images = try await ContainerCLI.shared.listImages()
        guard !images.isEmpty else { print("No images."); return }
        let width = images.map(\.name.count).max() ?? 0
        for img in images.sorted(by: { $0.name < $1.name }) {
            let size = img.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
            print("\(img.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(img.displayTags)  \(size)")
        }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a container's logs.")
    @Argument(help: "Container id.") var id: String
    @Flag(name: .shortAndLong, help: "Follow log output.") var follow = false
    @Option(name: .shortAndLong, help: "Number of lines to show from the end.") var tail: Int = 200

    func run() async throws {
        let process = try await ContainerCLI.shared.logProcess(id: id, follow: follow, tail: tail)
        try process.run()              // inherits stdout/stderr → streams to the terminal
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create and run a container.")
    @Argument(help: "Image reference, e.g. docker.io/library/nginx:latest.") var image: String
    @Option(name: .long, help: "Container name.") var name: String = ""
    @Flag(name: .shortAndLong, help: "Run detached.") var detach = false
    @Flag(help: "Remove the container on exit.") var rm = false
    @Option(name: .shortAndLong, help: "Publish a port (host:container[/proto]).") var publish: [String] = []
    @Option(name: .shortAndLong, help: "Set an environment variable (KEY=VALUE).") var env: [String] = []
    @Option(name: .shortAndLong, help: "Bind-mount a volume (host:container).") var volume: [String] = []
    @Option(name: .long, help: "Number of CPUs.") var cpus: String = ""
    @Option(name: [.customShort("m"), .long], help: "Memory limit (e.g. 512m, 2g).") var memory: String = ""
    @Flag(name: .shortAndLong, help: "Keep STDIN open even if not attached.") var interactive = false
    @Flag(name: .shortAndLong, help: "Allocate a pseudo-TTY.") var tty = false
    @Argument(parsing: .remaining, help: "Optional command to run.") var command: [String] = []

    func run() async throws {
        let spec = RunSpec(image: image, name: name, command: command.joined(separator: " "),
                           detach: detach, removeOnExit: rm, env: env, ports: publish, volumes: volume,
                           cpus: cpus, memory: memory)
        guard detach else {
            // Foreground: inherit the terminal's stdio so the container's output (and an interactive
            // TTY) reach the user, and mirror its exit code — matching `docker run` without -d.
            var args = ["run"]
            if interactive { args.append("--interactive") }
            if tty { args.append("--tty") }
            args += ContainerCLI.withDefaultDNS(spec.arguments())
            let process = try await ContainerCLI.shared.passthroughProcess(arguments: args)
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
            return
        }
        try await ContainerCLI.shared.runContainer(spec)
        print("Started \(name.isEmpty ? image : name)")
    }
}

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a container without starting it.")
    @Argument(help: "Image reference, e.g. docker.io/library/nginx:latest.") var image: String
    @Option(name: .long, help: "Container name.") var name: String = ""
    @Flag(help: "Remove the container on exit.") var rm = false
    @Option(name: .shortAndLong, help: "Publish a port (host:container[/proto]).") var publish: [String] = []
    @Option(name: .shortAndLong, help: "Set an environment variable (KEY=VALUE).") var env: [String] = []
    @Option(name: .shortAndLong, help: "Bind-mount a volume (host:container).") var volume: [String] = []
    @Option(name: .long, help: "Number of CPUs.") var cpus: String = ""
    @Option(name: [.customShort("m"), .long], help: "Memory limit (e.g. 512m, 2g).") var memory: String = ""
    // Accepted for `docker create` compatibility but irrelevant to create — a created container
    // isn't started, so detach/interactive/tty are no-ops.
    @Flag(name: .shortAndLong) var detach = false
    @Flag(name: .shortAndLong) var interactive = false
    @Flag(name: .shortAndLong) var tty = false
    @Argument(parsing: .remaining, help: "Optional command to run.") var command: [String] = []

    func run() async throws {
        let spec = RunSpec(image: image, name: name, command: command.joined(separator: " "),
                           detach: false, removeOnExit: rm, env: env, ports: publish, volumes: volume,
                           cpus: cpus, memory: memory)
        try await ContainerCLI.shared.createStopped(arguments: spec.arguments())
        print("Created \(name.isEmpty ? image : name)")
    }
}

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command (default: a shell) in a running container.")
    @Argument(help: "Container id.") var id: String
    @Argument(parsing: .remaining, help: "Command to run (default: /bin/sh).") var command: [String] = []

    func run() async throws {
        let invocation = try await ContainerCLI.shared.execInvocation(
            id: id, command: command.isEmpty ? ["/bin/sh"] : command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.args
        process.environment = Dictionary(invocation.environment.compactMap { entry in
            entry.firstIndex(of: "=").map { (String(entry[..<$0]), String(entry[entry.index(after: $0)...])) }
        }, uniquingKeysWith: { _, last in last })
        try process.run()              // inherits stdin/stdout/stderr → interactive
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start one or more containers.")
    @Argument var ids: [String]
    func run() async throws {
        for id in ids { try await ContainerCLI.shared.start(id: id); print("Started \(id)") }
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop one or more containers.")
    @Argument var ids: [String]
    func run() async throws {
        for id in ids { try await ContainerCLI.shared.stop(id: id); print("Stopped \(id)") }
    }
}

struct Rm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove one or more containers.")
    @Flag(name: .shortAndLong, help: "Stop a running container before removing it.") var force = false
    @Argument var ids: [String]
    func run() async throws {
        for id in ids {
            if force { try? await ContainerCLI.shared.stop(id: id) }   // docker rm -f stops first
            try await ContainerCLI.shared.delete(id: id)
            print("Removed \(id)")
        }
    }
}

// MARK: - Compose

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build, (re)create, and start a Compose project.")
    @Argument(help: "Path to a compose file or its directory (default: current directory).")
    var path: String = "."
    @Option(name: .customLong("service"), parsing: .singleValue,
            help: "Only (re)create the given service (repeatable). Omit to start the whole project.")
    var services: [String] = []

    func run() async throws {
        let project = try ComposeLoader.load(path)
        let engine = ComposeEngine(cli: ContainerCLI.shared)
        var failed = false
        func drain(_ stream: AsyncStream<ComposeEvent>) async {
            for await event in stream {
                switch event {
                case .log(let line): print(line)
                case .failure(let message): failed = true; printError("✗ " + message)
                }
            }
        }
        if services.isEmpty {
            await drain(engine.up(project))
        } else {
            for name in services {
                guard let service = project.startupOrder.first(where: { $0.name == name }) else {
                    printError("✗ no such service: \(name)")
                    throw ExitCode.failure
                }
                await drain(engine.up(service: service, in: project))
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
        let name: String
        if FileManager.default.fileExists(atPath: project) {
            name = try ComposeLoader.load(project).name
        } else if ComposeLoader.looksLikePath(project) {
            // Looks like a path but isn't there — don't silently reinterpret it as a project name.
            throw ValidationError("No compose file at '\(project)'.")
        } else {
            name = ProjectName.sanitize(project)
        }
        print("▸ Stopping \(name)…")
        let failures = await ComposeEngine(cli: ContainerCLI.shared).down(name)
        guard failures.isEmpty else {
            for failure in failures { printError("✗ " + failure) }
            throw ExitCode.failure
        }
        print("Done.")
    }
}

// MARK: - App gallery

struct Templates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the one-click app templates.")
    func run() throws {
        let width = AppCatalog.all.map(\.id.count).max() ?? 0
        for t in AppCatalog.all {
            print("\(t.id.padding(toLength: width, withPad: " ", startingAt: 0))  \(t.tagline)")
        }
    }
}

struct Deploy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Deploy a one-click app template.")
    @Argument(help: "Template id (see `crane templates`).") var template: String
    @Option(name: .long, help: "Instance/project name (default: the template id).") var name: String?

    func run() async throws {
        guard let tmpl = AppCatalog.all.first(where: { $0.id == template }) else {
            throw ValidationError("Unknown template '\(template)'. Run `crane templates`.")
        }
        let project = ProjectName.sanitize(name ?? tmpl.id)
        let values = TemplateDeployer.initialValues(tmpl)
        let dir = CranePaths.appsDirectory.appendingPathComponent(project, isDirectory: true)
        let composeURL = try TemplateDeployer.materialize(tmpl, project: project, values: values, into: dir)

        let generated = tmpl.variables.filter { $0.secret }
        if !generated.isEmpty {
            print("Generated secrets (saved in \(dir.appendingPathComponent(".env").path)):")
            for v in generated { print("  \(v.key)=\(values[v.key] ?? "")") }
        }
        let proj = try ComposeLoader.load(composeURL.path)
        var failed = false
        for await event in ComposeEngine(cli: ContainerCLI.shared).up(proj) {
            switch event {
            case .log(let line): print(line)
            case .failure(let message): failed = true; printError("✗ " + message)
            }
        }
        if failed { throw ExitCode.failure }
    }
}

private func printError(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
