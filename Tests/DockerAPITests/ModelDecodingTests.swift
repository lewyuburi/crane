import Foundation
import Testing

@testable import DockerAPI

/// Payload shapes captured from a real socktainer 1.2.1 running on Apple `container` 1.2.0,
/// trimmed to what Crane reads. They're the contract this layer is written against.
@Suite("Model decoding")
struct ModelDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("A container summary carries what the list row needs")
    func decodesContainerSummary() throws {
        let summaries = try decode([ContainerSummary].self, """
        [{"Created":1786075710,"Platform":"linux","Mounts":[],
          "Image":"docker.io/library/nginx:alpine",
          "HostConfig":{"NetworkMode":"default"},
          "Command":"/docker-entrypoint.sh nginx -g daemon off;",
          "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web"},
          "Names":["/shop-web-1"],"Status":"Up 3 seconds",
          "ImageID":"sha256:4a73073bd557","Ports":[{"Type":"tcp","PrivatePort":80,"PublicPort":8099,"IP":"0.0.0.0"}],
          "NetworkSettings":{"Networks":{"default":{"IPAddress":"192.168.64.3","Gateway":"192.168.64.1"}}},
          "Id":"b2b9506eb2bb","State":"running"}]
        """)
        let web = try #require(summaries.first)
        #expect(web.id == "b2b9506eb2bb")
        #expect(web.name == "shop-web-1", "the leading slash Docker adds is stripped")
        #expect(web.state == "running")
        #expect(web.ports == [PortBinding(ip: "0.0.0.0", containerPort: 80, hostPort: 8099)])
        #expect(web.addresses["default"] == "192.168.64.3")
        #expect(web.labels["com.docker.compose.service"] == "web")
        #expect(web.created == Date(timeIntervalSince1970: 1_786_075_710))
    }

    @Test("A container missing half its fields still decodes")
    func toleratesSparseSummary() throws {
        let sparse = try decode([ContainerSummary].self, #"[{"Id":"abc","State":"exited"}]"#)
        #expect(sparse.first?.id == "abc")
        #expect(sparse.first?.name == "abc", "with no name, the id stands in")
        #expect(sparse.first?.ports.isEmpty == true)
    }

    @Test("Inspect gives the detail pane its state, config and restart policy")
    func decodesContainerDetail() throws {
        let detail = try decode(ContainerDetail.self, """
        {"Id":"b2b9506eb2bb","Name":"/shop-web-1","Platform":"linux","RestartCount":2,
         "Image":"sha256:4a73073bd557",
         "State":{"Pid":0,"ExitCode":0,"Status":"running","Running":true,"Paused":false,
                  "StartedAt":"2026-08-07T04:08:31.079Z","FinishedAt":"","Error":"",
                  "Health":{"Status":"healthy","FailingStreak":0}},
         "Config":{"Env":["PATH=/usr/bin"],"Cmd":["nginx","-g","daemon off;"],"Tty":false,
                   "User":"","WorkingDir":"/app","Hostname":"shop-web-1","Entrypoint":[]},
         "HostConfig":{"RestartPolicy":{"Name":"unless-stopped","MaximumRetryCount":0}},
         "Mounts":[{"Source":"/Users/dev/app","Destination":"/app","RW":false}]}
        """)
        #expect(detail.name == "shop-web-1")
        #expect(detail.state.running)
        #expect(detail.state.health == "healthy")
        #expect(detail.restartPolicy == "unless-stopped")
        #expect(detail.restartCount == 2)
        #expect(detail.config.workingDirectory == "/app")
        #expect(detail.mounts.first?.readOnly == true)
    }

    @Test("An empty restart policy reads as none, not as a policy named ''")
    func normalizesRestartPolicy() throws {
        let detail = try decode(ContainerDetail.self,
                                #"{"Id":"a","HostConfig":{"RestartPolicy":{"Name":""}}}"#)
        #expect(detail.restartPolicy == nil)
        #expect(detail.state.running == false, "a missing State object is not a running container")
    }

    @Test("Images keep their tags, size and usage count")
    func decodesImages() throws {
        let images = try decode([ImageSummary].self, """
        [{"RepoTags":["docker.io/library/nginx:alpine"],"Containers":1,"Labels":{},
          "Size":57547856,"Id":"sha256:14cea493d9a3","RepoDigests":[],"Created":1757270667}]
        """)
        #expect(images.first?.displayName == "docker.io/library/nginx:alpine")
        #expect(images.first?.size == 57_547_856)
        #expect(images.first?.containers == 1)
    }

    @Test("An untagged image still shows something recognisable")
    func namesUntaggedImages() throws {
        let images = try decode([ImageSummary].self,
                                #"[{"Id":"sha256:abcdef0123456789","RepoTags":["<none>:<none>"]}]"#)
        #expect(images.first?.displayName == "<untagged> abcdef012345")
    }

    @Test("Volumes are unwrapped from their envelope, with their Compose project")
    func decodesVolumes() throws {
        let list = try decode(VolumeList.self, """
        {"Volumes":[{"Name":"shop_db","Driver":"local","Scope":"local",
          "Mountpoint":"/Users/dev/Library/Application Support/com.apple.container/volumes/shop_db/volume.img",
          "CreatedAt":"2026-08-07T04:06:42Z",
          "Labels":{"com.docker.compose.project":"shop","com.docker.compose.volume":"db"}}],
         "Warnings":null}
        """)
        #expect(list.volumes.count == 1)
        #expect(list.volumes.first?.composeProject == "shop")
    }

    @Test("The runtime's built-in network is recognisable, so it isn't offered for deletion")
    func decodesNetworks() throws {
        let networks = try decode([NetworkSummary].self, """
        [{"Id":"default","Name":"default","Driver":"nat","Scope":"local","Internal":false,
          "Subnet":"192.168.64.0/24","Gateway":"192.168.64.1",
          "Containers":{"web":{"Name":"web","IPv4Address":"192.168.64.3/24"}},
          "Labels":{"com.apple.container.resource.role":"builtin"}},
         {"Id":"shop_default","Name":"shop_default","Driver":"nat","Labels":{}}]
        """)
        #expect(networks.first?.isBuiltIn == true)
        #expect(networks.first?.attached["web"] == "192.168.64.3/24")
        #expect(networks.last?.isBuiltIn == false)
    }

    @Test("Stats decode and turn into a percentage only with a previous sample")
    func decodesStats() throws {
        let sample = try decode(StatsSample.self, """
        {"cpu_stats":{"system_cpu_usage":8488656040,"online_cpus":8,
          "cpu_usage":{"total_usage":21558000,"usage_in_usermode":21558000}},
         "memory_stats":{"usage":17985536,"limit":1073741824},
         "pids_stats":{"current":6},
         "networks":{"eth0":{"rx_bytes":1024,"tx_bytes":2048},"eth1":{"rx_bytes":1,"tx_bytes":2}},
         "blkio_stats":{"io_service_bytes_recursive":[
            {"op":"read","value":12238848},{"op":"write","value":4096}]}}
        """)
        #expect(sample.memoryUsage == 17_985_536)
        #expect(abs(sample.memoryFraction - 0.01675) < 0.001)
        #expect(sample.processes == 6)
        #expect(sample.networkRx == 1025, "interfaces are summed")
        #expect(sample.blockRead == 12_238_848)
        #expect(sample.cpuPercent(previous: nil) == 0, "one sample can't be a rate")

        let previous = StatsSample(cpuTotal: 21_558_000 - 1_000_000, systemCPU: 8_488_656_040 - 80_000_000,
                                   onlineCPUs: 8)
        // 1e6 / 8e7 of the machine, across 8 cores → 10 %.
        #expect(abs(sample.cpuPercent(previous: previous) - 10) < 0.01)
    }

    @Test("A counter that went backwards doesn't produce a nonsense spike")
    func handlesCounterReset() {
        let now = StatsSample(cpuTotal: 5, systemCPU: 10, onlineCPUs: 4)
        let earlier = StatsSample(cpuTotal: 500, systemCPU: 1000, onlineCPUs: 4)
        #expect(now.cpuPercent(previous: earlier) >= 0)
    }

    @Test("Image references split into name and tag the way the daemon expects")
    func splitsReferences() {
        #expect(DockerClient.splitReference("nginx") == ("nginx", "latest"))
        #expect(DockerClient.splitReference("nginx:alpine") == ("nginx", "alpine"))
        #expect(DockerClient.splitReference("docker.io/library/nginx:1.27") == ("docker.io/library/nginx", "1.27"))
        // A registry port is not a tag.
        #expect(DockerClient.splitReference("registry:5000/app") == ("registry:5000/app", "latest"))
        #expect(DockerClient.splitReference("nginx@sha256:abc") == ("nginx@sha256:abc", ""))
    }

    @Test("Pull progress reports a fraction only when the daemon sends byte counts")
    func decodesPullProgress() throws {
        let downloading = try decode(PullProgress.self,
            #"{"status":"Downloading","id":"a1b2","progressDetail":{"current":50,"total":200}}"#)
        #expect(downloading.fraction == 0.25)
        let plain = try decode(PullProgress.self, #"{"status":"Pulling fs layer","id":"a1b2"}"#)
        #expect(plain.fraction == nil)
    }
}

@Suite("Log framing")
struct LogFrameTests {
    /// Docker's 8-byte header: stream byte, three zeros, then a big-endian length.
    private func frame(_ stream: UInt8, _ text: String) -> Data {
        var data = Data([stream, 0, 0, 0])
        let bytes = Data(text.utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init))
        data.append(bytes)
        return data
    }

    @Test("Frames are split by stream")
    func splitsStreams() {
        var decoder = LogFrameDecoder()
        let chunks = decoder.push(frame(1, "out\n") + frame(2, "err\n"))
        #expect(chunks.map(\.stream) == [.stdout, .stderr])
        #expect(chunks.map(\.text) == ["out\n", "err\n"])
    }

    @Test("A frame split across reads is reassembled")
    func reassemblesAcrossReads() {
        var decoder = LogFrameDecoder()
        let whole = frame(1, "hello world")
        #expect(decoder.push(whole.prefix(10)).isEmpty, "a partial payload yields nothing yet")
        #expect(decoder.push(whole.dropFirst(10)).map(\.text) == ["hello world"])
    }

    @Test("A TTY container's output has no framing to strip")
    func passesThroughTTYOutput() {
        var decoder = LogFrameDecoder(multiplexed: false)
        #expect(decoder.push(Data("plain output".utf8)).map(\.text) == ["plain output"])
    }
}
