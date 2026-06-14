import Testing
import Foundation
@testable import CraneKit
@testable import CraneApp

/// An in-memory ContainerControlling that records calls, so AppModel's orchestration can be
/// tested without shelling out to the real `container` binary.
actor FakeCLI: ContainerControlling {
    enum Failure: Error { case boom }

    var installed = true
    var systemRunning = true
    var dnsDomain: String? = "crane"
    var containers: [Container] = []
    var volumes: [Volume] = []
    var networks: [Network] = []
    var images: [ContainerImage] = []
    var failOnRun = false
    var failLists = false
    var failDeletes = false

    private(set) var runContainerCount = 0
    private(set) var runDetachedArgs: [[String]] = []
    private(set) var createStoppedArgs: [[String]] = []
    private(set) var startedIDs: [String] = []
    private(set) var stoppedIDs: [String] = []
    private(set) var deletedIDs: [String] = []
    private(set) var networksCreated: [String] = []
    private(set) var execTargets: [String] = []
    private(set) var execCommands: [[String]] = []

    func setContainers(_ c: [Container]) { containers = c }
    func setImages(_ i: [ContainerImage]) { images = i }
    func setVolumes(_ v: [Volume]) { volumes = v }
    func setNetworks(_ n: [Network]) { networks = n }
    func setFailOnRun(_ f: Bool) { failOnRun = f }
    func setFailLists(_ f: Bool) { failLists = f }
    func setInstalled(_ i: Bool) { installed = i }
    func setDNSDomain(_ d: String?) { dnsDomain = d }

    var isInstalled: Bool { installed }
    func isSystemRunning() -> Bool { systemRunning }
    func systemStart() throws {}
    func listContainers() throws -> [Container] { if failLists { throw Failure.boom }; return containers }
    func runContainer(_ spec: RunSpec) throws {
        if failOnRun { throw Failure.boom }
        runContainerCount += 1
    }
    func start(id: String) throws {
        startedIDs.append(id)
        // Simulate the container coming up, so a retry loop converges instead of spinning.
        if let i = containers.firstIndex(where: { $0.id == id }) { containers[i].status = .running }
    }
    func stop(id: String) throws { stoppedIDs.append(id) }
    func delete(id: String) throws { if failDeletes { throw Failure.boom }; deletedIDs.append(id) }
    func setFailDeletes(_ f: Bool) { failDeletes = f }
    func runDetached(arguments: [String]) throws {
        if failOnRun { throw Failure.boom }
        runDetachedArgs.append(arguments)
    }
    func createStopped(arguments: [String]) throws { createStoppedArgs.append(arguments) }
    @discardableResult func exec(id: String, command: [String]) throws -> Data {
        execTargets.append(id); execCommands.append(command); return Data()
    }
    func listImages() throws -> [ContainerImage] { if failLists { throw Failure.boom }; return images }
    func deleteImages(references: [String]) throws {}
    func pruneImages() throws {}
    func pruneContainers() throws {}
    func createNetworkIfNeeded(_ name: String) { networksCreated.append(name) }
    func createVolumeIfNeeded(_ name: String) {}
    func buildImage(_ build: ComposeBuild, tag: String) throws {}
    func configuredDNSDomain() -> String? { dnsDomain }
    func listVolumes() throws -> [Volume] { volumes }
    func createVolume(name: String, size: String?) throws {}
    func deleteVolume(name: String) throws {}
    func pruneVolumes() throws {}
    func listNetworks() throws -> [Network] { networks }
    func createNetwork(name: String, subnet: String?) throws {}
    func deleteNetwork(name: String) throws {}
    func diskUsage() -> DiskUsage? { nil }
}

@MainActor
struct AppModelTests {

    @Test func setResourcesReRunsWhenRunning() async {
        let fake = FakeCLI()
        let model = AppModel(cli: fake)
        await model.setResources(Container(id: "c1", image: "nginx", status: .running), memory: "2G", cpus: 2)

        #expect(await fake.stoppedIDs == ["c1"])
        #expect(await fake.deletedIDs == ["c1"])
        let runs = await fake.runDetachedArgs
        #expect(runs.count == 1)
        #expect(runs[0].contains("--memory") && runs[0].contains("2G"))
        #expect(await fake.createStoppedArgs.isEmpty)   // not "create" — it was running
    }

    @Test func setResourcesCreatesStoppedWhenStopped() async {
        let fake = FakeCLI()
        let model = AppModel(cli: fake)
        await model.setResources(Container(id: "c1", image: "nginx", status: .stopped), memory: "4G", cpus: 1)

        let creates = await fake.createStoppedArgs
        #expect(creates.count == 1)                       // recreated WITHOUT starting
        #expect(creates[0].contains("--memory") && creates[0].contains("4G") && creates[0].contains("--cpus"))
        #expect(await fake.runDetachedArgs.isEmpty)
    }

    @Test func bulkActionsHitEachID() async {
        let fake = FakeCLI()
        let model = AppModel(cli: fake)
        await model.bulkDelete(["a", "b", "c"])
        await model.bulkStart(["x"])
        await model.bulkStop(["y", "z"])
        #expect(await fake.deletedIDs == ["a", "b", "c"])
        #expect(await fake.startedIDs == ["x"])
        #expect(await fake.stoppedIDs == ["y", "z"])
    }

    @Test func bulkReportsAllFailures() async {
        let fake = FakeCLI()
        await fake.setFailDeletes(true)
        let model = AppModel(cli: fake)
        await model.bulkDelete(["a", "b"])
        // Not swallowed, and reflects that more than one failed (not just the last).
        #expect(model.errorMessage?.contains("2 of 2") == true)
    }

    @Test func singleActionsRouteToCLI() async {
        let fake = FakeCLI()
        let model = AppModel(cli: fake)
        let c = Container(id: "solo", image: "nginx", status: .running)
        await model.start(c); await model.stop(c); await model.delete(c)
        #expect(await fake.startedIDs == ["solo"])
        #expect(await fake.stoppedIDs == ["solo"])
        #expect(await fake.deletedIDs == ["solo"])
    }

    @Test func composeDownDeletesOnlyProjectContainers() async {
        let fake = FakeCLI()
        await fake.setContainers([
            Container(id: "stk-app", image: "a", status: .running, labels: ["com.docker.compose.project": "stk"]),
            Container(id: "stk-db", image: "p", status: .running, labels: ["com.docker.compose.project": "stk"]),
            Container(id: "other", image: "x", status: .running, labels: ["com.docker.compose.project": "zzz"]),
        ])
        let model = AppModel(cli: fake)
        await model.refreshContainers()
        await model.composeDown("stk")
        #expect(await fake.deletedIDs == ["stk-app", "stk-db"])  // sorted by id, project-scoped
    }

    @Test func deleteComposeProjectRemovesContainersAndUntracks() async {
        let fake = FakeCLI()
        await fake.setContainers([
            Container(id: "stk-app", image: "a", status: .running, labels: ["com.docker.compose.project": "stk"]),
            Container(id: "stk-db", image: "p", status: .running, labels: ["com.docker.compose.project": "stk"]),
        ])
        let model = AppModel(cli: fake)
        await model.refreshContainers()
        let ref = ComposeProjectRef(path: "/tmp/stk/docker-compose.yml", displayName: "stk", projectName: "stk")
        model.composeProjects = [ref]

        await model.deleteComposeProject("stk", ref: ref)

        #expect(await fake.deletedIDs == ["stk-app", "stk-db"])  // acts on the elements
        #expect(model.composeProjects.isEmpty)                    // and then untracks the group
    }

    @Test func deleteContainerOnlyComposeGroupJustRemovesContainers() async {
        let fake = FakeCLI()
        await fake.setContainers([
            Container(id: "x-app", image: "a", status: .running, labels: ["com.docker.compose.project": "x"]),
        ])
        let model = AppModel(cli: fake)
        await model.refreshContainers()

        await model.deleteComposeProject("x", ref: nil)   // a group that exists only via its containers

        #expect(await fake.deletedIDs == ["x-app"])
    }

    @Test func refreshPopulatesModelFromCLI() async {
        let fake = FakeCLI()
        await fake.setImages([ContainerImage(id: "i1", name: "nginx", tags: ["latest"], references: ["nginx:latest"], size: 100)])
        await fake.setVolumes([Volume(id: "v1", name: "data", driver: "local", format: "ext4", sizeInBytes: 0, source: "/x")])
        await fake.setNetworks([Network(id: "n1", name: "default", mode: "nat", plugin: "vmnet", ipv4Subnet: nil, ipv4Gateway: nil)])
        let model = AppModel(cli: fake)
        await model.refreshImages(); await model.refreshVolumes(); await model.refreshNetworks()
        #expect(model.images.map(\.id) == ["i1"])
        #expect(model.volumes.map(\.name) == ["data"])
        #expect(model.networks.map(\.name) == ["default"])
    }

    @Test func setResourcesFailureSurfacesError() async {
        let fake = FakeCLI()
        await fake.setFailOnRun(true)
        let model = AppModel(cli: fake)
        await model.setResources(Container(id: "c1", image: "nginx", status: .running), memory: "2G", cpus: 1)
        #expect(model.errorMessage != nil)        // the run failure is reported, not swallowed
        #expect(await fake.deletedIDs == ["c1"])   // it had already deleted before re-running
    }

    @Test func runContainerReturnsTrueOnSuccess() async {
        let fake = FakeCLI()
        let model = AppModel(cli: fake)
        let ok = await model.runContainer(RunSpec(image: "nginx"))
        #expect(ok)
        #expect(await fake.runContainerCount == 1)
    }

    @Test func runContainerReturnsFalseAndReportsErrorOnFailure() async {
        let fake = FakeCLI()
        await fake.setFailOnRun(true)
        let model = AppModel(cli: fake)
        let ok = await model.runContainer(RunSpec(image: "nginx"))
        #expect(ok == false)
        #expect(model.errorMessage != nil)
    }

    @Test func refreshImagesEmptiesAndReportsOnFailure() async {
        let fake = FakeCLI()
        await fake.setImages([ContainerImage(id: "i", name: "n", tags: ["t"], references: ["n:t"], size: 1)])
        await fake.setFailLists(true)
        let model = AppModel(cli: fake)
        await model.refreshImages()
        #expect(model.images.isEmpty)             // a failed list doesn't leave stale data un-flagged
        #expect(model.errorMessage != nil)
    }

    @Test func refreshContainersEmptiesWhenNotInstalled() async {
        let fake = FakeCLI()
        await fake.setInstalled(false)
        let model = AppModel(cli: fake)
        await model.refreshContainers()
        #expect(model.containers.isEmpty)
        #expect(model.isSystemRunning == false)
    }

    @Test func composeUpServiceStartsOnlyThatService() async throws {
        let project = try ComposeParsing.parse(yaml: """
        services:
          web:
            image: nginx
          worker:
            image: busybox
        """, baseDir: FileManager.default.temporaryDirectory, projectNameOverride: "multi")
        let fake = FakeCLI()
        let model = AppModel(cli: fake)
        model.composeParsed["multi"] = project   // composeUpService reads the already-parsed project
        await model.composeUpService(project: "multi", service: "web")
        let runs = await fake.runDetachedArgs
        #expect(runs.count == 1)   // only the requested service is started
        #expect(runs[0].firstIndex(of: "--name").map { runs[0][$0 + 1] } == "multi-web")
    }

    @Test func stackRetryRestartsExitedServiceUntilHealthy() async throws {
        let project = try ComposeParsing.parse(yaml: """
        services:
          app:
            image: app
          db:
            image: postgres
        """, baseDir: FileManager.default.temporaryDirectory, projectNameOverride: "stk")
        let fake = FakeCLI()
        // `app` came up but `db` exited at boot (the flaky-DNS case). start() will mark it running.
        await fake.setContainers([
            Container(id: "stk-app", image: "app", status: .running, addresses: ["10.0.0.2"],
                      labels: ["com.docker.compose.project": "stk", "com.docker.compose.service": "app"]),
            Container(id: "stk-db", image: "postgres", status: .stopped, addresses: ["10.0.0.3"],
                      labels: ["com.docker.compose.project": "stk", "com.docker.compose.service": "db"]),
        ])
        let engine = ComposeEngine(cli: fake, retryDelay: .zero)
        for await _ in engine.up(project) {}
        #expect(await fake.startedIDs == ["stk-db"])   // the exited service was restarted, once it converged
    }

    @Test func composeUpStackUsesDefaultNetworkAndCompositeNames() async throws {
        let yaml = """
        services:
          app:
            image: app
            ports: ["3000:3000"]
          db:
            image: postgres
        """
        // The parser derives the project name from the compose file's directory, so name it "stk"
        // (matches how a deployed template's dir name equals its project name).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crane-compose-tests/stk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let ref = ComposeProjectRef(path: file.path, displayName: "stk", projectName: "stk")

        let fake = FakeCLI()
        await fake.setContainers([
            Container(id: "stk-app", image: "app", status: .running, addresses: ["10.0.0.2"],
                      labels: ["com.docker.compose.project": "stk", "com.docker.compose.service": "app"]),
            Container(id: "stk-db", image: "postgres", status: .running, addresses: ["10.0.0.3"],
                      labels: ["com.docker.compose.project": "stk", "com.docker.compose.service": "db"]),
        ])
        let model = AppModel(cli: fake)
        await model.composeUp(ref)

        #expect(await fake.networksCreated.contains("default")) // stacks use the default network
        let runs = await fake.runDetachedArgs
        #expect(runs.count == 2)
        for r in runs {
            let net = r.firstIndex(of: "--network").map { r[$0 + 1] }
            #expect(net == "default")
        }
        let names = Set(runs.compactMap { r in r.firstIndex(of: "--name").map { r[$0 + 1] } })
        #expect(names == ["stk-app", "stk-db"])     // composite, collision-free
        #expect((await fake.startedIDs).isEmpty)     // all healthy → no spurious retry restarts
    }

    @Test func composeUpSingleServiceUsesPerProjectNetwork() async throws {
        let ref = try Self.writeCompose("""
        services:
          web:
            image: nginx
            ports: ["8080:80"]
        """, projectDir: "solo")
        let fake = FakeCLI()
        let model = AppModel(cli: fake)
        await model.composeUp(ref)

        #expect(await fake.networksCreated == ["solo"])   // not "default" — single service isn't a stack
        let run = try #require(await fake.runDetachedArgs.first)
        #expect(run.firstIndex(of: "--name").map { run[$0 + 1] } == "solo-web")
        #expect(run.firstIndex(of: "--network").map { run[$0 + 1] } == "solo")
    }

    @Test func composeUpStackWarnsWhenInternalDNSMissing() async throws {
        let ref = try Self.writeCompose("""
        services:
          app:
            image: app
          db:
            image: postgres
        """, projectDir: "stk2")
        let fake = FakeCLI()
        await fake.setDNSDomain(nil)   // internal DNS not configured
        let model = AppModel(cli: fake)
        await model.composeUp(ref)
        #expect(model.composeLog.contains("Internal DNS not configured"))
    }

    /// Writes a compose file into a dir named `projectDir` (the parser derives the project name
    /// from that dir) and returns a ref pointing at it.
    private static func writeCompose(_ yaml: String, projectDir: String) throws -> ComposeProjectRef {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crane-compose-tests").appendingPathComponent(projectDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return ComposeProjectRef(path: file.path, displayName: projectDir, projectName: projectDir)
    }
}
