# Battery Plus

Lightweight Omarchy bar widget: battery icon, live wattage, percentage,
charging pulse, drain prediction, and power-profile switching — with
toggles for everything shown in the bar. Long-term history lives in the
companion `omarchy-battery` Rust project (systemd collector + SQLite).

## What it does

- **Core widget:** icon + current watts + percentage, bound to
  Quickshell's `UPower.displayDevice` (event-driven, no polling).
- **Bar settings (what shows in the menu bar):** `showIcon`,
  `showWattage`, `showPercentage` — toggle each element from the bar's
  widget settings or the in-popup Customize page; the widget collapses
  to whatever is left. Hovering the widget fades in a highlight pill
  and gently scales the content up.
- **Battery icon styles:** `iconStyle` = Battery, or Battery + %
  (empty outline with the number inside, no fill). Canvas-drawn from
  shapes — no font glyphs, so it can never render as tofu — with fill
  width tracking the real percentage (red at ≤20%). While charging,
  a drawn lightning bolt pulses over the icon via opacity animation
  (inert when not charging).
- **Battery history (24h):** the popup renders the SQLite
  history natively on Canvas: monotone-cubic smoothed traces (no
  overshoot wiggles), gradient wash, gridlines with % and time-of-day
  labels, drain vs charging colors, a "now" dot, and (while discharging)
  a dashed EMA forecast to the predicted 0%. It plays a reveal sweep on
  open, and hovering shows the continuous fitted value
  (`02:14 · 63.5% · Discharging`) at every x position — not just at
  sample instants. Data is re-queried fresh on every open; repaints
  happen only on new data, hover moves, or the one-shot reveal.
- **Charging animation:** pulsing bolt overlay via
  `SequentialAnimation`; `running` is gated on `isCharging` so it is fully
  inert (no repaints) on battery.
- **Live prediction (tooltip):** the service keeps a short rolling sample
  buffer and exposes a weighted-moving-average `timeToEmptyMinutes` the
  tooltip binds to. The long-term EMA forecast comes from
  `battery-predict` (same math, shared module).
- **Customize page:** the collapsible popup bottom has a style switcher
  (Battery / Battery + %), icon / wattage / percentage cards in one row
  (tap to toggle, dimmed when off), wattage-effect cards in one row
  (tap to preview live in the bar), and an Order section with
  left/right movers per element. The graph's hover-details toggle lives
  right under the graph. Picking Battery + % auto-hides the separate %
  label (it would duplicate the number in the icon) and restores it
  when you go back — manual toggles always win. Choices persist across
  restarts and stay in sync with the bar settings form.
- **Power profiles:** any click toggles a popup with the profiles as
  icon-over-label cards in one row (leaf = Saver, gauge = Balanced,
  bolt = Performance, canvas-drawn so they never render as tofu) —
  click a card to apply it. Clicks never change the profile by
  themselves.
- **Advanced (workings):** right-click the widget to jump straight to
  the Advanced section: sysfs fallback poll (5–60s, only when UPower
  is missing) and drain-history sample interval (15–600s) steppers,
  plus reset-to-defaults. Left-click opens the standard view.

## Requirements

- Omarchy 4.0+ (`omarchy-shell` / Quickshell 0.3+)
- `power-profiles-daemon` (`powerprofilesctl` on `PATH`) for profile
  switching. The widget still renders battery info without it.
- A UPower-backed battery (`UPower.displayDevice.isPresent`).
  Desktops without a battery hide the widget.
- For the history graph: `battery-chart` in `~/.local/bin` and the
  collector unit running (see `~/Projects/omarchy-battery/README.md`).
  Without them the popup shows a status line instead of the chart.

## Install

```sh
omarchy plugin add <url> --enable
```

Local dev — note: widget QML edits need a full shell restart to apply:

```sh
omarchy plugin validate ./battery-plus
# copy into ~/.config/omarchy/plugins/io.github.allphis.battery-plus/
omarchy-restart-shell
```

## Limitations

- Live tooltip prediction needs a little discharge history after each
  shell start; until then it falls back to UPower's `timeToEmpty`.
- Sysfs fallback assumes `/sys/class/power_supply/BAT*/uevent` layout and
  polls at `pollIntervalMs` (default 15s, configurable).
- Profile backend is `powerprofilesctl` only; `tlp`/`auto-cpufreq` would need
  the small `backend*` function block in `Service.qml` reimplemented
  (the UI calls only `refreshProfiles()`/`setProfile()`/`cycleProfile()`).
