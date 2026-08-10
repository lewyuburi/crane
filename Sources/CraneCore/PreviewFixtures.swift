import DockerAPI
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
}

public extension WorkspaceStore {
    /// A store that starts populated, for previews and snapshot rendering. It still holds a real
    /// client, so anything the view triggers behaves exactly as it would in the app.
    static func preview(client: DockerClient = DockerClient()) -> WorkspaceStore {
        let store = WorkspaceStore(client: client)
        store.seed(containers: PreviewFixtures.containers)
        return store
    }
}
