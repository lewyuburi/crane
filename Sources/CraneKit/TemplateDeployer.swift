import Foundation

/// Shared filesystem locations for Crane's managed state.
public enum CranePaths {
    /// Where deployed-template projects live: ~/Library/Application Support/Crane/apps
    public static var appsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crane/apps", isDirectory: true)
    }
}

/// Renders a gallery template to a managed Compose project on disk. Shared by the app's
/// one-click deploy and the CLI's `crane deploy`, so both produce identical projects.
public enum TemplateDeployer {
    /// Write `docker-compose.yml` + `.env` for `template` into `directory`; returns the compose URL.
    @discardableResult
    public static func materialize(_ template: AppTemplate, project: String,
                                   values: [String: String], into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let composeURL = directory.appendingPathComponent("docker-compose.yml")
        try template.compose.write(to: composeURL, atomically: true, encoding: .utf8)
        let env = TemplateRenderer.envFile(values: values, project: project)
        try env.write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        return composeURL
    }

    /// Initial values for a template's variables (generated secrets + defaults).
    public static func initialValues(_ template: AppTemplate) -> [String: String] {
        Dictionary(uniqueKeysWithValues: template.variables.map { ($0.key, $0.initialValue()) })
    }
}
