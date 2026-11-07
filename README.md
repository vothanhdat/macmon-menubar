# MacMon Indicator

A tiny macOS menu bar monitor for Apple Silicon: CPU, GPU, RAM, power, battery, temperature,
fans and disk, with up to 30 days of history and a top-processes list. Sensor data comes from
[macmon](https://github.com/vladkens/macmon) (sudoless). This project is an unofficial frontend for it.

| Menu bar | Warning | Menu |
|---|---|---|
| ![menu bar](docs/menubar-light.png) | ![warning](docs/menubar-warning-light.png) | ![menu](docs/dropdown-dark.png) |

_Screenshots use demo history and demo process names._

## Features

- **Two-line menu bar item** with an icon per value (or one line, icons optional). Pick up to 6 metrics,
  and adjust text size, line spacing, item spacing and opacity. Values turn orange or red past your limits.
- **Menu**: a native macOS menu, so it has the same glass look as your other menu bar menus. It holds
  filled bar charts for 5m (default) / 1h / 24h / 7d / 30d in one or two columns. You choose which
  charts appear and in what order, and where the values go (in the chart, on the label row, or split).
  The solid bar is the average, the faint bar is the peak, so short spikes stay visible.
  Hover to read values at any moment.
- **Top processes**: CPU, RAM and disk. By default you get the top 2 of each; click a column to see
  the top 6 by that column (click again to go back).
- **Battery** charge/discharge watts, **disk** read/write throughput.
- **Optional root mode** to see disk use of system processes (Spotlight, Time Machine, …).
- Starts at login, no Dock icon, stays out of the way.

## Requirements

- Apple Silicon Mac, macOS 13 or newer
- `macmon`: `brew install macmon`
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

## Install

```bash
git clone https://github.com/vothanhdat/macmon-menubar.git && cd macmon-menubar
make install
```

This builds the app and copies it to `/Applications`. Because you build it yourself, macOS does not
show the "unidentified developer" warning. Then open **Settings… → Launch at login**.

Other commands: `make app` (build only, into `build/`), `make run`, `make uninstall`, `make clean`.

## Using it

- **Click** (left or right): the menu with charts, top processes, **Settings… (⌘,)** and **Quit (⌘Q)**.
- **Settings**: menu bar slots, icons, one or two lines, text size, spacing, edge padding and opacity
  (the menu bar updates live while you drag), menu charts (which, order, columns, value position), update interval (on power / on battery), warning limits, launch at
  login, root mode, CSV export.

## Resource use

Measured on a MacBook Pro M4 Pro, on battery, 5 s interval, menu closed:

| Process | CPU (% of one core) | Memory (footprint) |
|---|---|---|
| MacMon Indicator | 0.2–0.4% | 15 MB (about 34 MB once the menu has been opened) |
| macmon | 0.30% | 11 MB |
| **Total** | **~0.5–0.7%** | **~26–45 MB** |

At the default 2 s interval on power, expect roughly twice the CPU. While the menu is open it
samples every second and scans processes every 2 s. macOS also uses about 110 MB of graphics memory
for the menu's glass window and frees it 20 to 40 s after the menu closes. The first time the menu is
drawn, macOS loads the frameworks it needs (the glass effect, symbol rendering), which adds about 19 MB
that stays. It doesn't grow on later opens, and all of the app's own menu objects are freed on close.

How it stays small:

- **No sensor code in the app.** macmon does the sampling. The app reads one JSON line per interval
  and decodes only the ~15 fields it uses (about 2 ms of work per sample).
- **AppKit only, no SwiftUI.** Charts are drawn by hand with Core Graphics.
- **Few menu bar redraws.** Each change of a menu bar item costs macOS about 20 ms of CPU, more than
  everything else the app does. The item is a pre-rendered image (a template image, so macOS tints it
  itself) that is replaced only when the text or color changes. **Ignore small changes** (on by
  default) keeps a number until it moves by a noticeable step or is a minute old. Warnings always
  show immediately, and the menu always shows exact values. This cut the app's CPU from 0.42% to 0.18%.
- **Adaptive interval:** 1 s while the menu is open, your setting on power or battery,
  10 s while the displays sleep, stopped during system sleep. Changes are debounced: sweeping the
  mouse along the menu bar opens and closes menus, and that doesn't restart macmon.
- **Process scanning runs only while the menu is open.**
- **History is one fixed-size memory-mapped file** (~214 KB, never grows). Writing a sample is just a
  memory write, and the file is flushed once a minute.

## How it works

```
macmon pipe -i <ms> ──JSON lines──▶ MacMonIndicator.app
                                     ├─ + disk throughput, battery watts (IOKit, no root)
                                     ├─ status item (two-line grid)
                                     ├─ history: 5 round-robin tiers in history.bin
                                     │    5m @5s · 1h @10s · 24h @4min · 7d @30min · 30d @2h  (avg + max)
                                     └─ menu (NSMenu; built on open, freed on close)
                                          └─ process monitor: libproc (your processes) + /bin/ps (others)
                                                              or the root helper (everything)
```

History lives in `~/Library/Application Support/MacMonIndicator/history.bin`. Time when the Mac was
asleep or the app wasn't running shows as a gap. Export it from Settings as CSV. The file records its
own layout, so when a new version adds a range, the existing ranges are kept.

## Root mode (optional, off by default)

Without root, macOS only lets an app read disk I/O for **your own** processes. System processes
show CPU and RAM (from `/bin/ps`), and their disk use is grouped as "System processes" under the list.

Turning on **Settings → Show system processes** asks for your admin password and installs a small
helper ([`Helper/helper.c`](Helper/helper.c), ~150 lines):

- `/Library/PrivilegedHelperTools/local.MacMonIndicator.helper` + a LaunchDaemon plist
- **Started on demand** by launchd when the menu asks for data. It **exits after 30 s** idle.
- **Read-only.** It answers exactly one request (`snapshot`) with per-process CPU time, memory and
  disk bytes. It accepts no other commands, writes no files, and only answers your user id.

Turning it off removes it (asks for the password again). Manual removal:

```bash
sudo launchctl bootout system/local.MacMonIndicator.helper
sudo rm -f /Library/LaunchDaemons/local.MacMonIndicator.helper.plist /Library/PrivilegedHelperTools/local.MacMonIndicator.helper
```

## Notes on the numbers

- **CPU %** in the menu bar is the share of all cores that are busy (like Activity Monitor's total).
  In the process list it's % of **one** core, so a busy process can show more than 100%.
- **GPU %** is frequency-weighted, as macmon reports it.
- **Temperatures** are macmon's CPU/GPU averages. **Power** "System" is the whole machine.
- **Battery** is + when charging and − when discharging.
- **Disk** totals include every block device (internal and external).

## Troubleshooting

- **Values show "–"**: macmon isn't running. The menu shows a line explaining why. Install it with `brew install macmon`.
- **Log**: `/usr/bin/log show --last 1h --predicate 'subsystem == "local.MacMonIndicator"'`
  (macmon starts and exits, sleep and wake).
- **Reset history**: quit the app and delete `~/Library/Application Support/MacMonIndicator/history.bin`.

## Development

```bash
make app                                                          # build into build/
"build/MacMon Indicator.app/Contents/MacOS/MacMonIndicator" --snapshot out --demo   # render UI to PNGs
"build/MacMon Indicator.app/Contents/MacOS/MacMonIndicator" --bar-previews looks.png # menu bar look sheet
"build/MacMon Indicator.app/Contents/MacOS/MacMonIndicator" --layout-previews l.png  # chart layout sheet
./build/macmon-indicator-helper --stdout | head                   # helper output (your processes)
```

## License

MIT. Uses [macmon](https://github.com/vladkens/macmon) (MIT) as a separate program.
