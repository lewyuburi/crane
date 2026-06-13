import Testing
import Foundation
@testable import CraneKit

struct VolumeNetworkTests {
    static let volumeJSON = """
    [{"configuration":{"creationDate":"2026-06-12T19:24:13Z","driver":"local","format":"ext4","labels":{},"name":"crane-vol","options":{},"sizeInBytes":549755813888,"source":"/path/volume.img"},"id":"crane-vol"}]
    """

    static let networkJSON = """
    [{"configuration":{"creationDate":"2026-06-12T17:00:04Z","labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","options":{},"plugin":"container-network-vmnet"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24","ipv6Subnet":"fd61::/64"}}]
    """

    static let dfJSON = """
    {"containers":{"active":2,"reclaimable":0,"sizeInBytes":457506816,"total":2},"images":{"active":2,"reclaimable":240021504,"sizeInBytes":405753856,"total":3},"volumes":{"active":0,"reclaimable":69390336,"sizeInBytes":69390336,"total":1}}
    """

    @Test func decodesVolume() throws {
        let v = try #require(VolumeNetworkDecoding.decodeVolumes(from: Data(Self.volumeJSON.utf8)).first)
        #expect(v.name == "crane-vol")
        #expect(v.format == "ext4")
        #expect(v.sizeInBytes == 549755813888)
    }

    @Test func decodesNetwork() throws {
        let n = try #require(VolumeNetworkDecoding.decodeNetworks(from: Data(Self.networkJSON.utf8)).first)
        #expect(n.name == "default")
        #expect(n.mode == "nat")
        #expect(n.ipv4Subnet == "192.168.64.0/24")
        #expect(n.ipv4Gateway == "192.168.64.1")
    }

    @Test func decodesDiskUsage() throws {
        let df = try #require(VolumeNetworkDecoding.decodeDiskUsage(from: Data(Self.dfJSON.utf8)))
        #expect(df.images.total == 3)
        #expect(df.images.reclaimableInBytes == 240021504)
        #expect(df.containers.active == 2)
        #expect(df.volumes.total == 1)
    }
}
