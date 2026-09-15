import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// Battery Plus service — headless singleton holding all state.
// The bar widget binds to this; it never polls UPower itself.
//
// Design: UPower bindings are event-driven (property-change signals).
// Timers exist only for (a) drain-history sampling, (b) debounced history
// saves, (c) sysfs fallback when UPower is unavailable. No blocking I/O on
// the UI thread — all subprocess/file reads are async (Process/FileView).
Item {
  id: root

  // Injected by shell.qml (see ensureService): shell, omarchyPath, manifest.
  property var shell: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // --- Tunables (configurable; widget settings propagate here) ---
  property int pollIntervalMs: 15000       // sysfs fallback only, 10-30s
  property int sampleIntervalMs: 60000    // drain-history sampling
  property int maxSamples: 200

  // ================= UPower (primary, event-driven) =================
  readonly property var device: UPower.displayDevice
  // NOTE: device.ready is load-bearing. Right after shell start the device
  // object exists with isPresent=true but percentage/state not yet populated
  // (0/Unknown) — treating that as real data records bogus 0% samples.
  // (device.ready !== false keeps this working if a future/past binding
  // ever lacks the ready property.)
  readonly property bool upowerAvailable: !!(device && device.ready !== false && device.isPresent)
  readonly property real upowerPct01: {
    if (!upowerAvailable) return -1
    var p = Number(device.percentage || 0)
    if (!isFinite(p)) return -1
    return Math.max(0, Math.min(1, p))
  }

  // ================= sysfs fallback (only when UPower missing) =================
  property string sysfsBase: ""
  property real sysfsPct01: -1
  property real sysfsWatts: 0
  property string sysfsState: ""
  property bool sysfsPresent: false
  readonly property bool useSysfs: !upowerAvailable
  // Platform power ceiling (W) anchoring the sparkline bands: max(30W floor,
  // Intel/AMD RAPL package max). Probed once at startup; world-readable,
  // no root needed. The 30W floor keeps bands meaningful on low-TDP machines
  // whose total system draw still swings 5-15W (screen + SoC + rest).
  property real wattBase: 30

  function sysfsDiscover() {
    if (upowerAvailable || sysfsProbe.running) return
    sysfsProbe.running = true
  }

  function parseSysfsUevent(raw) {
    var txt = String(raw || "")
    if (txt.length === 0) {
      sysfsPresent = false
      return
    }
    var cap = -1, status = "", volt = -1, cur = -1, power = -1
    var lines = txt.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var L = lines[i]
      if (L.indexOf("POWER_SUPPLY_CAPACITY=") === 0) cap = Number(L.slice(24))
      else if (L.indexOf("POWER_SUPPLY_STATUS=") === 0) status = L.slice(22).trim()
      else if (L.indexOf("POWER_SUPPLY_VOLTAGE_NOW=") === 0) volt = Number(L.slice(26))
      else if (L.indexOf("POWER_SUPPLY_CURRENT_NOW=") === 0) cur = Number(L.slice(28))
      else if (L.indexOf("POWER_SUPPLY_POWER_NOW=") === 0) power = Number(L.slice(25))
    }
    sysfsPresent = cap >= 0
    sysfsPct01 = (cap >= 0) ? Math.max(0, Math.min(1, cap / 100)) : -1
    sysfsState = status
    if (power > 0) sysfsWatts = power / 1000000.0          // µW -> W
    else if (volt > 0 && cur > 0) sysfsWatts = (volt * cur) / 1e12  // µV*µA=pW -> W
    else if (volt > 0 && cur < 0) sysfsWatts = Math.abs(volt * cur) / 1e12
    else sysfsWatts = 0
  }

  // ================= Unified battery state =================
  readonly property bool isPresent: upowerAvailable ? true : sysfsPresent
  readonly property real percentage01: upowerAvailable ? upowerPct01 : sysfsPct01
  readonly property int percentage: percentage01 >= 0 ? Math.round(percentage01 * 100) : -1

  readonly property bool isCharging: {
    if (upowerAvailable && device) return device.state === UPowerDeviceState.Charging
    return sysfsState === "Charging"
  }
  readonly property bool isDischarging: {
    if (upowerAvailable && device) {
      if (device.state === UPowerDeviceState.Discharging) return true
      // UPower.onBattery is the AC-line signal; discharging == on battery.
      return !!UPower.onBattery
    }
    return sysfsState === "Discharging"
  }
  readonly property bool isFull: {
    if (upowerAvailable && device) return device.state === UPowerDeviceState.FullyCharged || percentage01 >= 0.999
    return sysfsState === "Full" || percentage01 >= 0.999
  }
  readonly property string stateName: {
    if (!isPresent) return "unknown"
    if (isCharging) return "charging"
    if (isFull) return "full"
    if (isDischarging) return "discharging"
    return "unknown"
  }
  readonly property real watts: {
    if (upowerAvailable && device) return Math.abs(Number(device.changeRate || 0))
    return Math.max(0, Number(sysfsWatts || 0))
  }
  readonly property string wattsText: isPresent ? watts.toFixed(1) + "W" : "—"

  // ================= Drain history + prediction =================
  // Rolling samples: [{t: unixSec, pct: 0-100, watts, state}]
  property var samples: []
  // Estimated minutes until 0% while discharging; -1 = unknown.
  property int timeToEmptyMinutes: -1
  readonly property string timeToEmptyText: {
    if (!isDischarging || timeToEmptyMinutes < 0) return "—"
    var m = timeToEmptyMinutes
    if (m >= 60) return Math.floor(m / 60) + "h " + (m % 60) + "m"
    return m + "m"
  }
  readonly property string tooltipText: {
    if (!isPresent) return "No battery"
    var s = percentage + "% · " + wattsText + " · " + stateName
    if (isDischarging && timeToEmptyMinutes >= 0) s += " · ~" + timeToEmptyText + " left"
    if (!isDischarging && activeProfile !== "") s += " · " + activeProfile
    return s
  }

  readonly property string historyPath: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/battery-plus/history.json"

  function pruneSamples(now) {
    var cutoff = now - 30 * 24 * 3600  // 30 days
    var kept = []
    for (var i = 0; i < samples.length; i++)
      if (samples[i] && samples[i].t >= cutoff) kept.push(samples[i])
    // Cap length (keep most recent).
    while (kept.length > maxSamples) kept.shift()
    samples = kept
  }

  function recordSample(force) {
    // "unknown" covers UPower's Unknown/Empty/Pending states — including the
    // transient Unknown the daemon reports while still probing after shell
    // start (valid percentage, no direction yet). Such samples carry no
    // drain information and would poison the graph, so skip them.
    if (!isPresent || percentage < 0 || stateName === "unknown") return
    var now = Math.floor(Date.now() / 1000)
    if (samples.length > 0) {
      var last = samples[samples.length - 1]
      // Exact duplicates are never useful — notably the forced records
      // fired by back-to-back state signals during UPower init, which used
      // to stack identical same-second entries.
      if (last.t === now && last.pct === percentage && last.state === stateName) return
      if (!force) {
        if (now - last.t < 30) return  // min spacing: avoid UPower burst dupes
        if (last.pct === percentage && last.state === stateName) return // no change
      }
    }
    var next = samples.slice()
    next.push({ t: now, pct: percentage, watts: Math.round(watts * 100) / 100, state: stateName })
    while (next.length > maxSamples) next.shift()
    samples = next
    recomputePrediction()
    saveDebounce.restart()
  }

  // Prediction: weighted moving average of recent discharge-pair drain rates.
  // For each consecutive pair both marked discharging, rate = -dPct/dt (%/h).
  // Outliers rejected (dt<30s, dt>30min, rate<=0, rate>50%/h — suspend/idle).
  // Last 20 valid rates averaged with linear recency weights.
  // FUTURE refinements (noted, not implemented): weight recent *sessions*
  // more than older ones; exclude screen-off/idle via idle-inhibit state;
  // bucket by time-of-day/workload (e.g. separate day/night or AC-history
  // rates); blend with UPower timeToEmpty as a prior when history is thin.
  function recomputePrediction() {
    var rates = []
    for (var i = 1; i < samples.length; i++) {
      var a = samples[i - 1], b = samples[i]
      if (!a || !b) continue
      if (a.state !== "discharging" || b.state !== "discharging") continue
      var dt = b.t - a.t
      if (dt < 30 || dt > 1800) continue
      var dpct = a.pct - b.pct
      if (dpct <= 0) continue  // charged or flat — not a drain pair
      var r = dpct / dt * 3600
      if (r <= 0 || r > 50) continue
      rates.push(r)
    }
    // Keep only the most recent 20.
    while (rates.length > 20) rates.shift()
    if (rates.length === 0 || !isDischarging || percentage < 0) {
      // Fall back to live UPower estimate when history is thin.
      if (isDischarging && upowerAvailable && device && Number(device.timeToEmpty || 0) > 0) {
        timeToEmptyMinutes = Math.round(Number(device.timeToEmpty) / 60)
      } else {
        timeToEmptyMinutes = -1
      }
      return
    }
    var wSum = 0, vSum = 0
    for (var j = 0; j < rates.length; j++) {
      var w = j + 1  // linear recency weight: newest counts most
      wSum += w
      vSum += rates[j] * w
    }
    var avg = vSum / wSum
    timeToEmptyMinutes = avg > 0 ? Math.round(percentage / avg * 60) : -1
  }

  function saveHistory() {
    if (samples.length === 0) return
    try {
      var payload = JSON.stringify({ version: 1, samples: samples })
      // Async, non-blocking write via base64 (no shell-quoting hazards).
      var b64 = Qt.btoa(payload)
      saveProc.command = ["bash", "-c",
        "mkdir -p " + shellQuote(historyPath.replace(/\/[^\/]*$/, ""))
        + " && echo '" + b64 + "' | base64 -d > " + shellQuote(historyPath)]
      if (!saveProc.running) saveProc.running = true
    } catch (e) { /* never break UI on persist failure */ }
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // ================= Power profiles (backend abstraction) =================
  // UI calls ONLY refreshProfiles()/setProfile(). To swap backends (tlp,
  // auto-cpufreq), replace the backend* functions below — same signatures,
  // no UI changes needed.
  property var profiles: []
  property string activeProfile: ""
  property bool profileBusy: false

  function backendListCommand() { return ["powerprofilesctl", "list"] }
  function backendGetCommand() { return ["powerprofilesctl", "get"] }
  function backendSetCommand(p) { return ["powerprofilesctl", "set", p] }

  // powerprofilesctl list lines look like "  power-saver:", "* balanced:",
  // "  performance:". Strip markers defensively (also tolerates plain names).
  function backendParseList(raw) {
    var out = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var L = lines[i].trim()
      if (L === "" || L.indexOf(" ") >= 0 && L.indexOf(":") < 0) {
        // skip driver-detail lines ("CpuDriver: ...", "Degraded: ...")
        if (L.indexOf("Driver") >= 0 || L.indexOf("Degraded") >= 0 || L.indexOf("Platform") >= 0) continue
      }
      if (L.charAt(0) === "*") L = L.slice(1).trim()
      if (L.charAt(L.length - 1) === ":") L = L.slice(0, -1).trim()
      if (L === "" || L.indexOf(" ") >= 0 || L.indexOf(":") >= 0) continue
      if (out.indexOf(L) < 0) out.push(L)
    }
    return out
  }

  function refreshProfiles() {
    if (profileBusy) return
    if (!profileListProc.running) profileListProc.running = true
    if (!profileGetProc.running) profileGetProc.running = true
  }

  function setProfile(name) {
    if (!name || profileBusy || profileSetProc.running) return
    profileBusy = true
    profileSetProc.command = backendSetCommand(name)
    profileSetProc.running = true
  }

  // ================= Wiring (event-driven; timers are last resort) =================
  onPercentageChanged: { if (isPresent) { recordSample(false); recomputePrediction() } }
  onIsDischargingChanged: { recordSample(true); recomputePrediction(); refreshProfiles() }
  onIsChargingChanged: recordSample(true)

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      recordSample(true)
      recomputePrediction()
      refreshProfiles()
    }
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var obj = JSON.parse(text())
        if (obj && Array.isArray(obj.samples)) {
          // Sanitize: keep well-formed entries only.
          var clean = []
          for (var i = 0; i < obj.samples.length; i++) {
            var s = obj.samples[i]
            if (s && isFinite(s.t) && isFinite(s.pct) && s.pct >= 0 && s.pct <= 100) clean.push(s)
          }
          while (clean.length > root.maxSamples) clean.shift()
          root.samples = clean
          root.pruneSamples(Math.floor(Date.now() / 1000))
          root.recomputePrediction()
        }
      } catch (e) { root.samples = [] }
    }
    onLoadFailed: root.samples = []
  }

  FileView {
    id: sysfsUevent
    path: root.sysfsBase !== "" ? root.sysfsBase + "/uevent" : "/dev/null"
    watchChanges: false
    printErrors: false
    onLoaded: if (root.useSysfs) root.parseSysfsUevent(text())
    onLoadFailed: { root.sysfsPresent = false }
  }

  Process {
    id: sysfsProbe
    command: ["bash", "-c", "ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = String(text || "").trim().split("\n")[0].trim()
        if (p !== "") {
          root.sysfsBase = p
          sysfsUevent.reload()
        }
      }
    }
  }

  Process { id: saveProc }

  Process {
    id: profileListProc
    command: root.backendListCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = root.backendParseList(text)
        if (list.length > 0) root.profiles = list
      }
    }
  }

  Process {
    id: profileGetProc
    command: root.backendGetCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var cur = String(text || "").trim().split("\n")[0].trim()
        if (cur !== "") root.activeProfile = cur
      }
    }
  }

  Process {
    id: profileSetProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: {
      root.profileBusy = false
      root.refreshProfiles()
    }
  }

  // Drain sampler: the ONLY periodic timer on the happy path.
  Timer {
    id: sampler
    interval: root.sampleIntervalMs
    running: root.isPresent
    repeat: true
    triggeredOnStart: false
    onTriggered: root.recordSample(false)
  }

  // Debounced history persist (avoids a write per UPower event burst).
  Timer {
    id: saveDebounce
    interval: 5000
    repeat: false
    onTriggered: root.saveHistory()
  }

  // Sysfs fallback poll: runs ONLY when UPower has no battery.
  Timer {
    interval: root.pollIntervalMs
    running: root.useSysfs
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.sysfsBase === "") root.sysfsDiscover()
      else sysfsUevent.reload()
    }
  }

  // One-shot RAPL ceiling probe (max constraint_0 across powercap zones,
  // µW -> W). Missing/unreadable (VMs, ARM, no powercap) keeps the 30W default.
  Process {
    id: raplProbe
    command: ["bash", "-c", "cat /sys/class/powercap/*/constraint_0_max_power_uw 2>/dev/null | sort -n | tail -n1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var uw = Number(String(text || "").trim())
        if (isFinite(uw) && uw > 0) root.wattBase = Math.max(30, uw / 1000000.0)
      }
    }
  }

  Component.onCompleted: {
    if (!upowerAvailable) sysfsDiscover()
    if (!raplProbe.running) raplProbe.running = true
    refreshProfiles()
    recomputePrediction()
  }
}
