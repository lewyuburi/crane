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
            // Expand short clusters (`-aq`) so each flag is detected individually.
            let shorts = Set(rest.flatMap { tok -> [String] in
                if tok.hasPrefix("--") { return [tok] }
                if tok.hasPrefix("-") { return tok.dropFirst().map { "-\($0)" } }
                return []
            })
            var out = ["ps"]
            if shorts.contains("-a") || shorts.contains("--all") { out.append("-a") }
            if shorts.contains("-q") || shorts.contains("--quiet") { out.append("-q") }
            // `-f/--filter` would narrow the result set; we can't apply it, so warn rather than
            // silently returning *all* containers (which `docker stop $(docker ps -qf …)` would kill).
            var warnings: [String] = []
            if shorts.contains("-f") || shorts.contains("--filter") || rest.contains("--filter") {
                warnings.append("docker ps --filter is not supported; returning the unfiltered list.")
            }
            return Translation(.crane(out), warnings: warnings)

        case "images":
            return Translation(.crane(["images"]))

        case "image":
            switch rest.first {
            case "ls", "list": return Translation(.crane(["images"]))
            case "rm", "delete": return Translation(.container(["image", "delete"] + rest.dropFirst()))
            case .some(let sub): return Translation(.container(["image", sub] + rest.dropFirst()))
            case nil: return Translation(.message(
                "docker image: needs a subcommand (ls, rm, pull, push, inspect…).", isError: true))
            }

        case "logs":
            return translateLogs(rest)

        case "run":
            return translateRun(rest, verb: "run")
        case "create":
            // `docker create` must NOT start the container — route to `crane create` (created/stopped),
            // never to the `run` path which would start it immediately.
            return translateRun(rest, verb: "create")

        case "exec":
            return translateExec(rest)

        case "start":
            return Translation(.crane(["start"] + collectIDs(rest, valueFlags: ["--detach-keys"])))
        case "stop":
            // `-t/--timeout` and `-s/--signal` take a value — consume it so it isn't read as an id.
            return Translation(.crane(["stop"] + collectIDs(rest, valueFlags: ["-t", "--timeout", "-s", "--signal"])))
        case "rm":
            // `-f/--force` removes a running container; thread it through so `crane rm` stops first.
            let force = rest.contains("-f") || rest.contains("--force")
            let ids = collectIDs(rest, valueFlags: [])
            return Translation(.crane(["rm"] + (force ? ["-f"] : []) + ids))

        case "build":
            return Translation(.container(["build"] + rest))
        case "pull":
            return Translation(.container(["image", "pull"] + rest))
        case "push":
            return Translation(.container(["image", "push"] + rest))
        case "rmi":
            return Translation(.container(["image", "delete"] + rest))
        case "inspect":
            return Translation(.container(["inspect"] + rest))
        case "tag":
            // Apple exposes tagging as `container image tag`; top-level `container tag` doesn't exist.
            return Translation(.container(["image", "tag"] + rest))

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
        // -f/--file and -p/--project-name can appear before or after the subcommand; pull them out.
        var file: String?
        var projectName: String?
        var rest: [String] = []
        var i = 0
        while i < argv.count {
            let token = argv[i]
            if token.hasPrefix("-"), let eq = token.firstIndex(of: "=") {      // inline --file=x
                let flag = String(token[..<eq]), value = String(token[token.index(after: eq)...])
                if flag == "-f" || flag == "--file" { file = value }
                else if flag == "-p" || flag == "--project-name" { projectName = value }
                i += 1; continue
            }
            switch token {
            case "-f", "--file":
                if i + 1 < argv.count { file = argv[i + 1]; i += 1 }
            case "-p", "--project-name":
                if i + 1 < argv.count { projectName = argv[i + 1]; i += 1 }
            default:
                rest.append(token)
            }
            i += 1
        }

        guard let sub = rest.first else {
            return Translation(.message(composeHelp, isError: false))
        }
        let opts = Array(rest.dropFirst())                       // -d, --build, and SERVICE names
        let services = opts.filter { !$0.hasPrefix("-") }
        let detached = opts.contains("-d") || opts.contains("--detach")

        switch sub {
        case "up":
            var warnings: [String] = []
            if let projectName {
                warnings.append("docker compose -p \(projectName) is ignored on up; "
                    + "Crane derives the project name from the compose file.")
            }
            if !detached {
                warnings.append("docker compose up is attached in Docker; Crane starts the project, "
                    + "streams startup logs, then returns. Use `crane logs -f <container>` to keep following.")
            }
            var out = ["up"]
            if let file { out.append(file) }
            else if !services.isEmpty { out.append(".") }    // a path must precede --service options
            for service in services { out += ["--service", service] }
            return Translation(.crane(out), warnings: warnings)

        case "down":
            // A project name (from -p) names the target directly; else fall back to the file/dir.
            let target = projectName ?? file
            return Translation(.crane(["down"] + (target.map { [$0] } ?? [])))

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

    /// Collect positional ids from `args`, skipping flags. For flags in `valueFlags`, also skip the
    /// following value token so `docker stop -t 30 web` doesn't read `30` as a container id.
    private static func collectIDs(_ args: [String], valueFlags: Set<String>) -> [String] {
        var ids: [String] = []
        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("-") {
                if valueFlags.contains(token) { i += 2; continue }   // flag + its value
                i += 1; continue                                     // bool flag or inline --x=y
            }
            ids.append(token)
            i += 1
        }
        return ids
    }

    // MARK: - docker exec

    /// `docker exec` flags that take a value (so we consume it instead of mistaking it for the id).
    private static let execValueFlags: Set<String> = [
        "-e", "--env", "-w", "--workdir", "-u", "--user", "--detach-keys", "--env-file",
    ]

    /// Translate `docker exec [flags] <id> <command…>`. Only the *leading* flags are interpreted;
    /// everything from the container id onward is passed through verbatim, so flags that belong to
    /// the user's command (e.g. `grep -i`) are preserved. Crane's exec is always interactive.
    private static func translateExec(_ args: [String]) -> Translation {
        var warnings: [String] = []
        var i = 0
        while i < args.count, args[i].hasPrefix("-") {
            let token = args[i]
            if let (flag, _) = splitInlineValue(token) {           // --env=K=V etc.
                warnings.append(unsupportedFlagWarning(flag)); i += 1; continue
            }
            if ["-i", "-t", "--interactive", "--tty"].contains(token) { i += 1; continue }  // no-ops
            if let cluster = expandShortCluster(token),
               cluster.allSatisfy({ ["-i", "-t", "-d"].contains($0) }) {
                if cluster.contains("-d") { warnings.append("ignored -d: crane exec runs in the foreground") }
                i += 1; continue
            }
            if token == "-d" || token == "--detach" {
                warnings.append("ignored \(token): crane exec runs in the foreground"); i += 1; continue
            }
            if execValueFlags.contains(token) {
                warnings.append(unsupportedFlagWarning(token))
                if i + 1 < args.count { i += 1 }                   // swallow its value
                i += 1; continue
            }
            warnings.append("ignored unknown flag: \(token)"); i += 1
        }
        return Translation(.crane(["exec"] + args[i...]), warnings: warnings)
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

    // MARK: - docker run / create

    /// Flags that take a value and that we can honor (mapped to Crane's run options). The mapped
    /// name is the `crane run` flag; flags Apple's `container run` supports natively (dns/label/
    /// mount/platform) are forwarded too, not dropped.
    private static let runValueFlags: [String: String] = [
        "--name": "--name",
        "-p": "-p", "--publish": "-p",
        "-e": "-e", "--env": "-e",
        "-v": "-v", "--volume": "-v",
        "--cpus": "--cpus",
        "-m": "--memory", "--memory": "--memory",
        "--dns": "--dns", "--dns-search": "--dns-search", "--dns-option": "--dns-option",
        "-l": "--label", "--label": "--label",
        "--mount": "--mount",
        "--platform": "--platform",
    ]
    /// Boolean flags we honor (interactive/tty are kept so foreground `crane run` can attach a TTY).
    private static let runBoolFlags: [String: String] = [
        "-d": "-d", "--detach": "-d",
        "--rm": "--rm",
        "-i": "-i", "--interactive": "-i",
        "-t": "-t", "--tty": "-t",
    ]
    /// Boolean flags that are simply no-ops here — dropped silently.
    private static let runIgnoredBools: Set<String> = ["--init", "--privileged"]
    /// Flags that take a value but Apple's runtime can't honor — consume the value, warn, drop.
    /// Kept broad on purpose: a value flag we *don't* list would have its value mistaken for the image.
    private static let runUnsupportedValueFlags: Set<String> = [
        "-w", "--workdir", "--network", "--net", "--entrypoint", "-u", "--user", "-h", "--hostname",
        "--restart", "--add-host", "--env-file", "--label-file", "--link",
        "--pull", "--gpus",
        "--device", "--cap-add", "--cap-drop", "--tmpfs", "--memory-swap", "--shm-size",
        "--health-cmd", "--health-interval", "--health-timeout", "--health-retries",
        "--health-start-period", "--log-driver", "--log-opt", "--sysctl", "--ulimit",
        "--volumes-from", "--pid", "--ipc", "--uts", "--userns", "--runtime", "--stop-signal",
        "--stop-timeout", "--storage-opt", "--ip", "--ip6", "--mac-address", "--expose",
        "--network-alias", "--link-local-ip", "--cidfile", "--cpu-shares", "--cpu-period",
        "--cpu-quota", "--cpuset-cpus", "--cpuset-mems", "--blkio-weight", "--memory-reservation",
        "--oom-score-adj", "--group-add", "--security-opt", "--isolation", "--volume-driver",
        "--detach-keys", "-a", "--attach", "--annotation", "--pids-limit",
    ]

    private static func translateRun(_ args: [String], verb: String) -> Translation {
        var out = [verb]
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
                else { warnings.append("flag \(token) is missing its value") }
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

    Supported: ps, images, run, create, exec, logs, start, stop, rm, build, pull, push, rmi, compose.
    Unsupported docker features (custom networks, --add-host, swarm) are reported, not faked.
    Run `crane --help` for the native commands.
    """

    private static let composeHelp = """
    Crane docker-compose shim. Supported: up [-f file] [SERVICE…], down [-f file | -p name].
    For per-service logs/exec use `crane ps` then `crane logs`/`crane exec <container>`.
    """
}
