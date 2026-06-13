import Testing
import Foundation
@testable import Crane

struct StatsMachineTests {
    // Real `container stats --no-stream --format json crane-test` output.
    static let statsJSON = """
    [{"blockReadBytes":1744896,"blockWriteBytes":0,"cpuUsageUsec":3785,"id":"crane-test","memoryLimitBytes":1073741824,"memoryUsageBytes":2007040,"networkRxBytes":11953,"networkTxBytes":602,"numProcesses":1}]
    """

    // Real `container machine list --format json` output.
    static let machineJSON = """
    [{"createdDate":"2026-06-12T18:06:31Z","memory":8589934592,"ipAddress":"192.168.64.3","default":true,"cpus":4,"diskSize":78647296,"status":"running","id":"crane-mac"}]
    """

    @Test func decodesStats() throws {
        let stats = try #require(StatsDecoding.decode(from: Data(Self.statsJSON.utf8)).first)
        #expect(stats.id == "crane-test")
        #expect(stats.cpuUsageUsec == 3785)
        #expect(stats.memoryUsageBytes == 2007040)
        #expect(stats.memoryLimitBytes == 1073741824)
        #expect(stats.numProcesses == 1)
        #expect(abs(stats.memoryFraction - 0.00187) < 0.001)
    }

    @Test func decodesMachine() throws {
        let machine = try #require(MachineDecoding.decode(from: Data(Self.machineJSON.utf8)).first)
        #expect(machine.id == "crane-mac")
        #expect(machine.status == "running")
        #expect(machine.isRunning)
        #expect(machine.ipAddress == "192.168.64.3")
        #expect(machine.cpus == 4)
        #expect(machine.memoryBytes == 8589934592)
        #expect(machine.isDefault)
    }

    @Test func emptyDecodesEmpty() {
        #expect(StatsDecoding.decode(from: Data("[]".utf8)).isEmpty)
        #expect(MachineDecoding.decode(from: Data()).isEmpty)
    }
}
