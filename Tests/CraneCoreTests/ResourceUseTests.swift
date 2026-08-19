import DockerAPI
import Foundation
import Testing

@testable import CraneCore

@Suite("What a container uses")
struct ResourceUseTests {
    @Test("An image is matched by tag")
    func imageByTag() {
        let image = ImageSummary(id: "sha256:redis7bbbbbb", repoTags: ["redis:7-alpine"],
                                 size: 1, created: .now)
        let cache = Container(id: "1", name: "shop-cache-1", image: "redis:7-alpine")
        let other = Container(id: "2", name: "web", image: "nginx:alpine")
        #expect(cache.uses(image))
        #expect(!other.uses(image))
    }

    @Test("An image is matched by ID prefix when the tag drifted")
    func imageByID() {
        let image = ImageSummary(id: "sha256:14cea493d9a3", repoTags: ["docker.io/library/nginx:alpine"],
                                 size: 1, created: .now)
        let web = Container(id: "1", name: "web", image: "nginx:alpine",
                            imageID: "sha256:14cea493d9a3deadbeef")
        #expect(web.uses(image))
    }

    @Test("A volume is matched by mount name")
    func volumeByMount() {
        let volume = VolumeSummary(name: "shop_db", driver: "local",
                                   mountpoint: "/var/lib/shop_db", createdAt: "")
        let db = Container(id: "1", name: "db",
                           mounts: [MountPoint(source: "/var/lib/shop_db",
                                               destination: "/data", name: "shop_db")])
        let web = Container(id: "2", name: "web")
        #expect(db.uses(volume))
        #expect(!web.uses(volume))
    }
}
