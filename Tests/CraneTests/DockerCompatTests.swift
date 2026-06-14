import Testing
@testable import CraneKit

/// The docker / docker-compose compatibility translator is pure, so it's exercised entirely
/// in-process: given a docker-style argv it must produce the right Crane/container plan and
/// surface honest warnings for anything Apple's runtime can't do.
struct DockerCompatTests {

    // MARK: - docker: simple verbs map to our own subcommands

    @Test func psMapsToCrane() {
        #expect(DockerCompat.docker(["ps"]).plan == .crane(["ps"]))
    }

    @Test func psAllPassesThroughTheFlag() {
        #expect(DockerCompat.docker(["ps", "-a"]).plan == .crane(["ps", "-a"]))
        #expect(DockerCompat.docker(["ps", "--all"]).plan == .crane(["ps", "-a"]))
    }

    @Test func imagesMapsToCrane() {
        #expect(DockerCompat.docker(["images"]).plan == .crane(["images"]))
        #expect(DockerCompat.docker(["image", "ls"]).plan == .crane(["images"]))
    }

    @Test func logsTranslatesFollowAndTail() {
        #expect(DockerCompat.docker(["logs", "web"]).plan == .crane(["logs", "web"]))
        #expect(DockerCompat.docker(["logs", "-f", "web"]).plan == .crane(["logs", "-f", "web"]))
        #expect(DockerCompat.docker(["logs", "--tail", "50", "web"]).plan
                == .crane(["logs", "--tail", "50", "web"]))
    }

    @Test func startStopRmCollectIds() {
        #expect(DockerCompat.docker(["start", "a", "b"]).plan == .crane(["start", "a", "b"]))
        #expect(DockerCompat.docker(["stop", "a"]).plan == .crane(["stop", "a"]))
        #expect(DockerCompat.docker(["rm", "a", "b"]).plan == .crane(["rm", "a", "b"]))
    }

    @Test func execDropsInteractiveTtyAndKeepsCommand() {
        #expect(DockerCompat.docker(["exec", "-it", "web", "sh"]).plan == .crane(["exec", "web", "sh"]))
        #expect(DockerCompat.docker(["exec", "web", "ls", "-la"]).plan == .crane(["exec", "web", "ls", "-la"]))
    }

    // MARK: - docker run flag translation

    @Test func runBasic() {
        #expect(DockerCompat.docker(["run", "nginx"]).plan == .crane(["run", "nginx"]))
    }

    @Test func runTranslatesCommonFlags() {
        let t = DockerCompat.docker([
            "run", "-d", "--rm", "--name", "web", "-p", "8080:80", "-e", "K=V", "-v", "/h:/c", "nginx",
        ])
        #expect(t.plan == .crane([
            "run", "-d", "--rm", "--name", "web", "-p", "8080:80", "-e", "K=V", "-v", "/h:/c", "nginx",
        ]))
        #expect(t.warnings.isEmpty)
    }

    @Test func runTranslatesResourceFlags() {
        #expect(DockerCompat.docker(["run", "-m", "512m", "--cpus", "2", "nginx"]).plan
                == .crane(["run", "--memory", "512m", "--cpus", "2", "nginx"]))
    }

    @Test func runKeepsImageCommandAfterFlags() {
        #expect(DockerCompat.docker(["run", "--rm", "alpine", "echo", "hi"]).plan
                == .crane(["run", "--rm", "alpine", "echo", "hi"]))
    }

    @Test func runDropsInteractiveTtyClusterSilently() {
        let t = DockerCompat.docker(["run", "-it", "alpine", "sh"])
        #expect(t.plan == .crane(["run", "alpine", "sh"]))
        #expect(t.warnings.isEmpty)   // -i/-t are not errors, just no-ops here
    }

    @Test func runAttachedFormPublish() {
        #expect(DockerCompat.docker(["run", "-p8080:80", "nginx"]).plan
                == .crane(["run", "-p", "8080:80", "nginx"]))
    }

    @Test func runWarnsAndDropsUnsupportedAddHost() {
        let t = DockerCompat.docker(["run", "--add-host", "db:1.2.3.4", "nginx"])
        #expect(t.plan == .crane(["run", "nginx"]))
        #expect(t.warnings.contains { $0.contains("--add-host") })
    }

    @Test func runWarnsOnUnsupportedNetwork() {
        let t = DockerCompat.docker(["run", "--network", "mynet", "nginx"])
        #expect(t.plan == .crane(["run", "nginx"]))
        #expect(t.warnings.contains { $0.contains("--network") })
    }

    // MARK: - docker: passthrough to the Apple container binary

    @Test func buildPassesThrough() {
        #expect(DockerCompat.docker(["build", "-t", "me:1", "."]).plan
                == .container(["build", "-t", "me:1", "."]))
    }

    @Test func pullMapsToImagePull() {
        #expect(DockerCompat.docker(["pull", "nginx"]).plan == .container(["image", "pull", "nginx"]))
    }

    @Test func pushMapsToImagePush() {
        #expect(DockerCompat.docker(["push", "me:1"]).plan == .container(["image", "push", "me:1"]))
    }

    @Test func rmiMapsToImageDelete() {
        #expect(DockerCompat.docker(["rmi", "a", "b"]).plan == .container(["image", "delete", "a", "b"]))
    }

    // MARK: - docker: honest messages

    @Test func emptyArgsShowsHelp() {
        guard case .message(_, let isError) = DockerCompat.docker([]).plan else {
            Issue.record("expected a help message"); return
        }
        #expect(isError == false)
    }

    @Test func unknownCommandIsAnError() {
        guard case .message(let text, let isError) = DockerCompat.docker(["swarm", "init"]).plan else {
            Issue.record("expected an error message"); return
        }
        #expect(isError)
        #expect(text.contains("swarm"))
    }

    // MARK: - compose

    @Test func composeUpMapsToCrane() {
        #expect(DockerCompat.compose(["up"]).plan == .crane(["up"]))
        #expect(DockerCompat.compose(["up", "-d"]).plan == .crane(["up"]))  // we always detach
    }

    @Test func composeUpWithFileForwardsPath() {
        #expect(DockerCompat.compose(["-f", "stack.yml", "up", "-d"]).plan == .crane(["up", "stack.yml"]))
        #expect(DockerCompat.compose(["up", "-f", "stack.yml"]).plan == .crane(["up", "stack.yml"]))
    }

    @Test func composeDownMapsToCrane() {
        #expect(DockerCompat.compose(["down"]).plan == .crane(["down"]))
        #expect(DockerCompat.compose(["-f", "stack.yml", "down"]).plan == .crane(["down", "stack.yml"]))
    }

    @Test func composeLogsIsHonestlyUnsupported() {
        guard case .message(_, let isError) = DockerCompat.compose(["logs", "web"]).plan else {
            Issue.record("expected a message"); return
        }
        #expect(isError)
    }
}
