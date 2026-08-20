# Crane: Reachable as (Compose names, no host DNS)

Date: 2026-08-20

Crane 2.0 does not install a host resolver. From the Mac, published ports are `localhost:<hostPort>`. Between containers, socktainer registers Compose aliases `service` and `service.project` plus the container name. Apple Container uses **one global hostname namespace**, so the short name `redis` is not scoped to a Compose network: if yubarta and linkvest are both up, last start wins.

This spec adds a **Reachable as** section to container and stack Info so those facts are visible and copyable. It does not change the engine, socktainer flags, `/etc/resolver`, or network isolation.

## Goal

- On a container Info pane, show how to reach that container from this Mac and from other containers.
- On a Compose stack Info pane, show the same per service, once.
- Warn when two **running** Compose services share the same short name (`service` label) across different projects.
- Keep the UI as a grouped `Form` + `DetailRow`. No new tab, inspector, or Engine control.

## Non-goals

- `sudo container system dns create` / `/etc/resolver` / `*.test` / `*.local`.
- `host.docker.internal` or `host.container.internal`.
- Changing socktainer so short names are per-network (that is upstream).
- Making `docker network connect` / `disconnect` work.
- Redesigning the Networks list or detail.
- Editing Compose files, injecting `extra_hosts`, or writing `/etc/hosts`.
- Onboarding or Engine pane changes.

## Names Crane shows

Derived only from data already on `Container` (labels, name, published ports, `addresses`). No extra Docker API round-trip.

For a Compose container (`com.docker.compose.project` and `com.docker.compose.service` both set):

| Row label | Value |
|---|---|
| This Mac | One row per published host port: `localhost:<hostPort>`. Omit the row group if there are none. |
| Other containers | Distinct values, this order: `service`, `service.project`, container `name`. Drop duplicates (e.g. when name equals service). |
| Network | Network names from `addresses.keys`, sorted. If empty, omit the row. |

For a standalone container (no Compose project):

| Row label | Value |
|---|---|
| This Mac | Same published-port rule. |
| Other containers | Container `name` only. |
| Network | Same as above. |

`service.project` uses a single dot and the Compose project label as-is (`redis.yubarta`). That matches socktainer’s qualified alias.

## Collision

A **short-name collision** exists when two or more **running** containers have the same non-empty `service` and different `project` values.

- Container Info: if this container’s `service` collides, one orange `Label` under Reachable as: `` `redis` also names linkvest. Use `redis.yubarta`. ``
  - Other project names, sorted, joined with commas if more than one.
  - The qualified name in the sentence is always **this** container’s `service.project`.
- Stack Info: one warning per colliding short name used by this stack, not once per service. Same wording, using this stack’s project in the qualified name.
- Stopped containers do not participate. A stopped yubarta `redis` does not warn against a running linkvest `redis`.

Collision is **not** a blocking Engine diagnostic. It is copy in Info only.

## UI

### Container Info (`ContainerDetailView` Info tab)

New section **Reachable as**, immediately after **Ports** (after Status if Ports is absent).

- `DetailRow` for each value; values are monospaced and selectable (`DetailRow` already enables selection).
- **This Mac** may be several rows (one port each). **Other containers** may be several rows (one name each). **Network** may be several rows (one network each).
- Collision `Label` last in the section, `.foregroundStyle(.orange)`, `systemImage: "exclamationmark.triangle.fill"`, text selectable.

Do not duplicate Ports: Reachable as “This Mac” is the DNS/host story (`localhost:5434`); Ports stays `localhost:5434` → `5432/tcp`. Same host port string is fine; the sections answer different questions.

### Stack Info (`ProjectDetailView` Info tab)

After **Ports** (after **Services** if Ports is absent):

1. If this stack has at least one short-name collision, a Section **Short names** with one orange `Label` per colliding service (same sentence as container Info).
2. Then, for each service in name order (container name as tie-break), a Section titled with the service name (or container name if `service` is missing). Rows inside match container **Reachable as**: This Mac, Other containers, Network. No extra chrome.

Still `Form` + `Section` + `DetailRow` only.

### Networks pane

Unchanged.

## Model

Add a small pure value type in CraneCore, e.g. `ReachableNames`, built from one `Container` plus the full running-container list (for collision peers).

```
struct ReachableNames: Equatable, Sendable {
    var host: [String]          // "localhost:5434"
    var peers: [String]         // "redis", "redis.yubarta", "yubarta-redis"
    var networks: [String]      // "yubarta_default"
    var collisionWarning: String?
}
```

Factory: `ReachableNames(of: Container, among: [Container])`.

- `among` is the workspace container list; filter to `isRunning` inside the factory for collision.
- Host strings: `localhost:\(hostPort)` for each `publishedPorts` entry that has a host port, stable order (already lowest-first on `publishedPorts`).
- Peers: Compose rule or standalone rule above; unique, order preserved.
- Networks: `addresses.keys.sorted()`.
- Warning: nil or the exact sentence template:
  - one other project: `` `\(service)` also names \(other). Use `\(service).\(project)`. ``
  - several: `` `\(service)` also names \(a), \(b). Use `\(service).\(project)`. ``

No localization table in this pass: copy is English, like the rest of the 2.0 UI.

`Project` does not grow Docker calls. Stack Info maps `project.containers` through the same factory, passing `model.workspace.containers` (or the store’s full list) as `among`.

## Tests

New suite `Tests/CraneCoreTests/ReachableNamesTests.swift`:

- Compose container with project `yubarta`, service `redis`, name `yubarta-redis`, port 6379→6379 → peers `redis`, `redis.yubarta`, `yubarta-redis`; host `localhost:6379`.
- Duplicate drop: name equals service → peers do not repeat.
- Standalone: peers is `[name]` only; no warning.
- Collision: running `redis` in `yubarta` and `linkvest` → warning on each; stopped linkvest → no warning on yubarta.
- Three projects sharing `db` → warning lists the other two sorted.
- No published ports → `host` empty.
- Empty `addresses` → `networks` empty; section still shows peers.

No live socktainer tests. No snapshot required unless an existing Info snapshot would fail; update it if one covers the Info Form.

## Docs

README **Known limits**: add that short Compose names (`redis`) are global on this engine; use `service.project` when two stacks share a service name; from the Mac, use published `localhost` ports. Point at Reachable as in the GUI.

## Out of this spec if it appears during implementation

- Apple `container system dns` even as a hidden CLI.
- Changing LaunchAgent socktainer flags for DNS.
- Per-network DNS scoping in socktainer.
