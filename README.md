# CleanSwitcher

A minimal Cmd+Tab replacement for macOS.

- **Hides apps you haven't used recently** — the switcher shows your recent apps, with older ones one keypress away (Cmd+T).
- **A clean window switcher** — Cmd+«key left of 1» cycles the current app's windows.

## Before

![Before](docs/images/before.png)

## After

![After](docs/images/after.png)

## Windows

![Windows](docs/images/windows.png)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/marklidenberg/CleanSwitcher/main/install.sh | bash
```

Ad-hoc signed, not notarized.

## Build

```bash
swift build -c release
scripts/build-app.sh release   # produces CleanSwitcher.app
```

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

## Credits

A fork of [fad1/Switcher](https://github.com/fad1/Switcher).

## License

MIT
