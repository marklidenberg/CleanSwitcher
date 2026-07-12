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

Cmd+Tab from idle opens the app switcher; from active it steps. Cmd+` from the
app switcher dives into the selected app's windows. Releasing Cmd (or Return)
activates the selection; Escape / an outside click dismisses.

## Accessibility permission

Taking over Cmd+Tab means disabling the native hotkey, which must never happen
without a working replacement:

- The event tap is created **first**; native Cmd+Tab is disabled only if that
  succeeds. Until permission is granted, native Cmd+Tab keeps working.
- A background poll reconciles permission (not the tap-disabled callback, which
  macOS doesn't reliably deliver on revoke). On revocation it restores native
  Cmd+Tab and **quits** — terminating is the only reliable way to release the tap
  and clear the macOS input-freeze bug.
