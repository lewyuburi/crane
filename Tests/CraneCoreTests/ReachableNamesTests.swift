import DockerAPI
import Testing

@testable import CraneCore

@Suite("Reachable names")
struct ReachableNamesTests {
    @Test("A Compose service lists short, qualified and container names")
    func composePeersAndHost() {
        let redis = compose("yubarta", "redis", name: "yubarta-redis",
                            hostPort: 6379, network: "yubarta_default")
        let names = ReachableNames(of: redis, among: [redis])
        #expect(names.host == ["localhost:6379"])
        #expect(names.peers == ["redis", "redis.yubarta", "yubarta-redis"])
        #expect(names.networks == ["yubarta_default"])
        #expect(names.collisionWarning == nil)
    }

    @Test("A name that already is the service is not repeated")
    func dropsDuplicatePeer() {
        let db = compose("shop", "db", name: "db")
        #expect(ReachableNames(of: db, among: [db]).peers == ["db", "db.shop"])
    }

    @Test("A standalone container is only its name")
    func standalone() {
        let mail = Container(id: "1", name: "mailpit",
                             ports: [PortBinding(containerPort: 8025, hostPort: 8025)])
        let names = ReachableNames(of: mail, among: [mail])
        #expect(names.peers == ["mailpit"])
        #expect(names.collisionWarning == nil)
        #expect(names.host == ["localhost:8025"])
    }

    @Test("Two running stacks sharing redis warn on both")
    func runningCollision() {
        let yubarta = compose("yubarta", "redis", name: "yubarta-redis")
        let linkvest = compose("linkvest", "redis", name: "linkvest-redis")
        let among = [yubarta, linkvest]
        #expect(ReachableNames(of: yubarta, among: among).collisionWarning
            == "`redis` also names linkvest. Use `redis.yubarta`.")
        #expect(ReachableNames(of: linkvest, among: among).collisionWarning
            == "`redis` also names yubarta. Use `redis.linkvest`.")
    }

    @Test("A stopped peer does not count as a collision")
    func stoppedPeerIgnored() {
        let yubarta = compose("yubarta", "redis", name: "yubarta-redis")
        let linkvest = compose("linkvest", "redis", name: "linkvest-redis", running: false)
        #expect(ReachableNames(of: yubarta, among: [yubarta, linkvest]).collisionWarning == nil)
    }

    @Test("A stopped container does not warn about a running namesake")
    func stoppedSelfIgnored() {
        let yubarta = compose("yubarta", "redis", name: "yubarta-redis", running: false)
        let linkvest = compose("linkvest", "redis", name: "linkvest-redis")
        #expect(ReachableNames(of: yubarta, among: [yubarta, linkvest]).collisionWarning == nil)
    }

    @Test("Three projects sharing db list the other two, sorted")
    func threeWayCollision() {
        let a = compose("alpha", "db", name: "alpha-db")
        let b = compose("beta", "db", name: "beta-db")
        let c = compose("gamma", "db", name: "gamma-db")
        #expect(ReachableNames(of: a, among: [a, b, c]).collisionWarning
            == "`db` also names beta, gamma. Use `db.alpha`.")
    }

    @Test("No published ports leaves host empty")
    func noPorts() {
        let db = compose("yubarta", "db", name: "yubarta-db")
        #expect(ReachableNames(of: db, among: [db]).host.isEmpty)
    }

    @Test("Empty addresses leaves networks empty and still lists peers")
    func noNetworks() {
        let db = compose("yubarta", "db", name: "yubarta-db")
        let names = ReachableNames(of: db, among: [db])
        #expect(names.networks.isEmpty)
        #expect(names.peers == ["db", "db.yubarta", "yubarta-db"])
    }

    @Test("A stack lists one warning per colliding service")
    func stackWarningsDedupe() {
        let redisA = compose("yubarta", "redis", name: "yubarta-redis")
        let redisB = compose("linkvest", "redis", name: "linkvest-redis")
        let db = compose("yubarta", "db", name: "yubarta-db")
        let project = Project(name: "yubarta", containers: [redisA, db])
        #expect(ReachableNames.stackWarnings(in: project, among: [redisA, redisB, db])
            == ["`redis` also names linkvest. Use `redis.yubarta`."])
    }

    private func compose(_ project: String, _ service: String, name: String,
                         hostPort: Int? = nil, network: String? = nil,
                         running: Bool = true) -> Container {
        Container(
            id: name,
            name: name,
            state: running ? .running : .exited,
            ports: hostPort.map { [PortBinding(containerPort: $0, hostPort: $0)] } ?? [],
            addresses: network.map { [$0: "192.168.64.2"] } ?? [:],
            labels: [
                "com.docker.compose.project": project,
                "com.docker.compose.service": service,
            ])
    }
}
