# HotkeyManager

Owns global hotkeys and the modifier/mouse event tap that drive the switcher.
Reports to its delegate; never touches the panel directly.

## Two input mechanisms

- **Carbon hotkeys** — key presses (Cmd+Tab, arrows, H/Q/W/T, …). Chosen over a
  keyDown tap because they only need Accessibility permission, not Input
  Monitoring. Cmd+Tab / Cmd+Shift+Tab / Cmd+` are registered globally; the rest
  only while the panel is active, plus a block of no-op "swallow" hotkeys so
  ordinary Cmd+key combos don't leak to the app behind the panel.
- **CGEvent tap** (`.listenOnly`) — modifier release and mouse clicks only.
  Passive, so revoking Accessibility while it's alive can't freeze input; the
  cost is it can't consume events (clicks are handled via the panel's shields).

## Reliability backstops

The tap runs on a dedicated high-priority thread with its own run loop, so the
Cmd-release callback is never starved by main-thread UI work (which caused
timeout-disable and a stuck panel). Two polls cover dropped events while active:

- **Cmd watchdog** (100ms) — dismisses if Cmd is no longer physically held, in
  case the Cmd-up event is lost.
- **Hold-repeat** (40ms) — while a navigation key stays held, keeps firing its
  action past the initial delay. Carbon doesn't deliver reliable repeat events.

## Shift-tap

Shift pressed and released while Cmd is held, with no Shift+Tab in between, means
"select previous". `tabSeenDuringShift` distinguishes it from Shift held as part
of Shift+Tab; it fires on release so it can't double up with the reverse hotkey.
