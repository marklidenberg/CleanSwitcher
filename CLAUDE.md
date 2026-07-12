# CleanSwitcher

A minimal Cmd+Tab replacement for macOS. Shows apps that own a window (or a Dock badge), most-recently-used first. Hidden apps (Cmd+H) are included, matching native Cmd+Tab; only genuinely windowless apps are filtered out.

## Build

```bash
swift build --disable-sandbox        # debug
swift build -c release --disable-sandbox
.build/debug/CleanSwitcher
```

Use `--disable-sandbox` when building from Claude Code (SPM's own `sandbox-exec` conflicts with the environment sandbox).

## Layout

`Sources/CleanSwitcher/` — one file per concern:

- `AppDelegate` — state machine (idle/active × apps/windows), coordinates everything
- `HotkeyManager` — Carbon hotkeys, `.listenOnly` CGEvent tap, auto-repeat
- `AppListProvider` / `WindowListProvider` — MRU apps / per-app windows, recency split
- `AppSwitcherPanel` / `AppItemView` / `SwitcherItem` — the panel UI
- `Preferences` — UserDefaults wrapper
- `PrivateAPIs` — `CGSSetSymbolicHotKeyEnabled` (disables native Cmd+Tab; restored on exit)

Needs Accessibility permission (not Input Monitoring). Without it, native Cmd+Tab keeps working and the app polls until granted.

## Shortcuts

- **Cmd+Tab** — app switcher. **Cmd+«key left of 1»** — window switcher.
- Tab / Shift+Tab / arrows navigate (hold to repeat). **T** toggles older-apps section.
- **Return** or release Cmd activates; **Escape** dismisses. **H** hide others, **Q** quit app, **W** close window.

# lessmore conventions

## Naming & shape

- Prefer full names over shortenings (`g` → `group`, `sa` → `service_account`)
- Inline code if not reused (no single-use helpers)
- Prefer single-line over multi-line
- Skip obvious comments. Use them as little as possible

## Wise Comments

Hierarchical code structuring with comments. Put exactly one blank line before and after each step comment:

```
// - Step 1

code here

// - Step 2

code here

// -- Step 2.1 (substep)

code here
```

Example:

```swift
func registerUser(email: String, password: String) throws -> User {
    // - Validate input

    // -- Check the email

    guard isValidEmail(email) else { throw ValidationError.badEmail }

    // -- Check the password strength

    guard password.count >= 8 else { throw ValidationError.weakPassword }

    // - Create the account

    let user = db.insertUser(email: email, passwordHash: hash(password))

    // -- Grant the default role  (STEPS RESET to `-` at the new indentation!!!)

    db.insertRole(userId: user.id, role: .member)

    // - Send the welcome email

    sendEmail(to: email, template: .welcome)

    // - Return

    return user
}
```

## Todos

All todos must have a tag:

- `// todo next:`: must be done before merging/shipping the current change
- `// todo later:`: known follow-up, should be done but not blocking
- `// todo maybe:`: speculative, may or may not be worth doing

## Tests

- Cover all relevant scenarios
- Keep as small as possible while covering all scenarios
- No intersecting tests (no duplicate scenarios)

## Comments & Docs

Comments, READMEs, and proto docs describe the **current state** of the system —
not its history or the discussion behind it.

- No references to previous behavior ("now X instead of Y", "no longer…") —
  git holds the history
- No rejected alternatives or leftover justifications from earlier iterations
- Negations are fine only to explain a current invariant that matters on its own
- Deliberate TODOs / planned work markers are fine

## READMEs

- If a nearby `README.md` describes behavior you changed, update it in the same
  PR
- Keep READMEs high-level: data model, behavior, invariants — no signatures or
  implementation details
- For large changes or a missing-but-needed README, tell the user instead of
  inventing a big doc
