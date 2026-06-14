import Testing
import Foundation
@testable import CraneKit

struct CraneVersionTests {
    @Test func versionIsSemver() {
        // bundle.sh greps this exact shape out of CraneVersion.swift; keep it a plain x.y.z string.
        #expect(CraneVersion.current.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)
    }
}
