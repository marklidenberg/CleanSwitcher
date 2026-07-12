import AppKit
import Darwin

// - Restore native Cmd+Tab on crash / quit (SIGKILL can't be intercepted)

func emergencyExit() {
    setNativeCommandTabEnabled(true)
    exit(0)
}

[SIGTERM, SIGINT, SIGTRAP].forEach { sig in
    signal(sig) { _ in emergencyExit() }
}
NSSetUncaughtExceptionHandler { _ in emergencyExit() }

// - Run

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
