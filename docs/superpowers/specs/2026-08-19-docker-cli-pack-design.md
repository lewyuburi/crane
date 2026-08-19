# Crane: Docker CLI pack and engine settings

Date: 2026-08-19

Crane 2.0 already runs Apple’s `container` plus socktainer and talks to the Docker socket. This spec changes how (and whether) Crane becomes the user’s `docker` / `docker compose`, and rebuilds the Engine and onboarding surfaces so they follow macOS Human Interface Guidelines instead of bolting new controls onto the current screens.

The container workspace (lists, detail, logs, stats, files, terminal) stays. DockerAPI, AppleContainer, and the installer’s download/verify path stay. Onboarding and the Engine pane are rewritten.

## Goal

- The **engine** (runtime + socktainer + socket + registered context `crane`) is what setup installs.
- The **CLI pack** (official Docker CLI + Compose, pinned in `StackManifest`) is optional, one click, never the default.
- If the machine already has a Docker CLI Crane did not install, Crane **does not replace it**. It registers a Docker context and lets the user point that CLI at Crane.
- The UI is OrbStack-quiet and Apple-native: `Form`, `Section`, `Toggle`, `Button`, `LabeledContent`, TipKit. No custom chrome, no wizard, no fighting SwiftUI.

## Non-goals

- A Crane-written `docker`/`compose` clone or shim.
- Hijacking `/usr/local/bin/docker` or overwriting Docker Desktop.
- A `/var/run/docker.sock` symlink for tools that ignore contexts (later spec).
- Menu bar, login item UX, Machines, Compose-as-projects UI (phase 3/4).
- Restyling Containers / Images / Volumes / Networks.
- Changing the pinned versions except as required to split engine vs pack.

## Three states

Detection: resolve `docker` the same way a login shell would (`PATH` only). **Foreign** means that executable is not under Crane’s `StackLayout.binDirectory`. Crane’s own `bin/docker` after a pack install is not foreign. If `docker` is not on `PATH`, there is no foreign CLI even if Docker Desktop sits unused on disk.

| State | Engine setup | CLI pack | Context | Surfaces |
|---|---|---|---|---|
| **A — no CLI** | runtime + socktainer only | available | registered; selected as current (nothing else to disturb) | Onboarding checkbox (on). TipKit once after skip. Engine: Install button |
| **B — foreign CLI** | same | **blocked** | registered; **not** auto-selected | No checkbox, no tip. Engine: toggle “Use Crane as the engine”; restore previous |
| **C — Crane pack** | same | installed + PATH snippet | `crane` is current | Engine: versions; note that a new terminal is needed once |

`EngineStatus.isFresh` is true only when **engine** components (runtime, socktainer) are missing. Missing docker/compose must not send the user back to onboarding.

`EngineStatus.isReady` stays “no blocking diagnostics”. Missing CLI is not blocking (already true today). After this spec, missing CLI is also **not** a diagnostic warning with a Fix that silently installs the pack. The pack is a product action, not a repair.

## Behaviour

### Engine provision (`Engine.provision`)

Installs and supervises **runtime and socktainer only**. Writes launch agents. Registers context `crane` (`DockerContext.install`). Does **not** download docker/compose.

Context selection:

- If a foreign `docker` exists: remember previous context (existing `previous-docker-context` file, write-once) and **do not** call `makeCurrent`. The user’s existing CLI keeps its current engine until they flip the toggle.
- Otherwise: `makeCurrent` as today.

Repair / “Repair everything” follows the same split: it never installs the CLI pack.

### CLI pack (`CLIPack` / `Engine.provisionCLI`)

Downloads the pinned `docker` and `compose` artifacts, SHA-256, layout into `stack/` + `bin/` as today. Installs Compose where the Docker CLI looks for plugins (`cliPluginsDirectory`) **and** as `bin/docker-compose`.

Refuses to start if `foreignDockerPath != nil`. No partial PATH write in that case.

On success: PATH snippet, then `makeCurrent`.

On failure (network, digest, unpack): engine untouched; Engine pane shows the error and **Retry**. Incomplete files stay out of `bin/` (existing installer rule).

### PATH

Do not copy binaries into `/usr/local/bin`.

Append an idempotent block to `~/.zprofile`, and to `~/.bash_profile` only if that file already exists:

```
# crane-cli
export PATH="$HOME/Library/Application Support/Crane/bin:$PATH"
```

Use the real `StackLayout.binDirectory` path, not a hardcoded string. Re-running provision recognizes the `# crane-cli` marker and does not duplicate. Uninstall of the pack (out of scope unless it falls out naturally) would remove the marked block; this spec does not require an uninstall UI.

Tell the user a **new terminal window** is required. Terminal.app login shells read `.zprofile`; do not also write `.zshrc`.

### “Use Crane as the engine”

This is `DockerContext.makeCurrent` / `resign(to: previous)`. It is a **setting**, available in state B (and C, where it should already be on). It is not available as a way to force the pack when a foreign CLI exists.

If `DOCKER_HOST` is set, do not offer a toggle that would no-op (same as today’s diagnostic). Explain in the section footer.

### Persistence

- Previous Docker context: existing file under Application Support.
- TipKit handles one-time offer dismissal. Do not add a parallel `UserDefaults` flag for the same fact.
- Onboarding checkbox is session state until Setup runs; if checked, pack provision runs **after** engine provision succeeds. If engine provision fails, do not start the pack.

## Architecture

Keep the bottom-up package layers. New types live in `EngineControl`; `CraneCore` exposes them through `EngineModel`; `CraneUI` only renders.

```
CraneUI          OnboardingView, EngineView (replaces DiagnosticsView), Tip
CraneCore        EngineModel: provision, provisionCLI, setEngineCurrent, foreignDockerPath
EngineControl    Engine, CLIPack/PATH, DockerContext, StackManifest split, EngineStatus fields
```

### `StackManifest`

Keep one blessed table. Add:

- `engineArtifacts` → runtime, socktainer
- `cliArtifacts` → docker, compose

`artifacts` can remain the union for tests that iterate everything. Install loops must use the right subset.

### `EngineStatus` additions (pure, tested)

- `foreignDockerPath: String?`
- `cliPackInstalled: Bool` — Crane’s `bin/docker` and Compose plugin both exist and report the versions in `StackManifest.current`
- `cliPackBlocked: Bool` { foreignDockerPath != nil }
- Stop mapping missing docker/compose to diagnostics with `.install(.docker)` / `.install(.compose)`. Those rows move to the Docker CLI **section** in the Engine pane, not the health list.

Health list (diagnostics): runtime, socktainer, container service, Docker API, context registration. Context “not selected” in state B is **not** a warning-with-Fix in the health list; the toggle is the control. Context missing entirely still offers register.

### `EngineModel`

- `provision()` — engine only.
- `provisionCLI()` — pack; no-op/error if blocked.
- `setUseCraneAsEngine(_ Bool)` — makeCurrent / restore.
- While pack downloads, `phase` must **not** dump the user back to onboarding. Pack progress is local to the Engine pane (`ProgressView` on the row). Engine `phase == .working` remains for engine setup/repair only.

### `crane` CLI

- `crane setup` — engine only (same as the app).
- `crane setup --cli` — engine if needed, then pack; exit non-zero with a clear message if a foreign `docker` is on PATH.
- `crane restore-context` — unchanged.

## UI

Rebuild **OnboardingView** and the Engine pane from scratch. Match System Settings: grouped `Form`, native spacing, SF Symbols only as `Label` icons where HIG expects them. Inspiration from OrbStack is density and calm, not copied chrome.

English copy. Sentence case. Controls named by what they do.

### Semantic map (mandatory)

| Intent | Control |
|---|---|
| Include CLI in this upcoming setup | `Toggle` with `.toggleStyle(.checkbox)` in the onboarding Form. Default **off**. Hidden in state B. |
| Use Crane as the engine (live) | `Toggle` switch, `.controlSize(.mini)`, in a Form row. Immediate. |
| Install / Retry pack | `Button`, `.bordered` in the row. Onboarding primary remains `.borderedProminent` “Set up Crane”. |
| Blocked pack | `LabeledContent` + section footer with the foreign path (selectable, truncated middle). No fake disabled switch. |
| One-time offer after skipping checkbox | TipKit (`TipView` or popover anchored on Engine in the sidebar). Not the error `Banner`. Distinct from failures (`exclamationmark.triangle`). |
| Pack download | `ProgressView` in the same row. Workspace stays usable. |
| Errors | Existing glass `Banner` for failures only. |

Do not: custom pills, marketing cards, multi-page wizard, Liquid Glass on primary buttons, hand-rolled PATH terminals, a separate Settings window.

### Onboarding (rewrite)

Single page. Header: set up the container engine. Body Form:

- Section “Crane will install”: runtime and socktainer only (name, purpose, progress while working).
- Optional row: checkbox “Install Docker CLI and Compose”. Footer: they will be able to run `docker` in Terminal; a new terminal window is needed after install. Hidden if foreign CLI.
- If foreign CLI: footer only — Crane will register a Docker context; use Engine to point `docker` at Crane.

Primary: “Set up Crane”. Version footnote stays.

Update the current subtitle that claims `docker` already works for everyone; the socket is the product, the CLI is opt-in.

### Engine pane (rewrite of `DiagnosticsView`)

Navigation title “Engine”. Toolbar: Re-check, Repair everything (engine only).

1. **Status** — health rows for engine pieces, each with Fix when `repair != nil` (same pattern as today, minus CLI rows).
2. **Docker CLI** — the three states from the table. Toggle, Install, or versions + “Open a new terminal window to use `docker`.”
3. **Stack** — Crane version, runtime, socktainer, socket path. Docker/Compose versions only if the pack is installed.

### TipKit

Show when: `phase == .ready`, pack not installed, not blocked, tip not invalidated.

Actions: Install (calls `provisionCLI`) and dismiss (invalidate). After dismiss, only Engine.

Do not show during onboarding or `needsAttention`.

### Previews and snapshots

`#Preview` for onboarding (checkbox / hidden-foreign) and Engine (A/B/C). Extend `CRANE_SNAPSHOTS` with those frames. Seed `EngineModel` / `EngineStatus` with the new fields so snapshots do not need a live stack.

## Testing

- `EngineStatus`: fresh ignores missing CLI; ready with no pack; blocked vs pack; context not auto-current does not block.
- Foreign path: Crane `bin/docker` is not foreign; `/usr/local/bin/docker` is.
- Pack refused when foreign; PATH snippet idempotent; marker present.
- `provision` does not install docker/compose (unit with fake installer or by asserting the artifact list).
- Context: provision with foreign docker does not `makeCurrent`; toggle does; restore works.
- Snapshot tests for the new screens.
- Existing `InstallerIntegrationTests` still prove digest/layout; add pack-only install when `CRANE_INTEGRATION=1`.

## Migration from current 2.0 behaviour

Today `provision` installs all four binaries and always selects context `crane`. After this spec:

- Machines already fully provisioned: treat as state C if Crane’s docker is on disk; PATH snippet may be missing — Engine offers “Add to PATH” as the same Install/repair path (idempotent pack provision).
- Do not uninstall docker/compose already in Crane’s layout.
- `crane setup` on an old machine does not delete the pack.

## Risks

- TipKit vs snapshot tests: render `TipView` in a preview host or snapshot Engine without requiring the tip to appear.
- `.zprofile` edits are user-visible; keep the block tiny and marked.
- Docker Desktop later installed on top of state C: next `refresh` becomes state B (foreign `docker` wins on PATH if it is first). Pack remains on disk; UI switches to blocked + context toggle. Document this in the Engine footer rather than auto-deleting Crane’s binaries.

## Implementation order

1. Split manifest/provision/status + tests (no UI).
2. PATH + foreign detection + pack API + tests.
3. Rewrite Engine pane and onboarding + TipKit.
4. `crane setup --cli`.
5. Previews and snapshots.
6. Integration test for pack install.
