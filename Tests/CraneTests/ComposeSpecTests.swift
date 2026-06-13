import Testing
import Foundation
@testable import CraneKit

/// Conformance tests for Crane's Compose parser. Inputs and expectations are derived from the
/// upstream Compose loader tests in compose-spec/compose-go (Apache-2.0) — e.g.
/// `TestLoadWithDependsOn` and `TestLoadWithInterpolationCastFull` — so our subset matches how
/// the reference implementation interprets the spec. Written test-first (TDD).
struct ComposeSpecTests {
    private let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    // MARK: healthcheck

    @Test func parsesHealthcheckLongForm() throws {
        let yaml = """
        services:
          web:
            image: nginx
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost"]
              interval: 30s
              timeout: 5s
              retries: 3
              start_period: 10s
        """
        let web = try #require(try ComposeParsing.parse(yaml: yaml, baseDir: tmp).services.first)
        let hc = try #require(web.healthcheck)
        #expect(hc.test == ["CMD", "curl", "-f", "http://localhost"])
        #expect(hc.interval == "30s")
        #expect(hc.timeout == "5s")
        #expect(hc.retries == 3)
        #expect(hc.startPeriod == "10s")
        #expect(hc.disable == false)
    }

    @Test func parsesHealthcheckShellStringAndDisable() throws {
        // compose-go TestLoadWithInterpolationCastFull covers `retries` + `disable: true`.
        let yaml = """
        services:
          a:
            image: x
            healthcheck:
              test: curl -f http://localhost/health
          b:
            image: y
            healthcheck:
              disable: true
        """
        let p = try ComposeParsing.parse(yaml: yaml, baseDir: tmp)
        let a = try #require(p.services.first { $0.name == "a" })
        // A bare string test becomes a CMD-SHELL invocation per the spec.
        #expect(a.healthcheck?.test == ["CMD-SHELL", "curl -f http://localhost/health"])
        let b = try #require(p.services.first { $0.name == "b" })
        #expect(b.healthcheck?.disable == true)
    }

    // MARK: depends_on (long form with condition + required)

    @Test func parsesDependsOnConditionsAndRequired() throws {
        // Input + expectations from compose-go's TestLoadWithDependsOn.
        let yaml = """
        services:
          foo:
            image: nginx
            depends_on:
              bar:
                condition: service_started
              baz:
                condition: service_healthy
                required: false
              qux:
                condition: service_completed_successfully
                required: true
        """
        let foo = try #require(try ComposeParsing.parse(yaml: yaml, baseDir: tmp).services.first { $0.name == "foo" })
        #expect(Set(foo.dependsOn) == ["bar", "baz", "qux"])  // names drive startup order
        #expect(foo.dependencies["bar"] == ServiceDependency(condition: "service_started", required: true))
        #expect(foo.dependencies["baz"] == ServiceDependency(condition: "service_healthy", required: false))
        #expect(foo.dependencies["qux"] == ServiceDependency(condition: "service_completed_successfully", required: true))
    }

    @Test func parsesDependsOnShortForm() throws {
        let yaml = """
        services:
          app:
            image: app
            depends_on:
              - db
          db:
            image: postgres
        """
        let app = try #require(try ComposeParsing.parse(yaml: yaml, baseDir: tmp).services.first { $0.name == "app" })
        #expect(app.dependsOn == ["db"])
        #expect(app.dependencies.isEmpty)  // short form carries no condition/required
    }

    // MARK: restart

    @Test func parsesRestartPolicy() throws {
        let yaml = """
        services:
          web:
            image: nginx
            restart: unless-stopped
        """
        let web = try #require(try ComposeParsing.parse(yaml: yaml, baseDir: tmp).services.first)
        #expect(web.restart == "unless-stopped")
    }

    @Test func restartDefaultsToNil() throws {
        let yaml = """
        services:
          web:
            image: nginx
        """
        let web = try #require(try ComposeParsing.parse(yaml: yaml, baseDir: tmp).services.first)
        #expect(web.restart == nil)
    }

    // MARK: resource limits → --memory / --cpus

    @Test func parsesShortFormMemLimitAndCpus() throws {
        let yaml = """
        services:
          db:
            image: postgres
            mem_limit: 4g
            cpus: 2
        """
        let db = try #require(try ComposeParsing.parse(yaml: yaml, baseDir: tmp).services.first)
        #expect(db.memory == "4G")   // lowercase unit normalized to what Apple `container` wants
        #expect(db.cpus == "2")
    }

    @Test func parsesDeployResourceLimits() throws {
        let yaml = """
        services:
          db:
            image: postgres
            deploy:
              resources:
                limits:
                  memory: 2g
                  cpus: "1.5"
        """
        let db = try #require(try ComposeParsing.parse(yaml: yaml, baseDir: tmp).services.first)
        #expect(db.memory == "2G")
        #expect(db.cpus == "1.5")
    }

    // MARK: error & edge cases

    @Test func throwsWhenNoServices() {
        #expect(throws: (any Error).self) {
            try ComposeParsing.parse(yaml: "version: \"3\"\n", baseDir: tmp)
        }
    }

    @Test func dependencyCycleStillTerminates() throws {
        // a → b → a. startupOrder must not infinite-loop and must include both services.
        let yaml = """
        services:
          a:
            image: a
            depends_on: [b]
          b:
            image: b
            depends_on: [a]
        """
        let project = try ComposeParsing.parse(yaml: yaml, baseDir: tmp)
        #expect(Set(project.startupOrder.map(\.name)) == ["a", "b"])
    }
}
