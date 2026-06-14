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

    @Test func commandArgsPreserveSpacesAndWinOverString() {
        var spec = RunSpec(image: "alpine", commandArgs: ["sh", "-c", "echo hi"])
        spec.detach = false
        // "echo hi" stays a single argument — not split on the space.
        #expect(spec.arguments() == ["alpine", "sh", "-c", "echo hi"])
    }

    @Test func interactiveAndTtyEmitFlags() {
        var spec = RunSpec(image: "alpine", interactive: true, tty: true)
        spec.detach = true
        #expect(spec.arguments() == ["--detach", "--interactive", "--tty", "alpine"])
    }

    @Test func extraArgumentsForwardedBeforeImage() {
        var spec = RunSpec(image: "nginx", extraArguments: ["--dns", "1.2.3.4"])
        spec.detach = false
        #expect(spec.arguments() == ["--dns", "1.2.3.4", "nginx"])
    }
}
