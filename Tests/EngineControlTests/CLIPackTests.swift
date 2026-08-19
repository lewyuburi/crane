import Foundation
import Testing

@testable import EngineControl

@Suite("Docker locator")
struct DockerLocatorTests {
    private let fm = FileManager.default

    @Test("The first docker on PATH wins, and Crane's own bin is not foreign")
    func foreignVersusCrane() throws {
        let root = fm.temporaryDirectory.appending(path: "crane-locator-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let craneBin = root.appending(path: "crane-bin", directoryHint: .isDirectory)
        let brewBin = root.appending(path: "brew-bin", directoryHint: .isDirectory)
        try makeDocker(in: craneBin)
        try makeDocker(in: brewBin)

        let cranePath = "\(craneBin.path):\(brewBin.path)"
        #expect(DockerLocator.foreignPath(craneBin: craneBin, pathEnvironment: cranePath) == nil)

        let brewFirst = "\(brewBin.path):\(craneBin.path)"
        #expect(DockerLocator.foreignPath(craneBin: craneBin, pathEnvironment: brewFirst)
            == brewBin.appending(path: "docker").path)

        #expect(DockerLocator.foreignPath(craneBin: craneBin, pathEnvironment: "") == nil)
        #expect(DockerLocator.foreignPath(craneBin: craneBin, pathEnvironment: "/nope") == nil)
    }

    private func makeDocker(in directory: URL) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let docker = directory.appending(path: "docker", directoryHint: .notDirectory)
        try Data("#!/bin/sh\n".utf8).write(to: docker)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
    }
}

@Suite("PATH snippet")
struct CLIPathSnippetTests {
    @Test("Applying twice does not duplicate the block")
    func idempotent() {
        let bin = URL(fileURLWithPath: "/Users/dev/Library/Application Support/Crane/bin")
        let first = CLIPathSnippet.applying("", binDirectory: bin)
        #expect(first.contains(CLIPathSnippet.marker))
        #expect(first.contains("export PATH=\"\(bin.path):$PATH\""))
        let second = CLIPathSnippet.applying(first, binDirectory: bin)
        #expect(second.components(separatedBy: CLIPathSnippet.marker).count == 2)
    }

    @Test("An existing profile keeps its contents and gains the block")
    func preservesProfile() {
        let bin = URL(fileURLWithPath: "/opt/crane/bin")
        let existing = "eval \"$(/opt/homebrew/bin/brew shellenv)\"\n"
        let next = CLIPathSnippet.applying(existing, binDirectory: bin)
        #expect(next.hasPrefix("eval"))
        #expect(next.contains(CLIPathSnippet.marker))
    }

    @Test("Re-applying updates the path inside an existing block")
    func replacesBlock() {
        let old = CLIPathSnippet.applying("", binDirectory: URL(fileURLWithPath: "/old/bin"))
        let next = CLIPathSnippet.applying(old, binDirectory: URL(fileURLWithPath: "/new/bin"))
        #expect(next.contains("/new/bin"))
        #expect(!next.contains("/old/bin"))
    }

    @Test("Install writes zprofile and only touches bash_profile when it exists")
    func installProfiles() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "crane-home-\(UUID().uuidString)")
        let bin = URL(fileURLWithPath: "/tmp/crane/bin")
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        try CLIPathSnippet.install(home: home, binDirectory: bin)
        let zprofile = try String(contentsOf: home.appending(path: ".zprofile"), encoding: .utf8)
        #expect(zprofile.contains(CLIPathSnippet.marker))
        #expect(!fm.fileExists(atPath: home.appending(path: ".bash_profile").path))

        try Data("set -e\n".utf8).write(to: home.appending(path: ".bash_profile"))
        try CLIPathSnippet.install(home: home, binDirectory: bin)
        let bash = try String(contentsOf: home.appending(path: ".bash_profile"), encoding: .utf8)
        #expect(bash.contains("set -e"))
        #expect(bash.contains(CLIPathSnippet.marker))
    }
}

@Suite("CLI pack errors")
struct CLIPackErrorTests {
    @Test("A blocked pack has a path in the message")
    func blockedMessage() {
        let error = EngineError.cliPackBlocked("/usr/local/bin/docker")
        #expect(error.errorDescription?.contains("/usr/local/bin/docker") == true)
        #expect(error.errorDescription?.contains("won't replace") == true)
    }
}
