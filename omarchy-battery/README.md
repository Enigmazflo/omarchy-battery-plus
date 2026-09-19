# omarchy-battery

Samsung One UI-style battery history for Omarchy (Arch + Hyprland):
an event-driven SQLite log, an EMA discharge predictor, and an SVG chart
renderer that feeds the Battery Plus Quickshell popup.

## Components

| Binary | Role |
|---|---|
| `omarchy-battery-collector` | systemd user daemon. Polls sysfs, appends rows on change |
| `battery-predict` | CLI test front-end for the predictor (human-readable) |
| `battery-chart` | Renders the 24h stair-step + forecast chart to SVG |

The prediction math lives in `src/predict.rs` (shared lib); both
`battery-predict` and `battery-chart` call the same function, so the CLI
and the graph can never disagree.

## Requirements

- Rust toolchain (`mise install rust` works: `mise exec rust -- cargo …`)
- A C compiler for the bundled SQLite (`cc` — already on Arch)
- A battery at `/sys/class/power_supply/BAT*` (auto-detected; desktops
  with no battery make the collector exit 0 so the unit never loops)

## Install

```sh
# 1. Build
mise exec rust -- cargo build --release --manifest-path ~/Projects/omarchy-battery/Cargo.toml

# 2. Install binaries
cp ~/Projects/omarchy-battery/target/release/{omarchy-battery-collector,battery-predict,battery-chart} ~/.local/bin/

# 3. Install + start the collector
mkdir -p ~/.config/systemd/user
cp ~/Projects/omarchy-battery/systemd/omarchy-battery-collector.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now omarchy-battery-collector.service

# 4. Check it
systemctl --user status omarchy-battery-collector.service
journalctl --user -u omarchy-battery-collector.service -f
sqlite3 ~/.local/share/omarchy-battery/history.db "SELECT * FROM battery_log ORDER BY ts DESC LIMIT 5;"
```

## Test the predictor / renderer

```sh
battery-predict --db ~/.local/share/omarchy-battery/history.db
# ~4h 20m left (draining 9.5%/h) — empty ~11:40 PM   (exit 0)
# no prediction: status is 'Charging'                 (exit 2, suppressed)

battery-chart --db ~/.local/share/omarchy-battery/history.db \
  --out ~/.local/share/omarchy-battery/chart.svg --hours 24
```

The chart also emits `--json-out chart.json` — the dataset the Quickshell
popup renders natively (splines, reveal animation, hover details). Both
files are written atomically (temp + rename) since the widget may be
reading concurrently.

## Config

Environment variables (or `battery-predict`/`battery-chart` flags, or
`~/.config/omarchy-battery/env` sourced by the unit):

| Variable | Default | Meaning |
|---|---|---|
| `OMARCHY_BATTERY_DB` | `~/.local/share/omarchy-battery/history.db` | SQLite path |
| `OMARCHY_BATTERY_POLL_SECS` | `30` | Sysfs poll interval (min 5) |
| `OMARCHY_BATTERY_HEARTBEAT_SECS` | `900` | Idle heartbeat row (min 60) |
| `OMARCHY_BATTERY_WINDOW_MINUTES` | `60` | Predictor lookback (`--window-minutes`) |
| `OMARCHY_BATTERY_EMA_ALPHA` | `0.2` | EMA weight for new samples (`--alpha`) |
| `OMARCHY_BATTERY_PRUNE_DAYS` | `30` | Rows older than this are deleted on startup |
| `OMARCHY_BATTERY_WINDOW_HOURS` | `24` | Chart window (`--hours`) |

## Storage schema

```sql
CREATE TABLE battery_log (
  ts INTEGER PRIMARY KEY,
  level INTEGER NOT NULL,
  status TEXT NOT NULL,
  current_ua INTEGER,
  energy_now INTEGER,
  energy_full INTEGER
);
```

Notes:

- `energy_now`/`energy_full` hold `charge_now`/`charge_full` (µAh) on
  batteries that don't expose `energy_*` (like this machine's BAT1).
  The burn-rate math is identical either way (µA/µAh == 1/h).
- One row per capacity-or-status change, plus a 15-minute heartbeat —
  a day of normal use is tens of rows, not thousands.
- The Battery Plus Quickshell widget re-renders the chart SVG fresh on
  every popup open; nothing is ever cached.

## Troubleshooting

- `no battery (BAT*) …; nothing to do.` → desktop without a battery;
  the service exits 0 by design.
- Empty chart ("No battery data") → collector hasn't logged in-window
  rows yet; wait a few minutes after enabling.
- Wrong battery on multi-battery machines → the detector picks the
  first `BAT*` with a `capacity` file (sorted); override by symlinking
  or editing `detect_battery()`.
