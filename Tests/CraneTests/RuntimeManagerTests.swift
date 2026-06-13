import Testing
import Foundation
@testable import CraneKit

struct RuntimeManagerTests {

    @Test func normalizesVersionOutput() {
        // `container --version` prints a noisy line; we want just the semver.
        #expect(RuntimeManager.normalizeVersion("container CLI version 1.0.0 (build: abc123)") == "1.0.0")
        #expect(RuntimeManager.normalizeVersion("  0.12.3\n") == "0.12.3")
        #expect(RuntimeManager.normalizeVersion("") == nil)
        #expect(RuntimeManager.normalizeVersion("dev") == "dev")  // no semver → trimmed fallback
    }

    @Test func parsesGitHubReleases() {
        let json = """
        [{"tag_name":"1.0.0","prerelease":false},
         {"tag_name":"0.99.0","prerelease":true},
         {"name":"no tag here"}]
        """
        let releases = RuntimeManager.parseReleases(from: Data(json.utf8))
        #expect(releases.map(\.version) == ["1.0.0", "0.99.0"])  // entries without a tag are skipped
        #expect(releases[0].isPrerelease == false)
        #expect(releases[1].isPrerelease == true)
    }

    @Test func parseReleasesToleratesGarbage() {
        #expect(RuntimeManager.parseReleases(from: Data("not json".utf8)).isEmpty)
        #expect(RuntimeManager.parseReleases(from: Data("[]".utf8)).isEmpty)
    }

    @Test func validatesVersionTags() {
        #expect(RuntimeManager.isValidVersionTag("1.0.0"))
        #expect(RuntimeManager.isValidVersionTag("0.12.3"))
        #expect(RuntimeManager.isValidVersionTag("v1.2.3"))
        #expect(RuntimeManager.isValidVersionTag("1.2.3-beta.1"))
        // Hostile / malformed tags that must be rejected before becoming a path/URL component.
        #expect(!RuntimeManager.isValidVersionTag("../../etc"))
        #expect(!RuntimeManager.isValidVersionTag("1.0"))
        #expect(!RuntimeManager.isValidVersionTag("latest; rm -rf"))
        #expect(!RuntimeManager.isValidVersionTag(""))
    }

    @Test func runtimeInstallRootIsTwoLevelsUp() {
        let rt = Runtime(binaryPath: "/Apps/Crane/runtimes/1.0.0/bin/container", source: .managed)
        #expect(rt.installRoot == "/Apps/Crane/runtimes/1.0.0")
    }

    @Test func runtimeDisplayName() {
        #expect(Runtime(binaryPath: "/x/bin/container", source: .managed, version: "1.0.0").displayName == "managed · 1.0.0")
        #expect(Runtime(binaryPath: "/y", source: .system, version: nil).displayName == "system · unknown")
    }
}
