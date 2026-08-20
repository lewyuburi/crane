# Crane

A native macOS app that turns [Apple's `container`](https://github.com/apple/container) into a
Docker replacement you can actually work on — the engine, the socket, and the UI, managed as one.

> **Crane 2.0** replaces the 0.1.x app. That line is frozen at its tag.

## Why a rewrite

Apple's runtime is good, but on its own it isn't a Docker replacement: the ecosystem —
Testcontainers, VS Code Dev Containers, JetBrains, `act`, Traefik — talks to a **Docker socket**,
not to a CLI. Apple closed the Engine API as [not planned](https://github.com/apple/container/issues/66)
and pointed at [socktainer](https://github.com/socktainer/socktainer), which serves Docker Engine
API v1.51 on top of Apple's runtime.

So Crane stops imitating Docker and starts running the real thing:

```
Crane.app                  GUI, onboarding, engine, projects
docker CLI + compose       optional official binaries, or the CLI you already have
socktainer                 Docker API, service DNS, restart policies, healthchecks
apple/container            the runtime that boots the VMs
```

Setup installs and supervises the **engine** (runtime + socktainer), registers a `crane` Docker
context, and drives the GUI through the socket. The official `docker` / Compose binaries are an
optional pack: one click in the app, or `crane setup --cli`, and only when no other `docker` is
on `PATH`. If you already have Docker Desktop or Homebrew’s CLI, Crane will not replace it —
turn on **Use Crane as the engine** to point that CLI at Crane’s socket.

## Status

| Phase | What it delivers | State |
|---|---|---|
| 1 — Engine | Install/supervise runtime + socktainer, context, Engine pane, onboarding, CLI pack | **2.0** |
| 2 — Workspace | Containers (Compose stacks in the list), images, volumes, networks, logs, stats, terminal, files | **2.0** |
| Later | Compose-from-disk, app gallery, menu bar, Machines | not in 2.0 |

## Install

```sh
brew install --cask lewyuburi/tap/crane
```

Open Crane and set up the engine. Leave **Install Docker CLI and Compose** on if you don’t
already have `docker` on PATH — that’s the OrbStack-shaped loop: from a project folder,

```sh
docker compose up -d    # or `pnpm db:up`
```

The GUI groups those services as a Compose stack. A new terminal window is needed once after
the CLI pack lands on PATH.

Updates come from the tap, not from inside the app:

```sh
brew upgrade --cask crane
```

The tap tracks GitHub releases. After a new tag, `brew upgrade --cask crane` pulls the DMG.

## Requirements

macOS 26 on Apple Silicon, and a Swift 6.2+ toolchain (Xcode 26) to build.

## Build and run

```sh
./Scripts/bundle.sh --run   # builds build/Crane.app and launches it
swift test                  # unit suites (no runtime needed)
```

The app onboards a clean machine: it downloads the pinned **engine** into
`~/Library/Application Support/Crane`, loads two launch agents, and registers a `crane` Docker
context. No admin password, nothing installed system-wide. Docker CLI and Compose are on by
default at first setup (uncheck if you already have `docker`), then live under Engine.

Same thing from the terminal:

```sh
crane status        # what's installed, what's running, what's wrong
crane setup         # install or repair the engine, then start it
crane setup --cli   # also install official docker + compose (if PATH is free)
docker context use crane   # if you already have a Docker CLI
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

SwiftUI Previews live in the **CraneUI** library, not in `CraneApp`. Xcode 26 cannot set
`ENABLE_DEBUG_DYLIB` on a SwiftPM executable, so the canvas fails if the scheme is `CraneApp`
or `crane`.

1. Scheme (toolbar): **CraneUI** → My Mac  
   If it isn’t listed: Product → Scheme → Manage Schemes… → Autocreate / tick CraneUI.
2. Open a file with `#Preview` (`OnboardingView.swift`, `EngineView.swift`, `ContainerAvatar.swift`).
3. Editor → Canvas (⌥⌘↩), then Resume.

Snapshots still work without Xcode:

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
- Daily Compose is **image-based sidecars** (`docker compose up -d` of postgres, redis, mailpit,
  minio). Services with `build:` need a working Docker build API; that is not a 2.0 promise.
- Short Compose names (`redis`) are **global** on this engine, not scoped to a project network.
  If two stacks share a service name, use `redis.yubarta` (or the name on **Reachable as** in
  Info). From the Mac, published ports are still `localhost:<port>` — Crane does not install
  a host resolver.

## License

Apache-2.0 — see [LICENSE](LICENSE).
