import Testing
import Foundation
@testable import Crane

/// Tests for pure, extracted business logic (test-first). These functions were pulled out of
/// file/Process/UI boundaries specifically so they can be unit-tested.
struct PureLogicTests {

    // MARK: ProjectName.sanitize

    @Test func sanitizesProjectNames() {
        #expect(ProjectName.sanitize("My App") == "my-app")
        #expect(ProjectName.sanitize("arcane-raiders") == "arcane-raiders")
        #expect(ProjectName.sanitize("  --Foo_Bar!! ") == "foo-bar")
        #expect(ProjectName.sanitize("Café 123") == "caf-123")
        #expect(ProjectName.sanitize("") == "app")        // fallback for empty
        #expect(ProjectName.sanitize("***") == "app")      // collapses to empty → fallback
    }

    // MARK: ContainerCLI.dnsDomain(inTOML:)

    @Test func readsDNSDomainFromTOML() {
        #expect(ContainerCLI.dnsDomain(inTOML: "[dns]\ndomain = \"crane\"\n") == "crane")
        #expect(ContainerCLI.dnsDomain(inTOML: "[dns]\ndomain = 'test'") == "test")
    }

    @Test func dnsDomainStripsInlineComments() {
        #expect(ContainerCLI.dnsDomain(inTOML: "[dns]\ndomain = \"crane\" # the domain\n") == "crane")
        #expect(ContainerCLI.dnsDomain(inTOML: "[dns]\ndomain = crane # bar\n") == "crane")
    }

    @Test func dnsDomainNilWhenUnsetOrWrongSection() {
        #expect(ContainerCLI.dnsDomain(inTOML: "[container]\ncpus = 4\n") == nil)
        // A `domain` key under another section must NOT be picked up.
        #expect(ContainerCLI.dnsDomain(inTOML: "[registry]\ndomain = \"docker.io\"\n") == nil)
        #expect(ContainerCLI.dnsDomain(inTOML: "") == nil)
    }

    // MARK: TemplateRenderer.envFile

    @Test func rendersEnvFileSortedWithProject() {
        let env = TemplateRenderer.envFile(values: ["B": "2", "A": "1"], project: "stk")
        #expect(env == "A=1\nB=2\nPROJECT=stk\n")  // sorted keys, PROJECT injected
    }

    // MARK: HostsWiring.entries — /etc/hosts lines per container for a project

    @Test func buildsHostsEntriesForSiblings() {
        let members = [
            HostsWiring.Member(containerID: "p-app", service: "app", ip: "10.0.0.2"),
            HostsWiring.Member(containerID: "p-db", service: "db", ip: "10.0.0.3"),
        ]
        let byID = HostsWiring.entries(members: members)
        // app gets db's name + container id mapped to db's ip (not its own)
        #expect(byID["p-app"]?.sorted() == ["10.0.0.3\tdb", "10.0.0.3\tp-db"])
        #expect(byID["p-db"]?.sorted() == ["10.0.0.2\tapp", "10.0.0.2\tp-app"])
    }

    @Test func hostsEntriesEmptyForSingleMember() {
        let one = [HostsWiring.Member(containerID: "x", service: "x", ip: "10.0.0.9")]
        #expect(HostsWiring.entries(members: one).isEmpty)
    }
}
