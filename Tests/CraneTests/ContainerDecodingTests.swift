import Testing
import Foundation
@testable import Crane

/// Fixtures captured from a real `container` 1.0.0 apiserver.
struct ContainerDecodingTests {

    // `container ls --all --format json` with one running alpine container.
    static let runningJSON = """
    [{"configuration":{"id":"crane-test","image":{"descriptor":{"digest":"sha256:a2d4","mediaType":"application/vnd.oci.image.index.v1+json","size":9218},"reference":"docker.io/library/alpine:latest"},"platform":{"architecture":"arm64","os":"linux"},"resources":{"cpuOverhead":1,"cpus":4,"memoryInBytes":1073741824}},"id":"crane-test","status":{"networks":[{"hostname":"crane-test","ipv4Address":"192.168.64.2/24","ipv4Gateway":"192.168.64.1","macAddress":"f6:6e:42:13:4a:16","mtu":1280,"network":"default"}],"startedDate":"2026-06-12T16:10:02Z","state":"running"}}]
    """

    // Same container after `container stop`.
    static let stoppedJSON = """
    [{"configuration":{"id":"crane-test","image":{"reference":"docker.io/library/alpine:latest"},"platform":{"architecture":"arm64","os":"linux"}},"id":"crane-test","status":{"networks":[],"startedDate":"2026-06-12T16:10:02Z","state":"stopped"}}]
    """

    // `container image ls --format json` — same image (id 45cd) tagged twice + a distinct one.
    static let imagesJSON = """
    [{"configuration":{"name":"docker.io/itzg/minecraft-server:java25"},"id":"45cd","variants":[{"size":100}]},
     {"configuration":{"name":"docker.io/itzg/minecraft-server:latest"},"id":"45cd","variants":[{"size":100}]},
     {"configuration":{"descriptor":{"size":9218},"name":"docker.io/library/alpine:latest"},"id":"a2d4","variants":[{"size":4203982}]}]
    """

    @Test func decodesRunningContainer() throws {
        let containers = try ContainerDecoding.decodeContainers(from: Data(Self.runningJSON.utf8))
        let c = try #require(containers.first)
        #expect(c.id == "crane-test")
        #expect(c.status == .running)
        #expect(c.image == "docker.io/library/alpine:latest")
        #expect(c.addresses == ["192.168.64.2"]) // CIDR mask stripped
        #expect(c.os == "linux")
        #expect(c.arch == "arm64")
    }

    @Test func decodesStoppedContainer() throws {
        let containers = try ContainerDecoding.decodeContainers(from: Data(Self.stoppedJSON.utf8))
        let c = try #require(containers.first)
        #expect(c.status == .stopped)
        #expect(c.addresses.isEmpty)
    }

    @Test func groupsImagesByIdAndKeepsTags() throws {
        let images = try ContainerDecoding.decodeImages(from: Data(Self.imagesJSON.utf8))
        #expect(images.count == 2) // two tags of the same id collapse into one row
        let mc = try #require(images.first { $0.id == "45cd" })
        #expect(mc.name == "docker.io/itzg/minecraft-server")
        #expect(Set(mc.tags) == ["java25", "latest"])
        #expect(mc.references.count == 2)
        let alpine = try #require(images.first { $0.id == "a2d4" })
        #expect(alpine.tags == ["latest"])
        #expect(alpine.size == 4203982) // variant size, not the 9218 index size
    }

    // Real output for a container created with -p 8080:80 -p 9090:9090 -l app=demo -l tier=web.
    static let richJSON = """
    [{"configuration":{"id":"crane-rich","image":{"reference":"docker.io/library/alpine:latest"},"platform":{"architecture":"arm64","os":"linux"},"publishedPorts":[{"containerPort":80,"count":1,"hostAddress":"0.0.0.0","hostPort":8080,"proto":"tcp"},{"containerPort":9090,"count":1,"hostAddress":"0.0.0.0","hostPort":9090,"proto":"tcp"}],"mounts":[],"labels":{"app":"demo","tier":"web"}},"id":"crane-rich","status":{"networks":[{"hostname":"crane-rich","ipv4Address":"192.168.64.4/24"}],"state":"running"}}]
    """

    @Test func decodesPortsLabelsHostname() throws {
        let c = try #require(try ContainerDecoding.decodeContainers(from: Data(Self.richJSON.utf8)).first)
        #expect(c.hostname == "crane-rich")
        #expect(c.ports.count == 2)
        #expect(c.ports.first?.hostPort == 8080)
        #expect(c.ports.first?.containerPort == 80)
        #expect(c.ports.first?.proto == "tcp")
        #expect(c.sortedLabels.map(\.key) == ["app", "tier"])
        #expect(c.labels["tier"] == "web")
    }

    // Full config (as `container ls` emits) with resources + initProcess, for recreate.
    static let resourceJSON = """
    [{"configuration":{"id":"mc","image":{"reference":"docker.io/itzg/minecraft-server:latest"},"resources":{"cpus":4,"memoryInBytes":1073741824},"initProcess":{"executable":"/image/scripts/start","arguments":[],"environment":["EULA=TRUE","MEMORY=4G"]},"networks":[{"network":"arcane-raiders"}],"publishedPorts":[{"containerPort":25565,"hostPort":25565,"hostAddress":"0.0.0.0","proto":"tcp"}],"mounts":[{"source":"/host/data","destination":"/data"}],"labels":{"com.docker.compose.project":"arcane-raiders","com.docker.compose.service":"minecraft"}},"id":"mc","status":{"state":"running"}}]
    """

    @Test func decodesResourcesAndProcessForRecreate() throws {
        let c = try #require(try ContainerDecoding.decodeContainers(from: Data(Self.resourceJSON.utf8)).first)
        #expect(c.memoryBytes == 1073741824)
        #expect(c.cpus == 4)
        #expect(c.environment.contains("EULA=TRUE"))
        #expect(c.network == "arcane-raiders")
        #expect(c.entrypoint == "/image/scripts/start")
    }

    @Test func recreateArgumentsPreserveConfigWithNewMemory() throws {
        let c = try #require(try ContainerDecoding.decodeContainers(from: Data(Self.resourceJSON.utf8)).first)
        let args = c.recreateArguments(memory: "6G", cpus: 4)
        #expect(args.contains("--memory"))
        #expect(args.firstIndex(of: "6G") == args.firstIndex(of: "--memory").map { $0 + 1 })
        #expect(args.contains("--network") && args.contains("arcane-raiders"))
        #expect(args.contains("EULA=TRUE"))
        #expect(args.contains("--label") && args.contains("com.docker.compose.project=arcane-raiders"))
        #expect(args.contains("25565:25565/tcp"))
        #expect(args.contains("/host/data:/data"))
        #expect(args.last == "docker.io/itzg/minecraft-server:latest") // image, no extra command
    }

    @Test func injectsHostDNSWhenNoneSpecified() {
        let args = ContainerCLI.withDefaultDNS(["--detach", "--name", "x", "alpine:latest"])
        #expect(args.contains("--dns")) // host resolvers prepended
        #expect(args.firstIndex(of: "--detach")! > args.firstIndex(of: "--dns")!) // DNS before other flags
        #expect(args.last == "alpine:latest") // image still last
    }

    @Test func respectsExplicitDNS() {
        let original = ["--detach", "--dns", "9.9.9.9", "alpine:latest"]
        #expect(ContainerCLI.withDefaultDNS(original) == original) // untouched when caller set --dns
    }

    @Test func hostDNSServersAreReachable() {
        let servers = ContainerCLI.hostDNSServers()
        #expect(!servers.isEmpty)
        #expect(!servers.contains { $0.hasPrefix("127.") }) // loopback filtered out
    }

    @Test func emptyOutputDecodesToEmpty() throws {
        #expect(try ContainerDecoding.decodeContainers(from: Data("[]".utf8)).isEmpty)
        #expect(try ContainerDecoding.decodeContainers(from: Data()).isEmpty)
    }
}
