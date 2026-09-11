# Hiding a running app

The goal: a hidden running app has no icon, no gap, and nothing to click, while the app keeps running. Hiding only the icon would leave a clickable empty slot, so Hider keeps the tile out of the Dock's model entirely.

The pieces referenced here (`DockBar`, `tiles`, the DockCore methods) are described in [architecture.md](architecture.md).

## Refusing the tile

A running app's tile enters the Dock through one main-thread method, `-[DockBar insertTile:atIndex:forReason:]`. It runs on both paths: a fresh launch (`_handleLaunchNotification:`) and an app already running at Dock start (`addProcessForASN:`). Hider swizzles it and drops the call for a hidden app:

```objc
static void Hider_InsertTileHook(id self, SEL _cmd, id tile, NSInteger index, id reason) {
    if (Hider_RunHideActive() && Hider_ShouldRefuseTile(tile)) {
        return;  // not forwarded: the tile never enters `tiles`
    }
    ...
    g_orig_insertTile(self, _cmd, tile, safeIndex, reason);
}
```

With the tile out of `tiles`, there is no icon, no gap, no hit-testing, and no tooltip. The tile object still exists, which satisfies `addProcessForASN`'s non-optional Swift return. If DockCore tries to re-add the tile, the call re-enters the hook and is dropped again.

## Index clamp

Dropping inserts leaves `tiles` shorter than DockCore expects. When DockCore later computes `atIndex` for another tile, it can pass an index past the end of the array. `array.insert(at:)` then hits a Swift precondition and traps (`EXC_BREAKPOINT`), which crashes the Dock. Four hidden apps, for example, can produce an insert at index 7 into a 5-element array.

The same hook clamps the index before forwarding it:

```objc
NSInteger safeIndex = MIN(MAX(index, 0), (NSInteger)count);
```

Only out-of-range values change, so inserts on the normal path are untouched.

## Applying a change

A tile is built only during layout, so toggling the hidden list while the Dock is running does not remove a tile that is already on screen. To apply a change, the app and CLI restart the Dock:

```sh
killall Dock   # launchd relaunches it in ~2s; Plugin Playground reloads the dylib; the rebuild hides the app
```

The app drives this for you:

- **Applications pane.** Hidden apps first, then apps that currently own a Dock tile (each with a green dot, tracked through `NSWorkspace`), then a search across running and installed apps.
- **Auto-apply.** A change needs a rebuild, so toggles debounce: the Dock rebuilds once, about a second after the last toggle. Toggling an app on also enables the master switch.
- **Relaunch guard** (`SettingsManager.attemptRelaunch`). Every relaunch goes through one path that coalesces bursts, holds a 5-second minimum gap, and skips the kill if the Dock is not fully back up. Without it, repeated kills trip launchd's respawn throttle.
- **External sync.** `SettingsManager` reloads on the `settingsChanged` notification, guarded by `isReloading`, so edits from the CLI or a second window are not overwritten.

The guards that keep a failed rebuild from bricking the Dock are in [safety.md](safety.md).
