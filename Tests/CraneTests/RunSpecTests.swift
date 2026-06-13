import Testing
@testable import CraneKit

struct RunSpecTests {
    @Test func minimalSpecIsJustImage() {
        var spec = RunSpec(image: "nginx")
        spec.detach = false
        #expect(spec.arguments() == ["nginx"])
    }

    @Test func fullSpecBuildsExpectedFlags() {
        let spec = RunSpec(
            image: "docker.io/library/nginx:latest",
            name: "web",
            command: "nginx -g daemon off;",
            detach: true,
            removeOnExit: true,
            env: ["FOO=bar", "BAZ=qux"],
            ports: ["8080:80"],
            volumes: ["/host:/data"],
            cpus: "2",
            memory: "512M"
        )
        #expect(spec.arguments() == [
            "--detach", "--rm", "--name", "web",
            "--env", "FOO=bar", "--env", "BAZ=qux",
            "--publish", "8080:80",
            "--volume", "/host:/data",
            "--cpus", "2", "--memory", "512M",
            "docker.io/library/nginx:latest",
            "nginx", "-g", "daemon", "off;",
        ])
    }

    @Test func blankEntriesAreSkipped() {
        var spec = RunSpec(image: "alpine")
        spec.detach = false
        spec.env = ["", "  "]
        spec.ports = [""]
        #expect(spec.arguments() == ["alpine"])
    }

    @Test func validityRequiresImage() {
        #expect(RunSpec(image: "").isValid == false)
        #expect(RunSpec(image: "  ").isValid == false)
        #expect(RunSpec(image: "alpine").isValid == true)
    }
}
