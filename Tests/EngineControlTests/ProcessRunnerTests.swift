import AppleContainer
import Foundation
import Testing

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test("A hung child is killed instead of waited on forever")
    func timesOut() async {
        do {
            _ = try await ProcessRunner.run("/bin/sleep", ["30"], timeout: .milliseconds(400))
            Issue.record("sleep should have been timed out")
        } catch let ProcessRunner.Failure.timedOut(command, seconds) {
            #expect(command.contains("sleep"))
            #expect(seconds > 0)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("A quick command still returns its output")
    func succeedsWithinTimeout() async throws {
        let result = try await ProcessRunner.run("/bin/echo", ["crane"], timeout: .seconds(2))
        #expect(result.succeeded)
        #expect(result.out == "crane")
    }
}
