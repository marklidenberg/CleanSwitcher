# AppsPanel

A panel of apps over the screen under the mouse, toggled by the Apps shortcut
(⌥ Space by default). Click an icon — the app activates or launches.

## Layout

A compact box over the desktop — like Cmd+Tab's — centered, at «Position» down the
screen; or, with «Open near the cursor», centered on the cursor, kept on the screen:

```
      ╭──────────────────────────╮
      │   ◻ ◻ ◻ ◻ ◻ ◻            │    pinned, full — rows
      │   ◻ ◻ · ◻ ◻ ◻ ◻          │    recent, 50% — fixed slots, gaps allowed
      ╰──────────────────────────╯
        [ hide area ]                 while a drag is on
```

- Shape: pill (round ends) or box; a line between pinned and recent, or none;
  the icon sizes, gap, padding — all in Preferences, a change shown as a sample
  (gone with Esc, or once Preferences closes or loses focus).
- Typing turns the box into the search: the field, the list under it.
  CleanSwitcher is among the results: chosen, it opens its settings.
- Hover: a plate behind the icon (like Cmd+Tab's), a white glow, or nothing.
- Right click: a menu — the app's name, Rename…, Reset name. Rename: a field under the
  icon, the letters redrawn as you type; ⏎ saves, esc cancels, empty — its own name.
  The search finds an app by both names.
- Letters (optional): each icon's shortest name start no other app shares, in a chip
  (`CH` Chrome, `CL` Claude; the vendor dropped — `E` Excel). Typed, the others fade;
  an app's letters complete — it opens: after a pause (a key more — the search), or at
  once (no search). The pinned's among themselves; the recent's too (optional) — none a
  pinned one's start (`S` Safari pinned, `SL` Slack). Keys by place — any layout.
- A click off the box closes it — it passes through to what's under.
- The cursor stopped on an icon a while (200 ms by default) opens it (a checkbox, on by default; the delay a slider) —
  only after a move: the cursor warped onto an icon at open opens nothing.

## Invariants

- Recent never holds a pinned or a hidden app — nor, where set in Preferences, a quit one.
- A recent app keeps its slot until it stops being recent; the slot is then a gap.
  A new one — or one back after the TTL, or unpinned — takes the first free slot,
  the one used longer ago first.
- Drag: above the line pins (into a row, or a new row above, between or below the
  rows); below unpins; onto the hide area hides from recent. The search's pin
  brings a hidden app back, pinned. Target decided on the rows as they stood at
  drag start.
- The panel goes only once the chosen app is in front — no flash of the app behind.
- Views and icons are kept across opens; the installed apps are scanned off the
  main thread — an open does little before it shows.

## State

`AppsStore`, JSON in `Preferences.appsState`: `rows`, `slots`, `hidden`, `names`.
