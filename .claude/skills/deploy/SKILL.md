---
name: deploy
description: Deploy CleanSwitcher — rebuild and replace /Applications/CleanSwitcher.app in place, keeping the Accessibility grant. Trigger on "deploy", "reinstall the app".
---

From the repo root:

```sh
./scripts/dev.sh --once
```

Signs with your Apple Development identity, so the grant survives. Never `install.sh` (ad-hoc → grant resets).
