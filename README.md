# Crane

A native macOS app that turns [Apple's `container`](https://github.com/apple/container) into a
Docker replacement you can actually work on — the engine, the socket, and the UI, managed as one.

> **Crane 2.0 is a rewrite in progress.** This branch is being built phase by phase; see
> [Status](#status) for exactly what runs today. Crane 0.1.x is frozen at its tag.

## Why a rewrite

Apple's runtime is good, but on its own it isn't a Docker replacement: the ecosystem —
Testcontainers, VS Code Dev Containers, JetBrains, `act`, Traefik — talks to a **Docker socket**,
not to a CLI. Apple closed the Engine API as [not planned](https://github.com/apple/container/issues/66)
and pointed at [socktainer](https://github.com/socktainer/socktainer), which serves Docker Engine
API v1.51 on top of Apple's runtime.

So Crane stops imitating Docker and starts running the real thing:

```
Crane.app                  GUI, onboarding, diagnostics, projects
docker CLI + compose       the official binaries, on Crane's context
socktainer                 Docker API, service DNS, restart policies, healthchecks
apple/container            the runtime that boots the VMs
```

Crane installs, pins, supervises and repairs all four, and drives them through the socket —
no shim, no polling, no subprocess per click.

## Status

| Phase | What it delivers | State |
|---|---|---|
| 1 — Engine | Install/verify/supervise the stack, launch agents, Docker context, diagnostics, onboarding, event feed | **done** |
| 2 — Core | Containers, images, volumes, networks, logs, stats, terminal, files — all over the API | **done** |
| 3 — Projects | Real `docker compose`, app gallery, health and restart as first-class UI | planned |
| 4 — Product | Menu bar, login start, search, Machines, new screenshots | planned |

## Requirements

macOS 26 on Apple Silicon, and a Swift 6.2+ toolchain (Xcode 26) to build.

## Build and run

```sh
./Scripts/bundle.sh --run   # builds build/Crane.app and launches it
swift test                  # unit suites (no runtime needed)
```

The app onboards a clean machine: it downloads the pinned stack into
`~/Library/Application Support/Crane`, loads two launch agents, and registers a `crane` Docker
context. No admin password, nothing installed system-wide.

Same thing from the terminal:

```sh
crane status   # what's installed, what's running, what's wrong
crane setup    # install or repair the stack, then start it
docker ps      # the real Docker CLI, against Crane's context
```

## The pinned stack

socktainer links `apple/container` with an **exact** version, so the pieces are versioned as one
blessed set — [`StackManifest.swift`](Sources/EngineControl/StackManifest.swift) is the single
source of truth. Nothing is unpacked unless its SHA-256 matches the manifest, and Apple's package
must additionally be notarized and signed by Apple's Containerization team — requiring "Apple Root
CA" would be meaningless, since every Developer ID chains to it.

Bumping the stack means bumping that file, re-computing the digests, and running:

```sh
CRANE_INTEGRATION=1 swift test --filter InstallerIntegrationTests
```

which downloads the real artifacts and checks each one installs and reports the pinned version.

## Working on the UI

The screens render to PNGs without launching the app, so a design change can be looked at (and
looked at again afterwards):

```sh
CRANE_SNAPSHOTS=/tmp/crane-ui swift test --filter SnapshotTests
```

Two things the harness can't show: a split view's sidebar is a vibrancy view and captures blank,
and Liquid Glass button styles draw without their surface off-screen — which is why the primary
actions use `.borderedProminent` and glass is reserved for the floating banner.

## Known limits

Crane is honest about what this stack can't do rather than emulating it badly:

- The Docker API is **partial**: `pause`/`unpause`, `commit`, `top`, `diff`, `search` and static
  container IPs aren't available; `network connect/disconnect` are no-ops. Parity table in
  [socktainer#14](https://github.com/socktainer/socktainer/issues/14).
- [socktainer#329](https://github.com/socktainer/socktainer/issues/329): malformed EDNS0 replies
  break name resolution inside Go-based containers.
- Restart policies are enforced by socktainer's process; Crane's launch agent restarts it, but a
  policy doesn't survive a host reboot the way dockerd's would.
- `--privileged` doesn't exist on Apple's runtime; use `--cap-add`/`--cap-drop`.

## License

Apache-2.0 — see [LICENSE](LICENSE).
