import Testing
import Foundation
@testable import CraneKit

struct StatsTests {
    // Real `container stats --no-stream --format json crane-test` output.
    static let statsJSON = """
    [{"blockReadBytes":1744896,"blockWriteBytes":0,"cpuUsageUsec":3785,"id":"crane-test","memoryLimitBytes":1073741824,"memoryUsageBytes":2007040,"networkRxBytes":11953,"networkTxBytes":602,"numProcesses":1}]
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

    @Test func memoryFractionGuardsZeroLimit() {
        // A zero memory limit must not divide-by-zero — it reports 0.
        let json = """
        [{"id":"x","memoryUsageBytes":1000,"memoryLimitBytes":0,"cpuUsageUsec":0,"numProcesses":1,"blockReadBytes":0,"blockWriteBytes":0,"networkRxBytes":0,"networkTxBytes":0}]
        """
        let s = StatsDecoding.decode(from: Data(json.utf8)).first
        #expect(s?.memoryFraction == 0)
    }

    @Test func emptyDecodesEmpty() {
        #expect(StatsDecoding.decode(from: Data("[]".utf8)).isEmpty)
        #expect(StatsDecoding.decode(from: Data()).isEmpty)
    }
}
