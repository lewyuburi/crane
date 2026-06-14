import Testing
import Foundation
@testable import CraneKit

struct TemplateDeployerTests {
    private let fm = FileManager.default

    @Test func materializesComposeAndEnvWithProject() throws {
        let t = try #require(AppCatalog.all.first { $0.id == "postgres" })
        let dir = fm.temporaryDirectory.appendingPathComponent("crane-deploy-test/pg")
        try? fm.removeItem(at: dir)
        let composeURL = try TemplateDeployer.materialize(
            t, project: "pg", values: ["POSTGRES_PASSWORD": "secret", "PORT": "5432"], into: dir)

        #expect(fm.fileExists(atPath: composeURL.path))
        let env = try String(contentsOf: dir.appendingPathComponent(".env"), encoding: .utf8)
        #expect(env.contains("PROJECT=pg"))                 // engine var injected
        #expect(env.contains("POSTGRES_PASSWORD=secret"))
        let compose = try String(contentsOf: composeURL, encoding: .utf8)
        #expect(compose.contains("postgres"))
    }

    @Test func initialValuesGeneratesSecretsAndDefaults() throws {
        let t = try #require(AppCatalog.all.first { $0.id == "postgres" })
        let values = TemplateDeployer.initialValues(t)
        #expect(!(values["POSTGRES_PASSWORD"] ?? "").isEmpty)  // secret auto-generated
        #expect(values["PORT"] == "5432")                       // default preserved
    }
}
