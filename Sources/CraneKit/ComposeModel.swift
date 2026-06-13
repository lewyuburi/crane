import Foundation
import Yams

/// A service's `build:` configuration.
public struct ComposeBuild: Hashable, Sendable {
    public var context: String        // absolute path to the build context
    public var dockerfile: String?    // absolute Dockerfile path
    public var args: [String] = []    // "KEY=VALUE" build args
}

/// A long-form `depends_on` entry: the condition to wait for and whether it's required.
public struct ServiceDependency: Hashable, Sendable {
    public var condition: String   // service_started | service_healthy | service_completed_successfully
    public var required: Bool
}

/// A service's `healthcheck:` (Compose spec). `test` is normalized so a bare string becomes
/// `["CMD-SHELL", <string>]`, matching how Compose interprets the short form.
public struct Healthcheck: Hashable, Sendable {
    public var test: [String] = []
    public var interval: String?
    public var timeout: String?
    public var retries: Int?
    public var startPeriod: String?
    public var disable: Bool = false
}

/// A persisted reference to a compose file the user added to the sidebar.
public struct ComposeProjectRef: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String          // absolute path to the compose file
    public let displayName: String   // shown in the sidebar
    public let projectName: String   // sanitized name used for the network + labels

    public init(path: String, displayName: String, projectName: String) {
        self.path = path
        self.displayName = displayName
        self.projectName = projectName
    }
}

/// A parsed Docker Compose project (a practical subset of the spec).
public struct ComposeProject: Sendable {
    public var name: String
    public var services: [ComposeService]
    /// Named volumes declared under the top-level `volumes:` key.
    public var namedVolumes: [String]
    /// Directory of the compose file, for resolving relative bind-mount paths.
    public var baseDir: URL

    /// A multi-service project. These run in "stack mode" (default network + service-name
    /// container names) so containers can resolve each other by name via Apple's internal DNS.
    /// EXPERIMENTAL: that DNS is flaky and default-network-only on `container` 1.0.x.
    public var isStack: Bool { services.count > 1 }

    /// Services ordered so dependencies come before dependents (topological).
    public var startupOrder: [ComposeService] {
        var resolved: [ComposeService] = []
        var visited = Set<String>()
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        func visit(_ s: ComposeService, _ stack: Set<String>) {
            guard !visited.contains(s.name) else { return }
            for dep in s.dependsOn where !stack.contains(dep) {
                if let d = byName[dep] { visit(d, stack.union([s.name])) }
            }
            visited.insert(s.name)
            resolved.append(s)
        }
        for s in services { visit(s, [s.name]) }
        return resolved
    }
}

public struct ComposeService: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var image: String?
    public var build: ComposeBuild?
    public var command: [String] = []
    public var ports: [String] = []        // "hostPort:containerPort[/proto]"
    public var environment: [String] = []  // "KEY=VALUE"
    public var volumes: [String] = []      // "source:target[:ro]" (host paths absolute)
    public var dependsOn: [String] = []
    public var dependencies: [String: ServiceDependency] = [:]  // long-form depends_on details
    public var dns: [String] = []          // nameserver IPs
    public var healthcheck: Healthcheck?
    public var restart: String?            // "no" | "always" | "unless-stopped" | "on-failure"
    public var memory: String?             // container memory limit, e.g. "4G"
    public var cpus: String?               // number of CPUs

    /// The container name Crane uses for this service: `{project}-{service}`. This is also its
    /// internal DNS name in stack mode, so siblings reach it as `${PROJECT}-{service}` — unique
    /// per project (no collisions between stacks that share a service name like `db`).
    public func containerName(project: String) -> String { "\(project)-\(name)" }

    /// The image to run: a built tag when the service builds, else the declared image.
    public func runImage(project: String) -> String? {
        build != nil ? (image ?? "\(project)-\(name)") : image
    }

    /// Absolute host paths used as bind-mount sources. Docker-compose auto-creates
    /// these if missing; Apple `container` errors instead, so Crane pre-creates them.
    public var hostBindPaths: [String] {
        volumes.compactMap { vol in
            let source = vol.split(separator: ":").first.map(String.init) ?? ""
            return source.hasPrefix("/") ? source : nil
        }
    }

    /// Arguments after `container run` to start this service. The compose labels let
    /// Crane group these containers by project in the Containers list (OrbStack-style).
    public func runArguments(project: String, stack: Bool = false) -> [String] {
        // Stacks run on the default network — the only one where Apple's internal DNS resolves
        // container names. Non-stack services keep their isolated per-project network.
        let network = stack ? "default" : project
        var args = ["--detach", "--name", containerName(project: project),
                    "--network", network,
                    "--label", "com.docker.compose.project=\(project)",
                    "--label", "com.docker.compose.service=\(name)"]
        for p in ports { args += ["--publish", p] }
        for e in environment { args += ["--env", e] }
        for v in volumes { args += ["--volume", v] }
        for d in dns { args += ["--dns", d] }
        if let memory { args += ["--memory", memory] }
        if let cpus { args += ["--cpus", cpus] }
        if let img = runImage(project: project) { args.append(img) }
        args += command
        return args
    }
}

public enum ComposeParsing: Sendable {
    public enum ComposeError: LocalizedError, Sendable {
        case noServices
        case invalid(String)
        public var errorDescription: String? {
            switch self {
            case .noServices: return "No `services` found in the compose file."
            case let .invalid(m): return "Invalid compose file: \(m)"
            }
        }
    }

    public static func parse(yaml: String, baseDir: URL, projectNameOverride: String? = nil) throws -> ComposeProject {
        guard let root = (try Yams.load(yaml: yaml)) as? [String: Any] else {
            throw ComposeError.invalid("top level is not a mapping")
        }
        guard let servicesDict = root["services"] as? [String: Any], !servicesDict.isEmpty else {
            throw ComposeError.noServices
        }

        // Variable interpolation sources: a sibling `.env` file (defaults), then the
        // process environment (which takes precedence), matching Compose's rules.
        var vars = loadDotEnv(baseDir.appendingPathComponent(".env"))
        vars.merge(ProcessInfo.processInfo.environment) { _, new in new }

        let projectName = sanitize(projectNameOverride
            ?? (root["name"] as? String)
            ?? baseDir.lastPathComponent)

        let services = servicesDict.keys.sorted().compactMap { key -> ComposeService? in
            guard let dict = servicesDict[key] as? [String: Any] else { return nil }
            return service(name: key, from: dict, baseDir: baseDir, vars: vars)
        }

        let namedVolumes = (root["volumes"] as? [String: Any]).map { Array($0.keys) } ?? []

        return ComposeProject(name: projectName, services: services,
                              namedVolumes: namedVolumes.sorted(), baseDir: baseDir)
    }

    // MARK: - Service field decoding (tolerant of compose's short/long forms)

    private static func service(name: String, from dict: [String: Any], baseDir: URL,
                                vars: [String: String]) -> ComposeService {
        var s = ComposeService(name: name)
        s.image = (dict["image"] as? String).map { interpolate($0, vars) }
        s.build = build(dict["build"], baseDir: baseDir, vars: vars)
        s.command = stringList(dict["command"]).map { interpolate($0, vars) }
        s.ports = ports(dict["ports"]).map { interpolate($0, vars) }
        // env_file entries are defaults; inline `environment:` overrides them.
        var envMap = envFile(dict["env_file"], baseDir: baseDir)
        for entry in environment(dict["environment"]).map({ interpolate($0, vars) }) {
            if let eq = entry.firstIndex(of: "=") {
                envMap[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        s.environment = envMap.keys.sorted().map { "\($0)=\(envMap[$0]!)" }
        s.volumes = volumes(dict["volumes"], baseDir: baseDir).map { interpolate($0, vars) }
        s.dependsOn = dependsOn(dict["depends_on"])
        s.dependencies = dependencies(dict["depends_on"])
        s.healthcheck = healthcheck(dict["healthcheck"])
        s.restart = (dict["restart"] as? String).map { interpolate($0, vars) }
        s.dns = stringList(dict["dns"]).map { interpolate($0, vars) }
        // Resource limits: short form (mem_limit/cpus) or Compose-spec deploy.resources.limits.
        let limits = ((dict["deploy"] as? [String: Any])?["resources"] as? [String: Any])?["limits"] as? [String: Any]
        s.memory = (dict["mem_limit"] ?? limits?["memory"]).map { interpolate("\($0)", vars) }.map(normalizeMemory)
        s.cpus = (dict["cpus"] ?? dict["cpu_count"] ?? limits?["cpus"]).map { interpolate("\($0)", vars) }
        return s
    }

    /// Apple `container` wants an uppercase unit suffix (K/M/G/T); compose uses lowercase ("4g").
    private static func normalizeMemory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, last.isLetter else { return trimmed }
        return trimmed.dropLast() + String(last).uppercased()
    }

    /// `build:` may be a string (context dir) or an object {context, dockerfile, args}.
    private static func build(_ value: Any?, baseDir: URL, vars: [String: String]) -> ComposeBuild? {
        if let s = value as? String {
            return ComposeBuild(context: resolveHostPath(interpolate(s, vars), baseDir: baseDir))
        }
        guard let d = value as? [String: Any] else { return nil }
        let context = resolveHostPath((d["context"] as? String).map { interpolate($0, vars) } ?? ".",
                                      baseDir: baseDir)
        let dockerfile = (d["dockerfile"] as? String).map {
            URL(fileURLWithPath: context).appendingPathComponent(interpolate($0, vars)).path
        }
        let args = environment(d["args"]).map { interpolate($0, vars) }
        return ComposeBuild(context: context, dockerfile: dockerfile, args: args)
    }

    /// `env_file:` may be a single path or a list; returns merged KEY=VALUE map.
    private static func envFile(_ value: Any?, baseDir: URL) -> [String: String] {
        let paths: [String]
        if let s = value as? String { paths = [s] }
        else if let arr = value as? [Any] { paths = arr.compactMap { $0 as? String } }
        else { return [:] }
        var merged: [String: String] = [:]
        for p in paths {
            let url = URL(fileURLWithPath: resolveHostPath(p, baseDir: baseDir))
            merged.merge(loadDotEnv(url)) { _, new in new }
        }
        return merged
    }

    // MARK: - Variable interpolation (${VAR}, ${VAR:-default}, $VAR, $$)

    public static func loadDotEnv(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    public static func interpolate(_ s: String, _ vars: [String: String]) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "$" else { out.append(s[i]); i = s.index(after: i); continue }
            let next = s.index(after: i)
            if next < s.endIndex, s[next] == "$" {            // $$ -> literal $
                out.append("$"); i = s.index(after: next); continue
            }
            if next < s.endIndex, s[next] == "{",             // ${ ... }
               let close = s[next...].firstIndex(of: "}") {
                out += resolveExpr(String(s[s.index(after: next)..<close]), vars)
                i = s.index(after: close); continue
            }
            // $VAR
            var j = next, name = ""
            while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" {
                name.append(s[j]); j = s.index(after: j)
            }
            if name.isEmpty { out.append("$"); i = next } else { out += vars[name] ?? ""; i = j }
        }
        return out
    }

    private static func resolveExpr(_ expr: String, _ vars: [String: String]) -> String {
        if let r = expr.range(of: ":-") {        // ${VAR:-default}: default if unset OR empty
            let v = vars[String(expr[..<r.lowerBound])]
            return (v?.isEmpty == false) ? v! : String(expr[r.upperBound...])
        }
        if let r = expr.range(of: ":?") {        // ${VAR:?msg}: value or empty (we don't error)
            return vars[String(expr[..<r.lowerBound])] ?? ""
        }
        if let idx = expr.firstIndex(of: "-") {  // ${VAR-default}: default only if unset
            return vars[String(expr[..<idx])] ?? String(expr[expr.index(after: idx)...])
        }
        return vars[expr] ?? ""
    }

    /// `command` may be a string ("nginx -g 'daemon off;'") or a list.
    private static func stringList(_ value: Any?) -> [String] {
        if let arr = value as? [Any] { return arr.compactMap { $0 as? String } }
        if let s = value as? String { return s.split(separator: " ").map(String.init) }
        return []
    }

    private static func ports(_ value: Any?) -> [String] {
        guard let arr = value as? [Any] else { return [] }
        return arr.compactMap { item in
            if let s = item as? String { return s }
            if let d = item as? [String: Any] {
                let published = d["published"].map { "\($0)" } ?? ""
                let target = d["target"].map { "\($0)" } ?? ""
                guard !target.isEmpty else { return nil }
                return published.isEmpty ? target : "\(published):\(target)"
            }
            if let n = item as? Int { return "\(n)" }
            return nil
        }
    }

    /// `environment` may be a map {K: V} or a list ["K=V"].
    private static func environment(_ value: Any?) -> [String] {
        if let map = value as? [String: Any] {
            return map.keys.sorted().map { k in "\(k)=\(map[k].map { "\($0)" } ?? "")" }
        }
        if let arr = value as? [Any] { return arr.compactMap { $0 as? String } }
        return []
    }

    /// `volumes` may be short strings ("./src:/dst:ro") or long objects.
    /// Relative host paths are resolved against the compose file's directory.
    private static func volumes(_ value: Any?, baseDir: URL) -> [String] {
        guard let arr = value as? [Any] else { return [] }
        return arr.compactMap { item -> String? in
            if let s = item as? String { return resolveVolume(s, baseDir: baseDir) }
            if let d = item as? [String: Any],
               let target = d["target"] as? String {
                let source = (d["source"] as? String) ?? ""
                let ro = (d["read_only"] as? Bool) == true ? ":ro" : ""
                let resolved = source.isEmpty ? target : "\(resolveHostPath(source, baseDir: baseDir)):\(target)"
                return resolved + ro
            }
            return nil
        }
    }

    private static func resolveVolume(_ spec: String, baseDir: URL) -> String {
        let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return spec }  // anonymous volume, leave as-is
        let source = resolveHostPath(parts[0], baseDir: baseDir)
        return ([source] + parts[1...]).joined(separator: ":")
    }

    /// Bind-mount sources (./, ../, /, ~) are resolved to absolute paths; bare names
    /// are treated as named volumes and left unchanged.
    private static func resolveHostPath(_ path: String, baseDir: URL) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        if path.hasPrefix("./") || path.hasPrefix("../") || path == "." {
            return baseDir.appendingPathComponent(path).standardizedFileURL.path
        }
        return path  // named volume
    }

    private static func dependsOn(_ value: Any?) -> [String] {
        if let arr = value as? [Any] { return arr.compactMap { $0 as? String } }
        if let map = value as? [String: Any] { return Array(map.keys) }
        if let s = value as? String { return [s] }
        return []
    }

    /// Long-form `depends_on: { svc: { condition, required } }`. `required` defaults to true.
    private static func dependencies(_ value: Any?) -> [String: ServiceDependency] {
        guard let map = value as? [String: Any] else { return [:] }
        return map.reduce(into: [:]) { result, entry in
            if let cfg = entry.value as? [String: Any], let condition = cfg["condition"] as? String {
                result[entry.key] = ServiceDependency(condition: condition,
                                                      required: (cfg["required"] as? Bool) ?? true)
            }
        }
    }

    /// `healthcheck:` — `test` may be a bare string (wrapped as CMD-SHELL) or a list.
    private static func healthcheck(_ value: Any?) -> Healthcheck? {
        guard let d = value as? [String: Any] else { return nil }
        var hc = Healthcheck()
        hc.disable = (d["disable"] as? Bool) ?? false
        if let s = d["test"] as? String { hc.test = ["CMD-SHELL", s] }
        else if let arr = d["test"] as? [Any] { hc.test = arr.compactMap { $0 as? String } }
        hc.interval = d["interval"] as? String
        hc.timeout = d["timeout"] as? String
        hc.retries = (d["retries"] as? NSNumber)?.intValue
        hc.startPeriod = d["start_period"] as? String
        return hc
    }

    /// Project/network names must be lowercase alphanumeric + dashes.
    private static func sanitize(_ name: String) -> String { ProjectName.sanitize(name) }
}
