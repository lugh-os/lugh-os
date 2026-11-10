# Shell bridge — spec

> Status: **Accepted** (ADR-027) · Code: `crates/lugh-shell-core/src/services/`, `ui/shell/qml/Lugh/Shell/Services.qml`, `ui/shell/src/` (cxx-qt host), `crates/lugh-shell-devd/` (dev server)

How the QML shell talks to the system. One small JSON protocol carries every service, so the Rust side stays Qt-free and testable, the QML side stays identical on the mock and on the real backend, and a new service costs one Rust module plus one QML object.

## Shape

```
QML surfaces ──▶ Services.qml (state objects + ListModels, mock bodies)
                     │  attach(backend)
                     ▼
        backend.call(method, argsJson)      backend.event(json)
                     │                              ▲
     ┌───────────────┴──────────────┐               │
     │ LughBackend (cxx-qt, in-proc)│  or  WsBackend.qml ⇄ lugh-shell-devd (WebSocket)
     └───────────────┬──────────────┘               │
                     ▼                              │
            lugh_shell_core::services::ShellCore ───┘  (Sink → events)
                     │
   network · bluetooth · audio · media · power · display · notifications ·
   session · keyboard · wm · apps · launcher · trash · appearance · shell
```

- **Production:** `lugh-shell` (cxx-qt) owns a `ShellCore` in-process and exposes it to QML as the context property `LughBackend`. Events are queued to the Qt thread.
- **Development:** `lugh-shell-devd` runs the same `ShellCore` behind a WebSocket (`ws://127.0.0.1:7777`), so `make preview ARGS="--backend ws://127.0.0.1:7777"` drives the real services of the dev machine with the stock `qml6` runtime.
- **No backend:** `Services.qml` runs its mock bodies (previews, screenshots, QML tests).

## Messages

| Direction | JSON | Meaning |
|---|---|---|
| UI → core | `{"id":7,"m":"network.connectTo","a":["ssid","pw"]}` | Call. `id` optional. Reply `{"id":7,"r":…}` / `{"id":7,"e":"msg"}` (WebSocket only; in-process `call` returns nothing useful). **Calls never block**: the outcome arrives as patches. |
| UI → core | `m: "core.snapshot"` | The front-end answers with one `snapshot` event. |
| core → UI | `{"t":"snapshot","d":{"network":{…},"audio":{…},…}}` | Full state of every service. |
| core → UI | `{"t":"patch","s":"network","d":{"scanning":true}}` | Partial state: only changed keys. An array key always carries the whole array. |
| core → UI | `{"t":"signal","s":"session","n":"unlocked","a":[]}` | One-shot QML signal (or function) `Services.<s>.<n>(…a)`. |

Rules:
- State keys are the QML property names; array elements are objects whose keys are the `ListModel` roles, with the same JSON types as the mock (`int` stays integer, etc.).
- Rows are matched by key role (`Services._keys`): `wsId`, `winId`, `appId`, `nid`, `ssid`, `address`, `devId`, `streamId`. Models without a key (`launcher.results`) sync by position.
- `launcher` patches carry `query`; the UI drops a patch whose `query` is not the current one.
- Optimistic UI: for sliders and toggles the UI updates its own value at once and forwards the call. A service must not echo a value it just set back as a stale patch during a drag (suppress its own change for ~200 ms, then confirm).
- User-facing errors are state (`network.lastError`, `session.authError`), written in plain language. `CallError` text is for logs.
- A missing system service is state too (`bluetooth.available: false`, `power.hasBattery: false`, `power.profiles: []`). Nothing fails to start.

## Service contract (names, properties, roles, functions)

The single source of truth is `Services.qml`: every property, role, function and signal declared there is implemented by the matching `services::<name>` module. Additions go into `Services.qml` first (mock + comment), then into Rust.

Signals emitted by the core: `session.unlocked()`, `apps.launchFailed(appId, message)`, `notifications.actionInvoked(nid, key)`, `osd.requested(kind, value)`, and the `shell.*` functions (`showLauncher(query)`, `toggleControlCenter()`, `toggleNotificationCenter()`, `toggleLughMenu()`, `closeAll()`), which relay `space.lugh.Shell1` D-Bus calls from the compositor's key binds.

## Performance budget

| Path | Budget |
|---|---|
| Launcher keystroke → results patch applied | ≤ 5 ms in-process |
| Slider move → system call issued | ≤ 2 ms, coalesced to ≤ 60/s |
| Idle | 0 wakeups from the core when nothing changes (signals only, no polling) |
| Core RSS (all services) | ≤ 20 MB |
| Snapshot JSON | ≤ 64 KB typical |
