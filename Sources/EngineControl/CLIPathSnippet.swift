import Foundation

/// Puts Crane's `bin/` on the user's PATH without touching `/usr/local/bin`.
///
/// The block is marked so re-running setup is a no-op and a later edit can find it. Only
/// `~/.zprofile` is created; `~/.bash_profile` is updated only when it already exists, so
/// Crane doesn't invent a bash login story for zsh-only Macs.
public enum CLIPathSnippet: Sendable {
    public static let marker = "# crane-cli"

    public static func block(binDirectory: URL) -> String {
        let path = binDirectory.path(percentEncoded: false)
        return """
        \(marker)
        export PATH="\(path):$PATH"
        """
    }

    /// Idempotent: replaces a previous Crane block or appends one.
    public static func applying(_ existing: String, binDirectory: URL) -> String {
        let block = block(binDirectory: binDirectory)
        let blockLines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) {
            var end = start + 1
            if end < lines.count, lines[end].contains("export PATH=") { end += 1 }
            lines.replaceSubrange(start..<min(end, lines.count), with: blockLines)
            return trimTrailingExtraNewlines(lines.joined(separator: "\n"))
        }
        let trimmed = existing.trimmingCharacters(in: .newlines)
        if trimmed.isEmpty { return block + "\n" }
        return trimmed + "\n\n" + block + "\n"
    }

    public static func install(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        binDirectory: URL
    ) throws {
        let fm = FileManager.default
        let zprofile = home.appending(path: ".zprofile", directoryHint: .notDirectory)
        try write(applying((try? String(contentsOf: zprofile, encoding: .utf8)) ?? "", binDirectory: binDirectory),
                  to: zprofile)

        let bashProfile = home.appending(path: ".bash_profile", directoryHint: .notDirectory)
        if fm.fileExists(atPath: bashProfile.path) {
            try write(applying((try? String(contentsOf: bashProfile, encoding: .utf8)) ?? "",
                               binDirectory: binDirectory),
                      to: bashProfile)
        }
    }

    private static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func trimTrailingExtraNewlines(_ text: String) -> String {
        var result = text
        while result.hasSuffix("\n\n") { result.removeLast() }
        if !result.hasSuffix("\n") { result.append("\n") }
        return result
    }
}
