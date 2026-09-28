# AppDelegate

The coordinator. Wires up the subsystems and drives the switcher as a small state
machine, translating HotkeyManager events into panel operations.

## State

```
state:  idle | active            (is the panel showing?)
mode:   apps | windows           (what it's switching between)
```

- **apps** (Cmd+Tab) — MRU apps split into main/secondary; live-refreshed so
  apps launched while it's open appear.
- **windows** (Cmd+`) — one tile per window of one app; no live refresh.

Both shortcuts are configurable in Preferences (defaults below). Cmd+Tab from idle
opens the app switcher; from active it steps. Cmd+` from the app switcher dives
into the selected app's windows (when both share modifiers). Releasing Cmd (or Return)
activates the selection; Escape / an outside click dismisses.

Each hotkey has a mode in Preferences, applied from idle:

```
Normal       open the panel
Recent only  switch straight to the previous app / window, no panel
Disabled     no-op; still registered, native one stays off — even without permission
```

On every regular app's activation, whatever caused it (Spotlight, Dock, click,
switcher), two opt-ins apply (accessory apps like Paste are skipped — their panel
acts on the app behind):

- "Bring all windows forward" — raises (via AX) only its windows another app
  covers; skipped while hiding other apps, since then nothing covers them.
- "Hide other apps when switching" — hides every other app (instant, no
  animation); activating a hidden app unhides it.

Both run once activations settle (50ms), for the last activated app, and never
activate an app themselves. Activation is async: acting mid-race (hiding an app
still activating, or re-activating) makes apps ping-pong.

"Open new windows maximized" (opt-in, needs permission) resizes each new
standard window of any app to fill its screen (menu bar and Dock excluded).

## Accessibility permission

Taking over Cmd+Tab means disabling the native hotkey, which must never happen
without a working replacement:

- The event tap is created **first**; native Cmd+Tab is disabled only if that
  succeeds (or its mode is Disabled), and only while the configured shortcut is
  exactly Cmd+Tab (same for Cmd+`). Until permission is granted, native Cmd+Tab keeps working.
- A background poll reconciles permission (not the tap-disabled callback, which
  macOS doesn't reliably deliver on revoke). On revocation it restores native
  Cmd+Tab and **quits** — terminating is the only reliable way to release the tap
  and clear the macOS input-freeze bug.

Trackpad gestures (opt-in, per command): 3 or 4 fingers, ↔ ← → ↕ ↑ ↓. The Apps
panel's toggles it; a switcher's goes straight to the recent app / window, as
"Recent only" does — read off the private
MultitouchSupport framework, no permission. macOS's own swipe between full-screen
apps uses the same fingers: turn it off in System Settings → Trackpad, or pick the
other count. A swipe heading a configured way is claimed early (2% of the pad): its
scroll and gesture events are dropped (an event tap, Accessibility); every other
swipe — e.g. 3 fingers ↓ for App Exposé — goes on to the system.
