import DockerAPI
import EngineControl
import Foundation

/// Sample state for previews, snapshots and tests.
///
/// Views that can only be seen against a live engine can't be reviewed or regression-tested, so
/// the store takes a seam: a plain initializer that starts already populated.
public enum PreviewFixtures {
    public static let containers: [Container] = [
        Container(id: "a1b2c3d4e5f6", name: "shop-web-1", image: "docker.io/library/nginx:alpine",
                  state: .running, statusText: "Up 4 hours", health: .healthy,
                  ports: [PortBinding(ip: "0.0.0.0", containerPort: 80, hostPort: 8080)],
                  created: .now.addingTimeInterval(-14_400),
                  addresses: ["shop_default": "192.168.64.7"],
                  labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "web"]),
        Container(id: "b2c3d4e5f6a1", name: "shop-api-1", image: "ghcr.io/acme/billing-api:1.4",
                  state: .running, statusText: "Up 4 hours", health: .starting,
                  ports: [PortBinding(containerPort: 3000, hostPort: 3000)],
                  created: .now.addingTimeInterval(-14_300),
                  labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "api"]),
        Container(id: "c3d4e5f6a1b2", name: "shop-db-1", image: "docker.io/library/postgres:17-alpine",
                  state: .running, statusText: "Up 4 hours", health: .healthy,
                  ports: [PortBinding(containerPort: 5432, hostPort: 5432)],
                  mounts: [MountPoint(source: "/Users/dev/Library/Application Support/com.apple.container/volumes/shop_db",
                                      destination: "/var/lib/postgresql/data", name: "shop_db")],
                  created: .now.addingTimeInterval(-14_500),
                  labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "db"]),
        Container(id: "d4e5f6a1b2c3", name: "shop-cache-1", image: "redis:7-alpine",
                  state: .exited, statusText: "Exited (137)", exitCode: 137,
                  created: .now.addingTimeInterval(-14_600),
                  labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "cache"]),
        Container(id: "e5f6a1b2c3d4", name: "blog-web-1", image: "caddy:2-alpine",
                  state: .running, statusText: "Up 12 minutes",
                  ports: [PortBinding(containerPort: 80, hostPort: 8081)],
                  created: .now.addingTimeInterval(-720),
                  labels: ["com.docker.compose.project": "blog", "com.docker.compose.service": "web"]),
        Container(id: "f6a1b2c3d4e5", name: "scratch", image: "alpine:3.22",
                  state: .exited, statusText: "Exited (0)", exitCode: 0,
                  created: .now.addingTimeInterval(-86_400)),
        Container(id: "0a1b2c3d4e5f", name: "mailpit", image: "axllent/mailpit:latest",
                  state: .running, statusText: "Up 2 days",
                  ports: [PortBinding(containerPort: 8025, hostPort: 8025)],
                  created: .now.addingTimeInterval(-172_800)),
    ]

    public static var detail: ContainerDetail {
        let json = """
        {"Id":"a1b2c3d4e5f6","Name":"/shop-web-1","Platform":"linux","RestartCount":0,
         "State":{"Status":"running","Running":true,"StartedAt":"2026-08-07T04:08:31Z",
                  "Health":{"Status":"healthy"}},
         "Config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin","NGINX_VERSION=1.27.4",
                          "DATABASE_URL=postgres://shop:secret@db:5432/shop"],
                   "Cmd":["nginx","-g","daemon off;"],"WorkingDir":"/usr/share/nginx","Tty":false},
         "HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},
         "Mounts":[{"Source":"/Users/dev/Projects/shop/site","Destination":"/usr/share/nginx/html","RW":false},
                   {"Source":"/var/lib/shop","Destination":"/data","RW":true,"Name":"shop_data"}]}
        """
        return try! JSONDecoder().decode(ContainerDetail.self, from: Data(json.utf8))
    }

    public static let images: [ImageSummary] = [
        ImageSummary(id: "sha256:14cea493d9a3", repoTags: ["docker.io/library/nginx:alpine"],
                     size: 57_547_856, created: .now.addingTimeInterval(-86_400), containers: 2),
        ImageSummary(id: "sha256:postgres17aa", repoTags: ["docker.io/library/postgres:17-alpine"],
                     size: 270_000_000, created: .now.addingTimeInterval(-200_000), containers: 1),
        ImageSummary(id: "sha256:redis7bbbbbb", repoTags: ["redis:7-alpine"],
                     size: 40_000_000, created: .now.addingTimeInterval(-50_000), containers: 0),
        ImageSummary(id: "sha256:abcdef0123456789", repoTags: ["<none>:<none>"],
                     size: 12_000_000, created: .now.addingTimeInterval(-10_000), containers: 0),
    ]

    public static let volumes: [VolumeSummary] = [
        VolumeSummary(name: "shop_db", driver: "local",
                      mountpoint: "/Users/dev/Library/Application Support/com.apple.container/volumes/shop_db",
                      createdAt: "2026-08-07T04:06:42Z",
                      labels: ["com.docker.compose.project": "shop"]),
        VolumeSummary(name: "blog_data", driver: "local",
                      mountpoint: "/Users/dev/Library/Application Support/com.apple.container/volumes/blog_data",
                      createdAt: "2026-08-18T12:00:00Z",
                      labels: ["com.docker.compose.project": "blog"]),
    ]

    public static let networks: [NetworkSummary] = [
        NetworkSummary(id: "default", name: "default", driver: "nat",
                       subnet: "192.168.64.0/24", gateway: "192.168.64.1",
                       labels: ["com.apple.container.resource.role": "builtin"],
                       attached: ["shop-web-1": "192.168.64.7/24"]),
        NetworkSummary(id: "shop_default", name: "shop_default", driver: "nat",
                       subnet: "192.168.65.0/24",
                       attached: ["shop-web-1": "192.168.65.2/24", "shop-api-1": "192.168.65.3/24"]),
    ]

    public static func engineStatus(
        runtime: Bool = true,
        running: Bool = true,
        foreignDockerPath: String? = nil,
        cliPack: Bool = false,
        contextCurrent: String? = "crane"
    ) -> EngineStatus {
        let manifest = StackManifest.current
        return EngineStatus(
            components: EngineComponent.allCases.map { component in
                let installed: String?
                if component.isEngine {
                    installed = runtime ? manifest.artifact(for: component).version : nil
                } else {
                    installed = cliPack ? manifest.artifact(for: component).version : nil
                }
                return ComponentStatus(component: component, installed: installed,
                                       expected: manifest.artifact(for: component).version)
            },
            runtimeRunning: running, daemonRunning: running, socketPresent: running,
            contextInstalled: runtime,
            contextCurrent: runtime ? contextCurrent : nil,
            foreignDockerPath: foreignDockerPath)
    }
}
