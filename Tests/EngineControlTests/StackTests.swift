import Foundation
import Testing

@testable import EngineControl

@Suite("Stack manifest and layout")
struct StackTests {
    let layout = StackLayout(root: URL(fileURLWithPath: "/tmp/crane-test"))

    @Test("Every pinned artifact carries a real SHA-256")
    func manifestIsPinned() {
        for artifact in StackManifest.current.artifacts {
            #expect(artifact.sha256.count == 64, "\(artifact.component) needs a full digest")
            #expect(artifact.sha256 != String(repeating: "0", count: 64),
                    "\(artifact.component) still has a placeholder digest")
            #expect(artifact.url.hasPrefix("https://"), "\(artifact.component) must download over TLS")
            #expect(artifact.url.contains(artifact.version) || artifact.component == .docker,
                    "\(artifact.component)'s URL should pin its version")
        }
    }

    @Test("Versions unpack into their own directory, fronted by a stable symlink")
    func versionedLayout() {
        let socktainer = StackManifest.current.socktainer
        #expect(layout.directory(for: socktainer).path.hasSuffix("stack/socktainer/1.2.1"))
        #expect(layout.executable(for: socktainer).path.hasSuffix("stack/socktainer/1.2.1/socktainer"))
        #expect(layout.link(for: .socktainer).path == "/tmp/crane-test/bin/socktainer")
    }

    @Test("Apple's package keeps its helpers, so its binary lives under bin/")
    func applePackageLayout() {
        #expect(layout.executable(for: StackManifest.current.runtime).path
            .hasSuffix("stack/runtime/1.2.0/bin/container"))
    }

    @Test("The Compose plugin is linked as docker-compose")
    func composeLink() {
        #expect(layout.link(for: .compose).lastPathComponent == "docker-compose")
        #expect(layout.cliPluginsDirectory.path.hasSuffix(".docker/cli-plugins"))
    }
}

@Suite("Trust and version parsing")
struct TrustTests {
    /// Real output from `pkgutil --check-signature` on container-1.2.0-installer-signed.pkg.
    let appleOutput = """
    Package "container.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2026-07-29 01:09:05 +0000
       Certificate Chain:
        1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)
           Expires: 2030-06-04 16:44:29 +0000
    """

    @Test("Apple's own signed package is accepted")
    func acceptsApple() {
        #expect(PackageSignature.isApple(appleOutput, teamID: "UPBK2H6LZM"))
    }

    @Test("Any other developer's Developer ID package is rejected")
    func rejectsOtherDevelopers() {
        let impostor = appleOutput
            .replacingOccurrences(of: "Apple Inc. - Containerization (UPBK2H6LZM)",
                                  with: "Someone Else (ABCDE12345)")
        #expect(!PackageSignature.isApple(impostor, teamID: "UPBK2H6LZM"))
    }

    @Test("A signed but un-notarized package is rejected")
    func requiresNotarization() {
        let stripped = appleOutput.replacingOccurrences(
            of: "   Notarization: trusted by the Apple notary service\n", with: "")
        #expect(!PackageSignature.isApple(stripped, teamID: "UPBK2H6LZM"))
    }

    @Test("Versions are pulled out of each tool's own chatter")
    func parsesVersions() {
        #expect(VersionText.semver(in: "container CLI version 1.2.0 (build: release)") == "1.2.0")
        #expect(VersionText.semver(in: "socktainer: v1.2.1 (git commit: 0169253)") == "1.2.1")
        #expect(VersionText.semver(in: "Docker version 29.7.2, build abc1234") == "29.7.2")
        #expect(VersionText.semver(in: "v5.4.0") == "5.4.0")
        #expect(VersionText.semver(in: "   ") == nil)
    }

    @Test("Versions compare numerically, not alphabetically")
    func comparesVersions() {
        #expect(VersionText.compare("1.10.0", "1.9.0") == .orderedDescending)
        #expect(VersionText.compare("1.2.0", "1.2.0") == .orderedSame)
        #expect(VersionText.compare("1.2", "1.2.0") == .orderedSame)
        #expect(VersionText.compare("1.2.0", "1.2.1") == .orderedAscending)
    }
}

@Suite("Launch agents")
struct LaunchAgentTests {
    @Test("The plist says exactly what launchd needs")
    func plistShape() throws {
        let agent = LaunchAgent(label: "dev.crane.socktainer",
                                program: ["/tmp/bin/socktainer", "--no-docker-context"],
                                runAtLoad: true, keepAlive: true,
                                standardOutPath: "/tmp/logs/socktainer.log")
        let plist = try PropertyListSerialization.propertyList(
            from: agent.plistData(), format: nil) as! [String: Any]
        #expect(plist["Label"] as? String == "dev.crane.socktainer")
        #expect(plist["ProgramArguments"] as? [String] == ["/tmp/bin/socktainer", "--no-docker-context"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 10)
        #expect(plist["StandardOutPath"] as? String == "/tmp/logs/socktainer.log")
        #expect(plist["StandardErrorPath"] == nil, "an unset path shouldn't be written at all")
        #expect(agent.plistURL.path.hasSuffix("Library/LaunchAgents/dev.crane.socktainer.plist"))
    }

    @Test("A job is only running when launchctl prints a pid")
    func readsJobState() {
        #expect(JobState.hasPID(in: "state = running\n\tpid = 4211\n\truntime = 1m"))
        #expect(!JobState.hasPID(in: "state = not running\n\tlast exit code = 0"))
        #expect(!JobState.hasPID(in: "Could not find service in domain"))
    }
}

@Suite("Docker context")
struct DockerContextTests {
    let context = DockerContext(socketPath: "/Users/dev/.socktainer/container.sock",
                                dockerHome: URL(fileURLWithPath: "/tmp/crane-test/.docker"))

    @Test("The context directory is the SHA-256 of its name, as the Docker CLI expects")
    func directoryName() {
        #expect(DockerContext.directoryName(for: "crane")   // sha256("crane")
            == "2c6ac23e4ffdf95f08f369eca6488b585bca0def0ddfe69f525e40d4aa2509d3")
        #expect(context.metaDirectory.path
            .hasSuffix("contexts/meta/\(DockerContext.directoryName(for: "crane"))"))
    }

    @Test("meta.json points the CLI at the socket")
    func metaPayload() throws {
        let json = try JSONSerialization.jsonObject(
            with: DockerContext.metaJSON(socketPath: "/Users/dev/.socktainer/container.sock")) as! [String: Any]
        #expect(json["Name"] as? String == "crane")
        let endpoint = (json["Endpoints"] as? [String: Any])?["docker"] as? [String: Any]
        #expect(endpoint?["Host"] as? String == "unix:///Users/dev/.socktainer/container.sock")
        #expect(endpoint?["SkipTLSVerify"] as? Bool == false)
    }
}
