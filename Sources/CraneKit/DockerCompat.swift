import Foundation

/// Translates `docker` / `docker compose` invocations into Crane's own CLI verbs or a passthrough
/// to Apple's `container` binary. Pure and side-effect free so the whole mapping is unit-tested;
/// the thin executable just runs the resulting plan and prints the warnings.
///
/// The design principle is honesty over false parity: anything Apple's runtime genuinely can't do
/// (custom networks, `--add-host`, multi-service `compose logs`) is dropped with an explicit
/// warning or reported as unsupported — never silently faked.
public enum DockerCompat {

    /// What the shim should actually run.
    public enum Plan: Equatable, Sendable {
        /// Delegate to one of our own `crane` subcommands.
        case crane([String])
        /// Pass these arguments straight to the Apple `container` binary.
        case container([String])
        /// Print this text and exit (help, or an honest "not supported").
        case message(String, isError: Bool)
    }

    /// A plan plus any non-fatal warnings (e.g. flags dropped because Apple can't honor them).
    public struct Translation: Equatable, Sendable {
        public let plan: Plan
        public let warnings: [String]
        public init(_ plan: Plan, warnings: [String] = []) {
            self.plan = plan
            self.warnings = warnings
        }
    }

    // MARK: - docker

    public static func docker(_ argv: [String]) -> Translation {
        guard let command = argv.first else {
            return Translation(.message(dockerHelp, isError: false))
        }
        let rest = Array(argv.dropFirst())

        switch command {
        case "ps":
            let all = rest.contains("-a") || rest.contains("--all")
            return Translation(.crane(all ? ["ps", "-a"] : ["ps"]))

        case "images":
            return Translation(.crane(["images"]))

        case "image" where rest.first == "ls":
            return Translation(.crane(["images"]))
        case "image" where rest.first == "rm" || rest.first == "delete":
            return Translation(.container(["image", "delete"] + rest.dropFirst()))

        case "logs":
            return translateLogs(rest)

        case "run", "create":
            return translateRun(rest)

        case "exec":
            // Drop the interactive/tty flags (Crane's exec is always interactive); keep id + command.
            let kept = rest.filter { !["-i", "-t", "-it", "-ti", "--interactive", "--tty"].contains($0) }
            return Translation(.crane(["exec"] + kept))

        case "start", "stop":
            let ids = rest.filter { !$0.hasPrefix("-") }
            return Translation(.crane([command] + ids))
        case "rm":
            let ids = rest.filter { !$0.hasPrefix("-") }
            return Translation(.crane(["rm"] + ids))

        case "build":
            return Translation(.container(["build"] + rest))
        case "pull":
            return Translation(.container(["image", "pull"] + rest))
        case "push":
            return Translation(.container(["image", "push"] + rest))
        case "rmi":
            return Translation(.container(["image", "delete"] + rest))
        case "inspect", "tag":
            return Translation(.container([command] + rest))

        case "compose":
            return compose(rest)

        case "version", "--version":
            return Translation(.message("Crane docker-compat shim — backed by Apple `container`. "
                + "Run `crane --version` for the version.", isError: false))
        case "help", "--help", "-h":
            return Translation(.message(dockerHelp, isError: false))

        default:
            return Translation(.message(
                "docker \(command): not supported by Crane's compatibility shim. "
                + "Run `crane --help` for the native commands, or call `container` directly.",
                isError: true))
        }
    }

    // MARK: - compose

    /// `argv` is everything after `docker compose` (or after `docker-compose`).
    public static func compose(_ argv: [String]) -> Translation {
        // -f/--file and the subcommand can appear in either order; pull the file out first.
        var file: String?
        var positional: [String] = []
        var i = 0
        while i < argv.count {
            let token = argv[i]
            switch token {
            case "-f", "--file":
                if i + 1 < argv.count { file = argv[i + 1]; i += 1 }
            case "-p", "--project-name":
                if i + 1 < argv.count { i += 1 }   // accepted but unused; we derive the name
            default:
                positional.append(token)
            }
            i += 1
        }

        guard let sub = positional.first else {
            return Translation(.message(composeHelp, isError: false))
        }
        let tail = file.map { [$0] } ?? []

        switch sub {
        case "up":
            return Translation(.crane(["up"] + tail))   // -d ignored: Crane always runs detached
        case "down":
            return Translation(.crane(["down"] + tail))
        case "logs":
            return Translation(.message(
                "docker compose logs: not supported — Apple's runtime has no multi-service log "
                + "aggregation. Use `crane logs <container>` (see `crane ps`) per service.",
                isError: true))
        case "build":
            return Translation(.message(
                "docker compose build: Crane builds images automatically on `up`. "
                + "Run `crane up` (optionally with -f <file>).", isError: true))
        case "exec", "run", "pull", "restart":
            return Translation(.message(
                "docker compose \(sub): not supported yet. Use the per-container `crane` commands "
                + "(`crane ps`, then `crane exec`/`crane logs <container>`).", isError: true))
        default:
            return Translation(.message(
                "docker compose \(sub): not supported by Crane's compatibility shim.", isError: true))
        }
    }

    // MARK: - docker logs

    private static func translateLogs(_ args: [String]) -> Translation {
        var out = ["logs"]
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-f", "--follow":
                out.append("-f")
            case "--tail":
                if i + 1 < args.count { out += ["--tail", args[i + 1]]; i += 1 }
            default:
                out.append(args[i])   // the container id (and we tolerate trailing positionals)
            }
            i += 1
        }
        return Translation(.crane(out))
    }

    // MARK: - docker run

    /// Flags that take a value and that we can honor (mapped to Crane's run options).
    private static let runValueFlags: [String: String] = [
        "--name": "--name",
        "-p": "-p", "--publish": "-p",
        "-e": "-e", "--env": "-e",
        "-v": "-v", "--volume": "-v",
        "--cpus": "--cpus",
        "-m": "--memory", "--memory": "--memory",
    ]
    /// Boolean flags we honor.
    private static let runBoolFlags: [String: String] = [
        "-d": "-d", "--detach": "-d",
        "--rm": "--rm",
    ]
    /// Boolean flags that are simply no-ops here (a TTY is attached as needed) — dropped silently.
    private static let runIgnoredBools: Set<String> = [
        "-i", "-t", "--interactive", "--tty", "--init",
    ]
    /// Flags that take a value but Apple's runtime can't honor — consume the value, warn, drop.
    private static let runUnsupportedValueFlags: Set<String> = [
        "-w", "--workdir", "--network", "--net", "--entrypoint", "-u", "--user",
        "-h", "--hostname", "--restart", "--add-host", "--env-file", "-l", "--label",
        "--label-file", "--link", "--dns-search",
    ]

    private static func translateRun(_ args: [String]) -> Translation {
        var out = ["run"]
        var warnings: [String] = []
        var sawImage = false
        var i = 0

        while i < args.count {
            let token = args[i]

            // Once we've hit the image, everything after is the image's own command — pass verbatim.
            if sawImage {
                out.append(token); i += 1; continue
            }

            // Split `--flag=value` and attached short forms like `-p8080:80`.
            if let (flag, value) = splitInlineValue(token) {
                if let mapped = runValueFlags[flag] {
                    out += [mapped, value]
                } else if runUnsupportedValueFlags.contains(flag) {
                    warnings.append(unsupportedFlagWarning(flag))
                } else {
                    warnings.append("ignored unknown flag: \(flag)")
                }
                i += 1; continue
            }

            if let mapped = runBoolFlags[token] {
                out.append(mapped); i += 1; continue
            }
            if runIgnoredBools.contains(token) { i += 1; continue }
            if let expanded = expandShortCluster(token) {       // e.g. -it -> [-i, -t]
                if expanded.allSatisfy({ runIgnoredBools.contains($0) || runBoolFlags[$0] != nil }) {
                    for f in expanded { if let m = runBoolFlags[f] { out.append(m) } }
                    i += 1; continue
                }
            }
            if let mapped = runValueFlags[token] {
                if i + 1 < args.count { out += [mapped, args[i + 1]]; i += 1 }
                i += 1; continue
            }
            if runUnsupportedValueFlags.contains(token) {
                warnings.append(unsupportedFlagWarning(token))
                if i + 1 < args.count { i += 1 }   // swallow its value
                i += 1; continue
            }
            if token.hasPrefix("-") {
                warnings.append("ignored unknown flag: \(token)")
                i += 1; continue
            }

            // First bare token is the image; the rest is its command (handled by `sawImage` above).
            out.append(token)
            sawImage = true
            i += 1
        }

        return Translation(.crane(out), warnings: warnings)
    }

    // MARK: - flag helpers

    /// `--name=web` → ("--name","web"); `-p8080:80` → ("-p","8080:80"). Returns nil if no inline value.
    private static func splitInlineValue(_ token: String) -> (flag: String, value: String)? {
        if token.hasPrefix("--"), let eq = token.firstIndex(of: "=") {
            return (String(token[..<eq]), String(token[token.index(after: eq)...]))
        }
        // Attached short value: -pVALUE for the known value-taking short flags.
        if token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 2 {
            let flag = String(token.prefix(2))
            if runValueFlags[flag] != nil {
                return (flag, String(token.dropFirst(2)))
            }
        }
        return nil
    }

    /// `-it` → ["-i","-t"]; only for short clusters with no `=`.
    private static func expandShortCluster(_ token: String) -> [String]? {
        guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 2 else { return nil }
        return token.dropFirst().map { "-\($0)" }
    }

    private static func unsupportedFlagWarning(_ flag: String) -> String {
        "ignored \(flag): not supported by Apple's container runtime"
    }

    // MARK: - help text

    private static let dockerHelp = """
    Crane docker-compat shim — maps common `docker` commands onto Apple's `container`.

    Supported: ps, images, run, exec, logs, start, stop, rm, build, pull, push, rmi, compose.
    Unsupported docker features (custom networks, --add-host, swarm) are reported, not faked.
    Run `crane --help` for the native commands.
    """

    private static let composeHelp = """
    Crane docker-compose shim. Supported: up [-f file], down [-f file].
    For per-service logs/exec use `crane ps` then `crane logs`/`crane exec <container>`.
    """
}
