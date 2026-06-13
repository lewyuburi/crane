import Testing
import Foundation
@testable import CraneKit

struct ComposeLoaderTests {
    private let fm = FileManager.default

    private func makeDir(_ name: String) -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("crane-loader-tests/\(name)")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadsFromDirectoryByConventionalName() throws {
        let dir = makeDir("svc")  // dir name becomes the project name
        try "services:\n  web:\n    image: nginx\n".write(
            to: dir.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)
        let project = try ComposeLoader.load(dir.path)
        #expect(project.name == "svc")
        #expect(project.services.map(\.name) == ["web"])
    }

    @Test func prefersComposeYamlOverDockerComposeYml() throws {
        let dir = makeDir("pref")
        try "services:\n  a:\n    image: a\n".write(
            to: dir.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try "services:\n  b:\n    image: b\n".write(
            to: dir.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)
        let project = try ComposeLoader.load(dir.path)
        #expect(project.services.map(\.name) == ["a"])  // compose.yaml wins
    }

    @Test func loadsFromExplicitFilePath() throws {
        let dir = makeDir("explicit")
        let file = dir.appendingPathComponent("docker-compose.yml")
        try "name: custom\nservices:\n  x:\n    image: x\n".write(to: file, atomically: true, encoding: .utf8)
        let project = try ComposeLoader.load(file.path)
        #expect(project.name == "custom")
    }

    @Test func throwsWhenNoComposeFile() {
        let dir = makeDir("empty")
        #expect(throws: ComposeLoader.LoadError.self) {
            try ComposeLoader.load(dir.path)
        }
    }

    @Test func throwsWhenPathMissing() {
        #expect(throws: ComposeLoader.LoadError.self) {
            try ComposeLoader.load("/no/such/path-xyz")
        }
    }
}
