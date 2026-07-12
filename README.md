# CleanSwitcher

A minimal Cmd+Tab replacement for macOS.

- **Hides apps you haven't used recently** — the switcher shows your recent apps, with older ones one keypress away (Cmd+T).
- **A clean window switcher** — Cmd+«key left of 1» cycles the current app's windows.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marklidenberg/CleanSwitcher/main/install.sh | bash
```

Ad-hoc signed, not notarized.

## Shortcuts

| Key | Action |
|-----|--------|
| Cmd+Tab | Open app switcher |
| Cmd+«key left of 1» | Open window switcher |
| Tab / Shift+Tab / arrows | Navigate (hold to repeat) |
| T | Toggle older apps |
| Return / release Cmd | Activate |
| Escape | Dismiss |
| H | Hide other apps |
| Q | Quit app |
| W | Close window |

## How it looks

### Before (native MacOS Switcher)

![Before](docs/images/before.png)

### After (CleanSwitcher)

![After](docs/images/after.png)

### Windows (CleanSwitcher)

![Windows](docs/images/windows.png)


## Credits

A fork of [fad1/Switcher](https://github.com/fad1/Switcher).

## License

MIT
