# Battery Plus

Lightweight Omarchy bar widget: battery icon, live wattage, percentage,
charging pulse, drain prediction, and power-profile switching — with
toggles for everything shown in the bar. Long-term history lives in the
companion `omarchy-battery`.

## What it does

-- **Main widget:** Shows the battery icon, current power usage in watts, and battery percentage. It uses Quickshell's `UPower.displayDevice` and updates automatically when the battery changes.

- **Bar settings:** You can choose what appears in the bar:
  - `showIcon` — show/hide the battery icon
  - `showWattage` — show/hide watts
  - `showPercentage` — show/hide battery percentage
  
  These options are available from the widget settings or the Customize page. The widget automatically adjusts to whatever you have enabled. When you hover over it, a highlight appears and the content slightly grows.

- **Battery icon:** Two styles are available:
  - `Battery` — normal battery icon
  - `Battery + %` — shows the percentage number inside the battery
  
  The icon is drawn using Canvas shapes instead of fonts, so it will always render correctly. The battery fill matches the real battery level and turns red at 20% or lower.
  
  When the device is charging, a lightning bolt appears over the battery and gently pulses. The animation completely stops when the device is not charging.

- **Battery history (last 24 hours):** The popup shows battery history using the stored SQLite data. The graph includes:
  - Smooth battery-level lines
  - A light gradient under the graph
  - Gridlines with battery percentage and time labels
  - Different colors for charging and draining
  - A dot showing the current battery level
  - A dashed prediction showing when the battery is expected to reach 0% while discharging
  
  The graph animates when it first opens. When you move your mouse over the graph, it shows the estimated battery level at that exact time, for example:
  `02:14 · 63.5% · Discharging`
  
  It does not only show information for the exact times when samples were recorded. The history is loaded fresh every time the popup opens, and the graph only redraws when the data changes, the mouse moves, or the opening animation runs.

- **Charging animation:** The lightning bolt uses a `SequentialAnimation` to pulse while charging. The animation only runs when `isCharging` is true, so it does nothing and causes no extra redraws when running on battery.

- **Battery prediction:** The tooltip uses recent battery samples to estimate how long until the battery is empty (`timeToEmptyMinutes`). The service keeps a small rolling history and calculates a weighted moving average. The longer-term graph prediction uses `battery-predict` with the same calculation.

- **Customize page:** At the bottom of the popup, there is a Customize section where you can:
  - Switch between `Battery` and `Battery + %`
  - Turn the icon, wattage, and percentage on/off
  - Preview different wattage effects directly in the bar
  - Change the order of the elements using left/right buttons
  - Turn graph hover details on/off
  
  When `Battery + %` is selected, the separate percentage label is automatically hidden because the percentage is already inside the icon. Switching back to `Battery` brings the percentage label back.
  
  Manual settings always take priority. All settings are saved and remain after restarting, and the Customize page stays in sync with the normal bar settings.

- **Power profiles:** Clicking the widget opens a popup showing the available power profiles:
  - Leaf = Saver
  - Gauge = Balanced
  - Lightning bolt = Performance
  
  The icons are drawn with Canvas so they always display correctly. Clicking a profile applies it. Simply opening or clicking the widget does not change the current profile.

- **Advanced settings:** It includes:
  - Sysfs fallback polling interval: 5–60 seconds. This is only used if UPower is unavailable.
  - Battery history sampling interval: 15–600 seconds.
  - Reset all settings to their defaults.
  
  Left-click opens the normal battery popup.

## Install

```sh
pending
```

Local dev — note: widget QML edits need a full shell restart to apply:

```sh
omarchy plugin validate ./battery-plus
# copy into ~/.config/omarchy/plugins/io.github.enigmazflo.battery-plus/
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
