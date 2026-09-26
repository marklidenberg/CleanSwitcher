# HotkeyManager

Owns global hotkeys and the modifier/mouse event tap that drive the switcher.
Reports to its delegate; never touches the panel directly.

## Two input mechanisms

- **Carbon hotkeys** — key presses (Cmd+Tab, arrows, H/Q/W/T, …). Chosen over a
  keyDown tap because they only need Accessibility permission, not Input
  Monitoring. The two switcher shortcuts (+ Shift for reverse) are registered
  globally (set by AppDelegate); the rest only while the panel is active, plus a
  block of no-op "swallow" hotkeys so ordinary hold+key combos don't leak to the
  app behind the panel.
- **CGEvent tap** (`.listenOnly`) — modifier release and mouse clicks only.
  Passive, so revoking Accessibility while it's alive can't freeze input; the
  cost is it can't consume events (clicks are handled via the panel's shields).

## Hold modifiers

The shortcut that opens the panel sets the hold modifiers — its ⌘/⌥/⌃. The
panel stays open while they're all held, and the active-only hotkeys use them:

```
shortcut ⌥ Q   →  hold ⌥;  ⌥ H hides others, ⌥ Tab steps, releasing ⌥ activates
```

## Reliability backstops

The tap runs on a dedicated high-priority thread with its own run loop, so the
hold-release callback is never starved by main-thread UI work (which caused
timeout-disable and a stuck panel). Two polls cover dropped events while active:

- **Hold watchdog** (100ms) — dismisses if the hold modifiers are no longer
  physically held, in case the key-up event is lost.
- **Hold-repeat** (40ms) — while a navigation key stays held, keeps firing its
  action past the initial delay. Carbon doesn't deliver reliable repeat events.

## Shift-tap

Shift pressed and released while the hold modifiers are down, with no Shift+Tab in between, means
"select previous". `tabSeenDuringShift` distinguishes it from Shift held as part
of Shift+Tab; it fires on release so it can't double up with the reverse hotkey.
