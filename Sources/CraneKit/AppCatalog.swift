import Foundation

/// How a variable's value is produced when not supplied. Mirrors Dokploy's `${password:N}`
/// style generators so templates can declare auto-generated secrets.
public enum Generator: Hashable, Sendable {
    case none
    case password(Int)
    case base64(Int)
    case uuid

    public var isGenerated: Bool { if case .none = self { return false } else { return true } }

    public func value() -> String {
        switch self {
        case .none: return ""
        case .password(let n): return Secrets.token(n)
        case .base64(let n): return Secrets.base64(bytes: n)
        case .uuid: return UUID().uuidString.lowercased()
        }
    }

    /// Parse "password", "password:32", "base64:64", "uuid"; anything else → none.
    public static func parse(_ raw: String?) -> Generator {
        guard let raw, !raw.isEmpty else { return .none }
        let parts = raw.split(separator: ":", maxSplits: 1)
        let n = parts.count > 1 ? (Int(parts[1]) ?? 24) : 24
        switch parts[0] {
        case "password": return .password(n)
        case "base64": return .base64(n)
        case "uuid": return .uuid
        default: return .none
        }
    }
}

/// A configurable variable surfaced in the deploy form (env value, port, secret…).
public struct TemplateVar: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let defaultValue: String
    public let generator: Generator
    public let secret: Bool

    /// The starting value for the deploy form: a fresh secret when generated, else the default.
    public func initialValue() -> String { generator.isGenerated ? generator.value() : defaultValue }
}

public struct TemplateLink: Identifiable, Hashable, Sendable {
    public var id: String { url.absoluteString }
    public let label: String
    public let url: URL
}

/// A one-click app: a parametrized Compose project loaded from `templates/<id>/`. Deploying
/// renders the compose file + a sibling `.env`, registers it as a Compose project, and brings
/// it up — reusing the full engine (network/volume creation, DNS, host-wiring, grouping).
public struct AppTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let tagline: String
    public let category: Category
    public let logo: String?            // dashboard-icons slug, or a full https URL
    public let links: [TemplateLink]
    public let tags: [String]
    public let primaryPortKey: String?  // which variable holds the host port to "Open" after deploy
    public let variables: [TemplateVar]
    public let compose: String          // Compose YAML using ${VAR} placeholders

    public enum Category: String, CaseIterable, Identifiable, Codable, Sendable {
        case database = "Databases"
        case app = "Apps"
        case tool = "Tools"
        case monitoring = "Monitoring"
        case storage = "Storage"
        public var id: String { rawValue }
        public var symbol: String {
            switch self {
            case .database: return "cylinder.split.1x2"
            case .app: return "square.grid.2x2"
            case .tool: return "wrench.and.screwdriver"
            case .monitoring: return "chart.line.uptrend.xyaxis"
            case .storage: return "externaldrive"
            }
        }
    }

    public var symbol: String { category.symbol }

    /// Remote logo URL: a full URL as-is, else a crisp icon from the open dashboard-icons set.
    public var logoURL: URL? {
        guard let logo, !logo.isEmpty else { return nil }
        if logo.hasPrefix("http") { return URL(string: logo) }
        return URL(string: "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/\(logo).png")
    }
}

public enum Secrets: Sendable {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    public static func token(_ length: Int = 24) -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }
    public static func base64(bytes: Int = 32) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }
}

/// Loads the app gallery from the repo's `templates/` folder (one subfolder per app, each with
/// a `template.json` + `docker-compose.yml`). Third parties extend the gallery with a simple PR:
/// drop a new folder in `templates/` and it shows up. The folder is bundled into the .app and
/// loaded at runtime; during development it's read straight from the source tree.
public enum AppCatalog: Sendable {
    public static let all: [AppTemplate] = loadAll()

    public static var byCategory: [(category: AppTemplate.Category, apps: [AppTemplate])] {
        AppTemplate.Category.allCases.compactMap { cat in
            let apps = all.filter { $0.category == cat }
            return apps.isEmpty ? nil : (cat, apps)
        }
    }

    /// The `templates/` directory: bundled in the .app, or the repo folder during development.
    public static var directory: URL? {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("templates", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        // Dev fallback: Sources/Crane/AppCatalog.swift → repo root → templates/
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dev = repo.appendingPathComponent("templates", isDirectory: true)
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    public static func loadAll() -> [AppTemplate] {
        guard let dir = directory else { return [] }
        let subdirs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return subdirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap(load(from:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Decoding one template folder

    private struct TemplateFile: Decodable {
        let id, name, tagline: String
        let category: AppTemplate.Category
        let logo: String?
        let links: [String: String]?
        let tags: [String]?
        let primaryPort: String?
        let variables: [VarFile]
        public struct VarFile: Decodable, Sendable {
            let key, label: String
            let `default`: String?
            let generate: String?
            let secret: Bool?
        }
    }

    private static func load(from folder: URL) -> AppTemplate? {
        let metaURL = folder.appendingPathComponent("template.json")
        let composeURL = folder.appendingPathComponent("docker-compose.yml")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(TemplateFile.self, from: metaData),
              let compose = try? String(contentsOf: composeURL, encoding: .utf8)
        else { return nil }

        let links: [TemplateLink] = (meta.links ?? [:]).sorted { $0.key < $1.key }.compactMap { entry in
            URL(string: entry.value).map { TemplateLink(label: entry.key, url: $0) }
        }
        let variables = meta.variables.map { v in
            TemplateVar(key: v.key, label: v.label, defaultValue: v.default ?? "",
                        generator: Generator.parse(v.generate), secret: v.secret ?? false)
        }
        return AppTemplate(id: meta.id, name: meta.name, tagline: meta.tagline,
                           category: meta.category, logo: meta.logo, links: links,
                           tags: meta.tags ?? [], primaryPortKey: meta.primaryPort,
                           variables: variables, compose: compose)
    }
}
