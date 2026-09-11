<p align="center"> <img src="media/Hider.png" width="100%"> </p>

# Hider

Hide items from the macOS Dock — Finder, Trash, the separator, and running apps — from a native settings app (`Hider.app`) or the `hiderctl` CLI. A hidden running app leaves no trace in the Dock: no icon, no gap, nothing to click, while it keeps running.

Running apps are the hard case — macOS has no API for changing the Dock — so the [`docs/`](docs/) folder covers how it works.

## Requirements

- Apple Silicon Mac.
- **macOS Sequoia 15 → latest** (Tahoe and newer included).
- **SIP disabled.** Injecting into Dock is blocked otherwise.
- **[Plugin Playground](https://github.com/CoreBedtime/playground)** — the only supported injector. Tweaks live in `/opt/pluginplayground/tweaks`.

Ammonia is not supported going forward.

## Install

**1. Command Line Tools** (for `make`):
```sh
xcode-select --install
```

**2. Disable SIP** from Recovery:
```sh
csrutil disable
```
Restart into macOS.

**3. Install Plugin Playground** from [CoreBedtime/playground](https://github.com/CoreBedtime/playground). See the [Playground docs](https://github.com/CoreBedtime/playground/tree/master/docs) for PAC stripping (`disablePAC`) if your fangs build is plain `arm64`.

**4. Install Hider** — either from source or the `.pkg`:
```sh
make install      # builds + installs into Plugin Playground
# or
make installER    # builds hider-installer.pkg for Sequoia → latest
sudo installer -pkg hider-installer.pkg -target /
```
Both paths install `libHider.dylib` (+ whitelist / options) into `/opt/pluginplayground/tweaks`, `Hider.app`, `hiderctl`, enable `disablePAC`, and restart the Dock. Open `Hider.app` and hide something to confirm.

## App

Menubar applet (`NSStatusItem` + `NSMenu`): toggle Finder / Trash / separators / running-app hiding, hide or unhide running apps, restart the Dock, or open the declarative config. Changes auto-apply — running-app hiding needs a Dock rebuild, so ~1s after you stop toggling the Dock refreshes once.

## CLI

Apps are named by bundle ID (`hiderctl list`, or `osascript -e 'id of app "Spotify"'`).
```sh
hiderctl status                        # settings + install status
hiderctl list                          # installed apps; * marks hidden
hiderctl hide <bundleID|finder|trash>  # hide
hiderctl show <bundleID|finder|trash>  # show
hiderctl apply|export [path]           # JSON config in / out
hiderctl watch                         # re-enforce as apps launch
```
With running-app hiding on, `hide`/`show` restart the Dock; set `HIDER_NO_RESTART=1` to batch changes and restart once.

## How it works

The injected dylib (`src/Hider.m`) hooks DockCore. For a hidden running app it refuses the tile at insertion (`-[DockBar insertTile:atIndex:forReason:]`), so it never enters the Dock model — no icon, no gap, nothing to hit-test. An index clamp avoids a DockCore Swift precondition crash, and a crash-loop guard restores the Dock if anything breaks. Details in [`docs/hiding.md`](docs/hiding.md).

## If the Dock misbehaves

Running-app hiding is off by default and fails safe. If the Dock won't appear:
```sh
sudo mv /opt/pluginplayground/tweaks/libHider.dylib /tmp/
launchctl kickstart gui/$(id -u)/com.apple.Dock.agent
```
Never `kickstart -k` — it can wedge the injector. A reboot clears leftover state.

## Uninstall

```sh
make uninstall
```

## Credits

- Created by **Alex Spaulding** (@aspauldingcode).
- Running-app hiding, `Hider.app`, and `hiderctl` by **Jace** (@JaceThings).
- Dock tile rendering fix by **Salty** (@ogui-775).
- Injector: [Plugin Playground](https://github.com/CoreBedtime/playground) by CoreBedtime.

## License

[MIT](LICENSE)
