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

    @Test func execForwardsInteractiveTtyAndKeepsCommand() {
        // -i/-t are forwarded (so a non-interactive exec gets no spurious TTY); command preserved.
        #expect(DockerCompat.docker(["exec", "-it", "web", "sh"]).plan == .crane(["exec", "-i", "-t", "web", "sh"]))
        #expect(DockerCompat.docker(["exec", "web", "ls", "-la"]).plan == .crane(["exec", "web", "ls", "-la"]))
    }

    @Test func execPreservesFlagsThatBelongToTheCommand() {
        // The trailing `-i` is grep's, not docker's — it must survive; the leading -t is docker's.
        #expect(DockerCompat.docker(["exec", "-t", "web", "grep", "-i", "pat", "f"]).plan
                == .crane(["exec", "-t", "web", "grep", "-i", "pat", "f"]))
    }

    @Test func execWarnsOnUnsupportedEnvFlagAndSwallowsItsValue() {
        let t = DockerCompat.docker(["exec", "-e", "K=V", "web", "sh"])
        #expect(t.plan == .crane(["exec", "web", "sh"]))
        #expect(t.warnings.contains { $0.contains("-e") })
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

    @Test func runPreservesInteractiveTtyCluster() {
        // -i/-t are kept so foreground `crane run` can attach a real TTY (not silently dropped).
        let t = DockerCompat.docker(["run", "-it", "alpine", "sh"])
        #expect(t.plan == .crane(["run", "-i", "-t", "alpine", "sh"]))
        #expect(t.warnings.isEmpty)
    }

    @Test func runConsumesUnsupportedValueFlag() {
        // --gpus takes a value Apple can't honor; consume it so its value isn't read as the image.
        let t = DockerCompat.docker(["run", "--gpus", "all", "nginx"])
        #expect(t.plan == .crane(["run", "nginx"]))
        #expect(t.warnings.contains { $0.contains("--gpus") })
    }

    @Test func runForwardsFlagsAppleSupports() {
        // Apple's `container run` supports --dns/--label/--platform/--mount — forward, don't drop.
        let t = DockerCompat.docker(["run", "--dns", "1.2.3.4", "-l", "a=b", "--platform", "linux/arm64", "nginx"])
        #expect(t.plan == .crane(["run", "--dns", "1.2.3.4", "--label", "a=b", "--platform", "linux/arm64", "nginx"]))
        #expect(t.warnings.isEmpty)
    }

    @Test func createRoutesToCraneCreateNotRun() {
        // docker create must not start the container — it maps to `crane create`, never `crane run`.
        #expect(DockerCompat.docker(["create", "--name", "db", "postgres"]).plan
                == .crane(["create", "--name", "db", "postgres"]))
    }

    @Test func psQuietPassesThrough() {
        #expect(DockerCompat.docker(["ps", "-q"]).plan == .crane(["ps", "-q"]))
        #expect(DockerCompat.docker(["ps", "-aq"]).plan == .crane(["ps", "-a", "-q"]))
    }

    @Test func stopConsumesTimeoutValue() {
        // docker stop -t 30 web : the 30 is the timeout value, not a container id.
        #expect(DockerCompat.docker(["stop", "-t", "30", "web"]).plan == .crane(["stop", "web"]))
    }

    @Test func rmForceThreadsThrough() {
        #expect(DockerCompat.docker(["rm", "-f", "web"]).plan == .crane(["rm", "-f", "web"]))
        #expect(DockerCompat.docker(["rm", "a", "b"]).plan == .crane(["rm", "a", "b"]))
    }

    @Test func runAttachedFormPublish() {
        #expect(DockerCompat.docker(["run", "-p8080:80", "nginx"]).plan
                == .crane(["run", "-p", "8080:80", "nginx"]))
    }

    @Test func runLongInlineForm() {
        #expect(DockerCompat.docker(["run", "--publish=8080:80", "--name=web", "nginx"]).plan
                == .crane(["run", "-p", "8080:80", "--name", "web", "nginx"]))
    }

    @Test func runWarnsOnInlineUnsupportedFlag() {
        let t = DockerCompat.docker(["run", "--network=mynet", "nginx"])
        #expect(t.plan == .crane(["run", "nginx"]))
        #expect(t.warnings.contains { $0.contains("--network") })
    }

    @Test func runWarnsOnMissingValue() {
        let t = DockerCompat.docker(["run", "-e"])
        #expect(t.warnings.contains { $0.contains("-e") && $0.contains("missing") })
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

    @Test func imageRmMapsToImageDelete() {
        #expect(DockerCompat.docker(["image", "rm", "a"]).plan == .container(["image", "delete", "a"]))
    }

    @Test func imageSubcommandsPassThrough() {
        #expect(DockerCompat.docker(["image", "inspect", "nginx"]).plan
                == .container(["image", "inspect", "nginx"]))
    }

    @Test func tagMapsToImageTag() {
        // Apple has no top-level `container tag`; it's `container image tag`.
        #expect(DockerCompat.docker(["tag", "src:1", "dst:2"]).plan
                == .container(["image", "tag", "src:1", "dst:2"]))
    }

    @Test func psFilterWarnsInsteadOfBroadening() {
        let t = DockerCompat.docker(["ps", "-q", "--filter", "name=web"])
        #expect(t.plan == .crane(["ps", "-q"]))
        #expect(t.warnings.contains { $0.contains("filter") })
    }

    @Test func bareImageIsAnError() {
        guard case .message(_, let isError) = DockerCompat.docker(["image"]).plan else {
            Issue.record("expected a message"); return
        }
        #expect(isError)
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

    @Test func composeFileInlineForm() {
        #expect(DockerCompat.compose(["--file=stack.yml", "up", "-d"]).plan == .crane(["up", "stack.yml"]))
    }

    @Test func composeUpWithoutDetachWarns() {
        #expect(DockerCompat.compose(["up"]).warnings.isEmpty == false)
        #expect(DockerCompat.compose(["up", "-d"]).warnings.isEmpty)   // detached: no surprise, no warning
    }

    @Test func composeDownMapsToCrane() {
        #expect(DockerCompat.compose(["down"]).plan == .crane(["down"]))
        #expect(DockerCompat.compose(["-f", "stack.yml", "down"]).plan == .crane(["down", "stack.yml"]))
    }

    @Test func composeDownHonorsProjectName() {
        // -p foo names the target directly; tearing down `foo`, not the default/file project.
        #expect(DockerCompat.compose(["-p", "foo", "down"]).plan == .crane(["down", "foo"]))
        #expect(DockerCompat.compose(["down", "--project-name=foo"]).plan == .crane(["down", "foo"]))
    }

    @Test func composeUpTargetsRequestedServices() {
        // `compose up worker` must NOT start the whole project.
        #expect(DockerCompat.compose(["up", "worker", "-d"]).plan == .crane(["up", ".", "--service", "worker"]))
        #expect(DockerCompat.compose(["-f", "s.yml", "up", "worker", "db", "-d"]).plan
                == .crane(["up", "s.yml", "--service", "worker", "--service", "db"]))
    }

    @Test func composeUpWarnsWhenProjectNameOverridden() {
        let t = DockerCompat.compose(["-p", "foo", "up", "-d"])
        #expect(t.plan == .crane(["up"]))
        #expect(t.warnings.contains { $0.contains("-p") })
    }

    @Test func composeLogsIsHonestlyUnsupported() {
        guard case .message(_, let isError) = DockerCompat.compose(["logs", "web"]).plan else {
            Issue.record("expected a message"); return
        }
        #expect(isError)
    }
}
