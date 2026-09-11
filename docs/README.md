# Hider internals

How the running-app hiding is built and why it works. For install and usage, see the [top-level README](../README.md).

| Document | What's in it |
|----------|--------------|
| [architecture.md](architecture.md) | The components, the preferences they share, and the private DockCore symbols Hider hooks. |
| [hiding.md](hiding.md) | How a running app is kept out of the Dock, the index clamp that stops it from crashing, and how a change is applied. |
| [safety.md](safety.md) | The guards that keep a bad state from bricking the Dock, plus the log files and flags. |
| [REVERSING.md](REVERSING.md) | Full GhidraVibe headless RE of Dock: addresses, decompiles, mermaid graphs, and why PR #2 works. |
