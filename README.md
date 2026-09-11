# hammerspoon-metrics
Display computer metrics / bandwidth limiter

# Hammerspoon Config

A personal vibe-coded [Hammerspoon](https://www.hammerspoon.org/) configuration for macOS: a
canvas-based system widget dashboard plus a menubar network bandwidth limiter,
both driven by JSON config files and editable through small `hs.webview` UIs.
The AI of choice is Claude Opus/Sonnet.

> **Tested on:** macOS Tahoe, Hammerspoon 1.1.1. It may work on other versions,
> but that's the only combination this has been verified against.

## Features

### Widget dashboard (`widgets/`)

A stack of small `hs.canvas` overlays drawn on screen, with live values pulled
from shell scripts (`scripts/*.sh`) on a timer:

- **CPU**, **GPU**, **RAM**, **SSD** usage
- **Network** up/down throughput
- **Date/time**
- **Wallpaper** rotation (random image from a folder, per-display, on an
  interval)

Everything — order, enabled state, thresholds, colors, intervals, target
display(s), per-display offsets, wallpaper folder — is stored in
[`widgets.json`](widgets.json), which is seeded automatically on first run.
It can be edited by hand or through the built-in HTML editor
(`widgets/editor.lua` / `widgets/editor.html`).

### NetLimiter (`netlimiter/`)

A menubar app that throttles system-wide network bandwidth using macOS's
built-in BSD traffic-shaping tools (`dnctl` + `pfctl` — the same ones behind
Apple's Network Link Conditioner). It's a Hammerspoon port of
[Dima Goltsman's `osx-net-speed-limiter`](https://github.com/dimagoltsman/osx-net-speed-limiter)
(originally a standalone SwiftUI app), reimplemented as a Lua module with the
same enable/disable/preset behavior:

- Toggle limiting on/off from the menubar, with quick presets
  (512K, 1M, 10M, 100M, 500M, 1G)
- Live speed changes without re-prompting for the admin password
- A menubar icon that switches between 🐇 (unrestricted) and 🐢 (throttled),
  using the PDFs in [`icons/`](icons)
- An `hs.webview` control panel (`netlimiter/ui.html`) for manual
  upload/download values
- Settings persisted to `netlimiter.json`; only loaded/started when enabled
  from the widget dashboard editor

## Requirements

- macOS (tested on Tahoe)
- [Hammerspoon](https://www.hammerspoon.org/) (tested on 1.1.1)

## Installation

1. Install Hammerspoon: `brew install --cask hammerspoon` (or download from
   [hammerspoon.org](https://www.hammerspoon.org/)).
2. Clone (or symlink the contents of) this repository into `~/.hammerspoon`.
3. Launch Hammerspoon and reload the config (menubar icon → "Reload Config",
   or `hs.reload()` from the console).
4. On first run, `widgets.json` is created automatically from sane defaults.
   Enable NetLimiter and adjust widget settings via the dashboard editor
   (see hotkeys below), or by editing `widgets.json` directly.
5. To make the cpu and gpu widgets work , in terminal do:
   >sudo visudo -f /etc/sudoers.d/pm-usage
   
   In this file add this line:
   
   your-username ALL=(root) NOPASSWD: /Users/your-username/.hammerspoon/scripts/pm-usage.sh

   and save the file.

## Structure

```
init.lua           entry point: wires widgets + netlimiter, binds hotkeys
widgets.json        widget dashboard config (auto-seeded)
netlimiter.json      NetLimiter last-used speed settings (auto-seeded)
widgets/            widget registry/orchestrator + individual widgets, editor UI
netlimiter/         menubar bandwidth limiter + control panel UI
scripts/            shell scripts backing the system-stat widgets
icons/              menubar icons (rabbit.pdf / turtle.pdf)
```

## Hotkeys

All bound with `Hyper = cmd + alt + ctrl`:

| Hotkey    | Action                                   |
| --------- | ----------------------------------------- |
| Hyper + 2 / 4 | Toggle widget dashboard visibility    |
| Hyper + F1 | Re-arm widget click-through / layering  |
| Hyper + 9  | List connected displays (for config)   |
| Hyper + e  | Open the widgets dashboard editor      |
| Hyper + 0  | Show Lua heap size and force a GC      |
| Cmd + `   | Set a random wallpaper (if enabled)    |
| Cmd + Alt + ` | Choose a specific wallpaper (if enabled) |

## Credits

- NetLimiter's throttling approach is ported from
  [dimagoltsman/osx-net-speed-limiter](https://github.com/dimagoltsman/osx-net-speed-limiter)
  by [Dima Goltsman](https://github.com/dimagoltsman) (MIT licensed).

## License

[MIT](LICENSE)
