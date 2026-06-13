import Testing
import Foundation
@testable import Crane

struct ComposeTests {
    static let yaml = """
    name: myapp
    services:
      web:
        image: nginx:latest
        ports:
          - "8080:80"
          - "443:443"
        environment:
          FOO: bar
          BAZ: qux
        volumes:
          - ./html:/usr/share/nginx/html:ro
        depends_on:
          - db
      db:
        image: postgres:16
        environment:
          - POSTGRES_PASSWORD=secret
        volumes:
          - dbdata:/var/lib/postgresql/data
    volumes:
      dbdata:
    """

    private func project() throws -> ComposeProject {
        try ComposeParsing.parse(yaml: Self.yaml, baseDir: URL(fileURLWithPath: "/proj"))
    }

    @Test func parsesProjectAndServices() throws {
        let p = try project()
        #expect(p.name == "myapp")
        #expect(p.services.count == 2)
        #expect(p.namedVolumes == ["dbdata"])
    }

    @Test func parsesWebService() throws {
        let web = try #require(try project().services.first { $0.name == "web" })
        #expect(web.image == "nginx:latest")
        #expect(web.ports == ["8080:80", "443:443"])
        #expect(web.environment == ["BAZ=qux", "FOO=bar"]) // map sorted by key
        #expect(web.volumes == ["/proj/html:/usr/share/nginx/html:ro"]) // relative resolved
        #expect(web.dependsOn == ["db"])
    }

    @Test func envListFormAndNamedVolume() throws {
        let db = try #require(try project().services.first { $0.name == "db" })
        #expect(db.environment == ["POSTGRES_PASSWORD=secret"])
        #expect(db.volumes == ["dbdata:/var/lib/postgresql/data"]) // named volume unchanged
    }

    @Test func startupOrderRespectsDependsOn() throws {
        let order = try project().startupOrder.map(\.name)
        #expect(order.firstIndex(of: "db")! < order.firstIndex(of: "web")!)
    }

    @Test func interpolatesVariables() throws {
        let yaml = """
        services:
          web:
            image: nginx:${TAG:-latest}
            ports:
              - "${SERVER_PORT:-8080}:80"
            environment:
              MODE: ${MODE-prod}
        """
        let p = try ComposeParsing.parse(yaml: yaml, baseDir: URL(fileURLWithPath: "/p"))
        let web = try #require(p.services.first)
        #expect(web.image == "nginx:latest")          // default used
        #expect(web.ports == ["8080:80"])             // default used
        #expect(web.environment == ["MODE=prod"])     // unset → default
    }

    @Test func interpolateUnit() {
        let vars = ["FOO": "bar", "EMPTY": ""]
        #expect(ComposeParsing.interpolate("${FOO}", vars) == "bar")
        #expect(ComposeParsing.interpolate("${MISSING:-def}", vars) == "def")
        #expect(ComposeParsing.interpolate("${EMPTY:-def}", vars) == "def")
        #expect(ComposeParsing.interpolate("$FOO/x", vars) == "bar/x")
        #expect(ComposeParsing.interpolate("a$$b", vars) == "a$b")
    }

    @Test func parsesBuildShortAndLongForm() throws {
        let yaml = """
        services:
          a:
            build: ./svc-a
          b:
            build:
              context: ./svc-b
              dockerfile: Dockerfile.prod
              args:
                VERSION: "2"
        """
        let p = try ComposeParsing.parse(yaml: yaml, baseDir: URL(fileURLWithPath: "/proj"))
        let a = try #require(p.services.first { $0.name == "a" })
        #expect(a.build?.context == "/proj/svc-a")
        #expect(a.runImage(project: "proj") == "proj-a")  // built tag
        let b = try #require(p.services.first { $0.name == "b" })
        #expect(b.build?.context == "/proj/svc-b")
        #expect(b.build?.dockerfile == "/proj/svc-b/Dockerfile.prod")
        #expect(b.build?.args == ["VERSION=2"])
    }

    @Test func runArgumentsForWeb() throws {
        let web = try #require(try project().services.first { $0.name == "web" })
        #expect(web.runArguments(project: "myapp") == [
            "--detach", "--name", "myapp-web", "--network", "myapp",
            "--label", "com.docker.compose.project=myapp",
            "--label", "com.docker.compose.service=web",
            "--publish", "8080:80", "--publish", "443:443",
            "--env", "BAZ=qux", "--env", "FOO=bar",
            "--volume", "/proj/html:/usr/share/nginx/html:ro",
            "nginx:latest",
        ])
    }
}
