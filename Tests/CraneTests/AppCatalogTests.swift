import Testing
import Foundation
@testable import CraneKit

struct AppCatalogTests {

    @Test func catalogLoadsFromTemplatesFolder() {
        #expect(AppCatalog.directory != nil) // templates/ found (dev tree or bundle)
        #expect(AppCatalog.all.count >= 10)  // loaded the folder contents
    }

    @Test func templateIDsAreUnique() {
        let ids = AppCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func generatorsProduceExpectedShapes() {
        #expect(Generator.parse("password:12").value().count == 12)
        #expect(UUID(uuidString: Generator.parse("uuid").value()) != nil)        // a real UUID
        #expect(Data(base64Encoded: Generator.parse("base64:16").value())?.count == 16) // 16 bytes
        #expect(Generator.parse(nil).isGenerated == false)
        // Two generated secrets must differ (not a constant).
        #expect(Generator.parse("password:20").value() != Generator.parse("password:20").value())
    }

    @Test func everyTemplateComposeParsesWithServices() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for t in AppCatalog.all {
            let project = try ComposeParsing.parse(yaml: t.compose, baseDir: tmp, projectNameOverride: t.id)
            #expect(!project.services.isEmpty, "\(t.id) produced no services")
        }
    }

    /// Every ${VAR} placeholder in a template's compose must have a declared variable,
    /// otherwise the deploy form can't populate it (typo guard).
    @Test func placeholdersHaveDeclaredVariables() {
        // PROJECT is injected by the deploy engine (composite DNS names), not a user variable.
        let builtins: Set<String> = ["PROJECT"]
        for t in AppCatalog.all {
            let declared = Set(t.variables.map(\.key)).union(builtins)
            for ref in placeholders(in: t.compose) {
                #expect(declared.contains(ref), "\(t.id): ${\(ref)} has no matching variable")
            }
        }
    }

    @Test func primaryPortKeyExists() {
        for t in AppCatalog.all where t.primaryPortKey != nil {
            #expect(t.variables.contains { $0.key == t.primaryPortKey })
        }
    }

    @Test func generatedSecretsAreRandomAndNonEmpty() {
        #expect(Secrets.token() != Secrets.token())
        #expect(Secrets.token(16).count == 16)
    }

    // Extract NAME from each ${NAME} / ${NAME:-default} occurrence.
    private func placeholders(in yaml: String) -> Set<String> {
        var result = Set<String>()
        var rest = Substring(yaml)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            let inner = rest[open.upperBound..<close]
            let name = inner.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { result.insert(String(name)) }
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}
