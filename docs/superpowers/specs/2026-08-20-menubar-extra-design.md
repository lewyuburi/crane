# Crane: Menu bar status extra

Date: 2026-08-20

Crane today quits when the last window closes. The engine can keep running via LaunchAgents, but there is no live indicator. This adds a menu bar extra so closing the window leaves Crane in the menu bar (no Dock) until Quit.

## Goal

- Always show a Crane menu bar item while the GUI process is alive.
- Closing the last window does **not** quit; the app becomes Dock-less (`.accessory`).
- Menu: engine status, running container count, Open Crane, Start/Stop Engine, Quit Crane.
- Event feed and `EngineModel` stay alive with the process, not only with a window.

## Non-goals

- Per-container list or actions in the menu.
- Notifications / badges.
- Preference “quit when last window closes”.
- Quitting the GUI must not uninstall the stack or delete LaunchAgent plists.
- Separate helper process.

## Lifecycle

| Event | Behavior |
|---|---|
| Launch | `.regular`, Dock + window + menu bar. |
| Last window closes | Do not terminate. `.accessory` (leave Dock). Menu bar remains. |
| Open Crane | `.regular`, activate, open/reuse main window. |
| Quit Crane | Terminate GUI. LaunchAgents keep the engine unless Stop Engine was used. |

## Menu

1. Status line (disabled): `Engine running` / `Engine needs attention` / checking text.
2. If ready: `N containers running` (disabled).
3. Open Crane
4. Start Engine — when not ready; calls existing repair `startDaemon` path.
5. Stop Engine — when ready; unload socktainer agent (keep plist) + `container system stop`.
6. Quit Crane

Icon: template SF Symbol `shippingbox.fill`. Tooltip mirrors status.

## Architecture

- `MenuBarExtra` in `CraneApp`, same `EngineModel` as `WindowGroup`.
- `AppDelegate` owns terminate-after-last-window = false and activation policy flips.
- `CraneUI` menu view reads model / workspace; start/stop go through `EngineModel`.
- `startWatching` / `refresh` tied to app lifetime, not only `RootView`.

## Testing

- Prefer a small AppKit/unit check that last-window-closed does not imply terminate, if cheap.
- Manual: close window → Dock gone, menu bar remains → Open → window + Dock → Quit.
