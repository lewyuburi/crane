import DockerAPI
import Foundation
import Testing

@testable import CraneCore

@Suite("Event reducer")
struct ReducerTests {
    private func catalog() -> ContainerCatalog {
        ContainerCatalog([
            Container(id: "web1", name: "shop-web-1", image: "nginx", state: .running,
                      ports: [PortBinding(containerPort: 80, hostPort: 8080)],
                      labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "web"]),
            Container(id: "db1", name: "shop-db-1", image: "postgres", state: .running,
                      labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "db"]),
            Container(id: "solo", name: "scratch", image: "alpine", state: .exited),
        ])
    }

    private func event(_ action: String, _ id: String,
                       _ attributes: [String: String] = [:]) -> DockerEvent {
        DockerEvent(subject: .container, action: action, id: id, attributes: attributes)
    }

    @Test("A die event stops the row without a round-trip")
    func handlesDie() {
        var state = catalog()
        #expect(state.apply(event("die", "web1", ["exitCode": "137"])) == .none)
        #expect(state["web1"]?.state == .exited)
        #expect(state["web1"]?.exitCode == 137)
        #expect(state["web1"]?.statusText == "Exited (137)")
    }

    @Test("A start event needs a refetch, because ports only exist once it's up")
    func startNeedsRefetch() {
        var state = catalog()
        #expect(state.apply(event("start", "db1")) == .reloadContainer(id: "db1"))
        #expect(state["db1"]?.state == .running)
    }

    @Test("A destroyed container disappears and asks for nothing")
    func handlesDestroy() {
        var state = catalog()
        #expect(state.apply(event("destroy", "solo")) == .none)
        #expect(state["solo"] == nil)
        #expect(state.containers.count == 2)
    }

    @Test("An event for a container we've never seen pulls it in")
    func fetchesUnknownContainer() {
        var state = catalog()
        #expect(state.apply(event("create", "brand-new")) == .reloadContainer(id: "brand-new"))
        #expect(state.apply(event("destroy", "brand-new")) == .none,
                "a container we don't have and that just died needs no fetch")
    }

    @Test("Health transitions land on the row")
    func tracksHealth() {
        var state = catalog()
        #expect(state.apply(event("health_status: healthy", "web1")) == .none)
        #expect(state["web1"]?.health == .healthy)
        #expect(state.apply(event("health_status: unhealthy", "web1")) == .none)
        #expect(state["web1"]?.health == .unhealthy)
    }

    @Test("Stopping clears a stale health badge")
    func clearsHealthOnStop() {
        var state = catalog()
        _ = state.apply(event("health_status: healthy", "web1"))
        _ = state.apply(event("die", "web1", ["exitCode": "0"]))
        #expect(state["web1"]?.health == nil, "a stopped container isn't 'healthy'")
    }

    @Test("Exec noise doesn't cost a fetch")
    func ignoresExecNoise() {
        var state = catalog()
        for action in ["exec_create: sh", "exec_start: sh", "exec_die", "attach", "resize"] {
            #expect(state.apply(event(action, "web1")) == .none, "\(action) should be free")
        }
    }

    @Test("A rename keeps the list sorted")
    func handlesRename() {
        var state = catalog()
        #expect(state.apply(event("rename", "solo", ["name": "aardvark"])) == .none)
        #expect(state.containers.map(\.name) == ["aardvark", "shop-db-1", "shop-web-1"])
    }

    @Test("Events about other resources route to their own list")
    func routesBySubject() {
        var state = catalog()
        #expect(state.apply(DockerEvent(subject: .image, action: "pull", id: "nginx")) == .reloadImages)
        #expect(state.apply(DockerEvent(subject: .volume, action: "create", id: "data")) == .reloadVolumes)
        #expect(state.apply(DockerEvent(subject: .network, action: "create", id: "net")) == .reloadNetworks)
        #expect(state.apply(DockerEvent(subject: .daemon, action: "reload", id: "")) == .none)
    }

    @Test("Snapshots replace everything and stay sorted")
    func replacesOnSnapshot() {
        var state = catalog()
        state.replace(with: [Container(id: "z", name: "zeta"), Container(id: "a", name: "alpha")])
        #expect(state.containers.map(\.name) == ["alpha", "zeta"])
    }
}

@Suite("Grouping")
struct GroupingTests {
    @Test("Compose projects group together, loose containers stay apart")
    func groupsByProject() {
        let grouping = ContainerGrouping([
            Container(id: "1", name: "shop-web-1", labels: ["com.docker.compose.project": "shop"]),
            Container(id: "2", name: "blog-web-1", labels: ["com.docker.compose.project": "blog"]),
            Container(id: "3", name: "shop-db-1", state: .exited,
                      labels: ["com.docker.compose.project": "shop"]),
            Container(id: "4", name: "scratch"),
        ])
        #expect(grouping.projects.map(\.name) == ["blog", "shop"])
        #expect(grouping.projects.last?.containers.map(\.name) == ["shop-db-1", "shop-web-1"])
        #expect(grouping.standalone.map(\.name) == ["scratch"])
    }

    @Test("A project is only fully up when every service is")
    func reportsProjectHealth() {
        let partial = Project(name: "shop", containers: [
            Container(id: "1", name: "web", state: .running),
            Container(id: "2", name: "db", state: .exited),
        ])
        #expect(partial.runningCount == 1)
        #expect(!partial.isFullyUp)
        #expect(partial.statusLabel == "Partial")
        #expect(Project(name: "empty", containers: []).isFullyUp == false)
    }

    @Test("Only published ports are offered as links")
    func listsPublishedPorts() {
        let container = Container(id: "1", name: "web", ports: [
            PortBinding(containerPort: 443),
            PortBinding(containerPort: 80, hostPort: 8080),
            PortBinding(containerPort: 5432, hostPort: 5432),
        ])
        #expect(container.publishedPorts.map(\.hostPort) == [5432, 8080])
    }
}
