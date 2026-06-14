import ArgumentParser
import CraneKit
import Foundation

/// Runs a `DockerCompat.Translation`: prints any warnings, then dispatches to our own subcommands,
/// passes through to the Apple `container` binary, or reports an honest "not supported" message.
enum DockerShim {
    static func run(_ translation: DockerCompat.Translation) async {
        for warning in translation.warnings {
            FileHandle.standardError.write(Data(("⚠︎ " + warning + "\n").utf8))
        }
        switch translation.plan {
        case .crane(let args):
            await CraneCommand.main(args)
        case .container(let args):
            await passthrough(args)
        case .message(let text, let isError):
            let handle = isError ? FileHandle.standardError : FileHandle.standardOutput
            handle.write(Data((text + "\n").utf8))
            if isError { exit(1) }
        }
    }

    /// Forward to `container <args>`, inheriting stdio, and mirror its exit code.
    private static func passthrough(_ args: [String]) async {
        do {
            let process = try await ContainerCLI.shared.passthroughProcess(arguments: args)
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        } catch {
            FileHandle.standardError.write(Data(("✗ " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
