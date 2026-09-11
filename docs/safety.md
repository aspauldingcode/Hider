# Safety and debugging

Running-app hiding edits a live system process, so it is off by default and wrapped in guards that recover the Dock on their own.

## Guards

- **Circuit breaker** (`Hider_RunHideBudgetOK`). Counts hide operations per one-second window. A sustained spike, from a layout fight or a hang, trips safe mode, restores every tile, and stops further work. This catches a hang, which leaves no crash report.
- **Crash-loop guard** (`Hider_CrashLoopGuard`, in `Hider_Init`). A crash on launch would relaunch, re-run, and crash again. Before an intentional kill, the controller writes `/tmp/hider-intentional-restart`, and a marked launch is exempt. An unmarked launch increments `/tmp/hider-launch-count`; a 12-second survival timer clears it. After three, the guard enters safe mode and sets `hideRunningApps` to `NO`.

## Manual recovery

If the Dock stays down, move the dylib out of the Plugin Playground tweaks folder and relaunch the Dock:

```sh
sudo mv /opt/pluginplayground/tweaks/libHider.dylib /tmp/
launchctl kickstart gui/$(id -u)/com.apple.Dock.agent
```

Never use `kickstart -k`; combined with rapid injector reloads it can wedge launchd until a reboot. To disable the feature without removing the dylib:

```sh
defaults write com.aspauldingcode.hider hideRunningApps -bool NO
```

## Files and flags

| Path | Purpose |
|------|---------|
| `/tmp/hider.log` | dylib log. One `insertTile: SKIP` line per refused tile, one `clamped ... index` line per clamp. |
| `/tmp/hider-run-hide` | Transient override that turns run-hide on. |
| `/tmp/hider-intentional-restart` | Marks a relaunch as intentional for the crash-loop guard. |
| `/tmp/hider-launch-count` | Crash-loop guard's launch counter. |
| `HIDER_NO_RESTART=1` | Stops `hiderctl` from restarting the Dock. |
