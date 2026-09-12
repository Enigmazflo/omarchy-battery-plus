import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Battery Plus bar widget — renders only; live state lives in Service.qml,
// long-term history lives in SQLite (see omarchy-battery collector) and is
// rendered to SVG by the battery-chart helper, displayed below.
//
// INTERACTION CONTRACT (read before touching mouse handling):
// The bar's ModuleSlot overlays every widget with its own MouseArea and
// forwards clicks via pressModuleClickTarget() (Bar.qml). A widget receives
// slot clicks only if it exposes triggerPress(button) — see
// moduleTargetClickable() — ideally also registering itself with
// bar.registerClickTarget() like WidgetButton does. A bare inner MouseArea
// alone is NOT reliably reached, which is why this widget implements the
// full contract below instead of relying on MouseArea.onClicked.
//
// NOTE: widget QML edits do NOT hot-reload reliably in omarchy-shell;
// restart the shell (omarchy-restart-shell) after changing this file.
BarWidget {
  id: root
  moduleName: "io.github.enigmazflo.battery-plus"

  // --- Bar click-target contract (mirrors WidgetButton): the bar routes
  // slot clicks here (see moduleTargetClickable in Bar.qml).
  property bool interactive: true
  property bool pressable: true
  property bool concealed: false
  property var registeredBar: null

  function triggerPress(button) {
    if (bar) bar.hideTooltip(root)
    handlePress(button)
  }

  function syncClickRegistration() {
    if (registeredBar && typeof registeredBar.unregisterClickTarget === "function")
      registeredBar.unregisterClickTarget(root)
    registeredBar = bar
    if (registeredBar && typeof registeredBar.registerClickTarget === "function")
      registeredBar.registerClickTarget(root)
  }

  onBarChanged: syncClickRegistration()
  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: {
    if (registeredBar && typeof registeredBar.unregisterClickTarget === "function")
      registeredBar.unregisterClickTarget(root)
  }

  // Single entry point for ALL presses (bar-forwarded AND inner MouseArea).
  // Exactly-once delivery: for left-click the bar consumes the event when it
  // forwards, so the inner MouseArea never refires; for right-click the
  // bar's slot handler doesn't accept the button, so only the MouseArea fires.
  //
  // Deliberately SAFE: no press ever changes the power profile by itself.
  // Profiles change only via explicit selection in the popup. Any press
  // toggles the popup.
  function handlePress(button) {
    if (!svc) return
    if (!popupOpen) {
      popupOpen = true
      // Right-click jumps straight to the Advanced (workings) section;
      // any other button opens the standard view.
      if (button === Qt.RightButton) showAdvanced = true
      svc.refreshProfiles()
      refreshChart()
    } else {
      close()
    }
  }

  readonly property var svc: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
    ? bar.shell.serviceFor(moduleName) : null

  readonly property bool present: svc ? !!svc.isPresent : true
  readonly property bool charging: svc ? !!svc.isCharging : false
  readonly property string wattsText: svc ? String(svc.wattsText || "") : ""
  readonly property int pct: svc ? Number(svc.percentage || 0) : -1
  readonly property string tipText: svc ? String(svc.tooltipText || "") : ""

  // --- User-visible toggles (bar settings UI, see manifest schema) ---
  readonly property bool showIcon: setting("showIcon", true) === true
  readonly property bool showWattage: setting("showWattage", true) === true
  readonly property bool showPercentage: setting("showPercentage", true) === true
  // "Battery" | "Battery + %" — Canvas-drawn, so it renders with any
  // font. Plain fills to the real percentage; the +% variant leaves the
  // body empty and sets the number inside it instead.
  readonly property string iconStyle: String(setting("iconStyle", "Battery") || "Battery")
  readonly property bool iosPct: iconStyle === "Battery + %"
  // Base icon size tracks the bar; renders slightly smaller so the
  // heavier border + cap match neighboring icons optically.
  readonly property real iconScale: 0.86
  // Single-phase driver for ALL charging FX (bolt pulse + wattage glow +
  // icon halo stay in sync). 0..1, driven by chargeAnim below; only runs
  // while charging, so zero cost on battery.
  property real chargePhase: 0
  readonly property bool chargeFx: root.charging && root.visible && root.present
  readonly property string chargeGlowColor: "#4CC38A"
  // Wattage animation style (bar-settings dropdown + in-popup selector):
  // "Glow" | "Counting" | "Shimmer" | "Heat" | "Off".
  readonly property string wattageFx: String(setting("wattageFx", "Glow") || "Glow")
  readonly property real wattsVal: svc ? Number(svc.watts || 0) : 0
  // Animated copy of the wattage for the Counting style — Behavior glides
  // it toward each new reading instead of jumping.
  property real wattsShown: 0
  Behavior on wattsShown { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
  // Text actually rendered (Counting reads the gliding value, rest are live).
  readonly property string wattsDisplay: wattageFx === "Counting"
    ? (wattsShown.toFixed(1) + "W") : wattsText
  // Shimmer sweep state: direction of the last change (+1 climbing => the
  // glow reveals left-to-right, -1 dropping => right-to-left), 0..1 reveal
  // position, trailing fade opacity, and the previous value for direction.
  property int wattsDir: 1
  property real shimmerSweep: 0
  property real shimmerOpacity: 0
  property real shimmerPrevVal: 0
  property string shimmerHtml: ""
  SequentialAnimation {
    id: shimmerAnim
    NumberAnimation { target: root; property: "shimmerSweep"; from: 0; to: 1; duration: 450; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "shimmerOpacity"; from: 1; to: 0; duration: 300; easing.type: Easing.InOutQuad }
  }
  // Builds the overlay HTML: revealed digits glow, the rest (and the "W"
  // suffix) stay transparent so the plain label shows through. Works on
  // any theme — the glow is a lightened foreground, not fixed white.
  function rebuildShimmer() {
    var s = String(wattsDisplay || "")
    var body = (s.length > 0 && s.charAt(s.length - 1) === "W") ? s.slice(0, -1) : s
    var m = body.length
    if (m === 0) { shimmerHtml = ""; return }
    var lit = Qt.lighter(root.bar ? root.bar.barForeground : "#ffffff", 1.8)
    var out = ""
    for (var i = 0; i < m; i++) {
      var frac = m > 1 ? (wattsDir > 0 ? i / (m - 1) : (m - 1 - i) / (m - 1)) : 1
      if (frac <= shimmerSweep + 0.0001) out += '<font color="' + lit + '">' + body[i] + "</font>"
      else out += '<font color="transparent">' + body[i] + "</font>"
    }
    if (s.length > m) out += '<font color="transparent">W</font>'
    shimmerHtml = out
  }
  function wattsHeatColor(w) {
    w = Number(w) || 0
    if (w < 10) return root.chargeGlowColor
    if (w < 20) return "#E5A63B"
    return String(Color.urgent)
  }

  // Bar-element toggle state: is "icon" | "watts" | "pct" shown?
  function elementOn(ekey) {
    if (ekey === "icon") return root.showIcon
    if (ekey === "watts") return root.showWattage
    return root.showPercentage
  }

  // Percentage goes through manualPctToggle so a manual choice always wins
  // over the Battery +% auto-hide; the others save directly.
  function toggleElement(ekey) {
    if (ekey === "icon") root.saveSetting("showIcon", !root.showIcon)
    else if (ekey === "watts") root.saveSetting("showWattage", !root.showWattage)
    else root.manualPctToggle()
  }

  function shortElementLabel(ekey) {
    if (ekey === "icon") return "Icon"
    if (ekey === "watts") return "Watts"
    return "Percent"
  }

  // Mini element glyphs for the Customize cards (canvas-drawn, no font
  // glyphs — "%" is ASCII text, always safe). Static outlines only, so no
  // repaint wiring is needed on value changes.
  function paintElementIcon(canvas, ekey) {
    if (!canvas) return
    var ctx = canvas.getContext("2d")
    var W = canvas.width, H = canvas.height
    ctx.clearRect(0, 0, W, H)
    if (W < 6 || H < 6) return
    var c = root.bar ? String(root.bar.foreground) : "#ffffff"
    if (ekey === "watts") {
      var pts = [[0.58, 0.02], [0.18, 0.56], [0.44, 0.56], [0.38, 0.98], [0.82, 0.42], [0.55, 0.42]]
      ctx.beginPath()
      ctx.moveTo(pts[0][0] * W, pts[0][1] * H)
      for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0] * W, pts[i][1] * H)
      ctx.closePath()
      ctx.fillStyle = c
      ctx.fill()
    } else {
      // Mini battery: outline + cap, unfilled.
      var lw = Math.max(1.25, H * 0.09)
      var capW = Math.max(2, H * 0.16)
      var gap = Math.max(1.5, H * 0.09)
      var bw = W - capW - gap
      rr(ctx, lw / 2, lw / 2, bw - lw, H - lw, H * 0.30)
      ctx.strokeStyle = c
      ctx.lineWidth = lw
      ctx.stroke()
      var capH = H * 0.45
      rr(ctx, bw + gap, (H - capH) / 2, capW, capH, Math.min(2, capH / 2))
      ctx.fillStyle = c
      ctx.fill()
    }
  }

  // Wattage-effect glyphs for the Customize cards (canvas-drawn, static —
  // no repaint wiring needed). Each glyph hints at its effect.
  function paintFxIcon(canvas, fx) {
    if (!canvas) return
    var ctx = canvas.getContext("2d")
    var W = canvas.width, H = canvas.height
    ctx.clearRect(0, 0, W, H)
    if (W < 6 || H < 6) return
    var c = root.bar ? String(root.bar.foreground) : "#ffffff"
    fx = String(fx || "")
    if (fx === "Glow") {
      // Halo dot: filled core + soft ring.
      ctx.beginPath()
      ctx.arc(W / 2, H / 2, W * 0.16, 0, Math.PI * 2)
      ctx.fillStyle = c
      ctx.fill()
      ctx.beginPath()
      ctx.arc(W / 2, H / 2, W * 0.34, 0, Math.PI * 2)
      ctx.strokeStyle = c
      ctx.lineWidth = Math.max(1.25, W * 0.08)
      ctx.stroke()
    } else if (fx === "Counting") {
      // Odometer drum: outline with divider lines.
      var lw = Math.max(1.25, W * 0.08)
      rr(ctx, lw / 2, H * 0.12, W - lw, H * 0.76, 2)
      ctx.strokeStyle = c
      ctx.lineWidth = lw
      ctx.stroke()
      ctx.beginPath()
      ctx.moveTo(lw * 2, H * 0.38)
      ctx.lineTo(W - lw * 2, H * 0.38)
      ctx.moveTo(lw * 2, H * 0.62)
      ctx.lineTo(W - lw * 2, H * 0.62)
      ctx.strokeStyle = c
      ctx.lineWidth = Math.max(1, W * 0.05)
      ctx.stroke()
    } else if (fx === "Shimmer") {
      // Four-point sparkle.
      var sp = [[0.5, 0.02], [0.61, 0.39], [0.98, 0.5], [0.61, 0.61], [0.5, 0.98], [0.39, 0.61], [0.02, 0.5], [0.39, 0.39]]
      ctx.beginPath()
      ctx.moveTo(sp[0][0] * W, sp[0][1] * H)
      for (var i = 1; i < sp.length; i++) ctx.lineTo(sp[i][0] * W, sp[i][1] * H)
      ctx.closePath()
      ctx.fillStyle = c
      ctx.fill()
    } else if (fx === "Heat") {
      // Three ascending bars.
      ctx.fillStyle = c
      var bw = W * 0.2, gap = W * 0.08, base = H * 0.9
      var hs = [0.28, 0.52, 0.78]
      for (var b = 0; b < 3; b++) {
        var bh = H * hs[b]
        ctx.fillRect(b * (bw + gap) + gap / 2, base - bh, bw, bh)
      }
    } else {
      // Off: ring with a slash.
      ctx.beginPath()
      ctx.arc(W / 2, H / 2, W * 0.34, 0, Math.PI * 2)
      ctx.strokeStyle = c
      ctx.lineWidth = Math.max(1.25, W * 0.08)
      ctx.stroke()
      ctx.beginPath()
      ctx.moveTo(W * 0.26, H * 0.74)
      ctx.lineTo(W * 0.74, H * 0.26)
      ctx.strokeStyle = c
      ctx.lineWidth = Math.max(1.25, W * 0.08)
      ctx.lineCap = "round"
      ctx.stroke()
    }
  }

  // Short display names for power profiles ("power-saver" -> "Saver").
  // Falls back to stripping a "power-" prefix and capitalizing.
  function shortProfileName(p) {
    p = String(p || "")
    if (p === "power-saver") return "Saver"
    if (p === "balanced") return "Balanced"
    if (p === "performance") return "Performance"
    if (p.indexOf("power-") === 0) p = p.slice(6)
    return p.length > 0 ? p.charAt(0).toUpperCase() + p.slice(1) : p
  }

  // Mini profile glyphs, canvas-drawn like the battery icon (no font
  // glyphs, so they can never render as tofu). Icons always paint in the
  // foreground color — selection is carried by the card fill + border, so
  // no repaint wiring is needed when the active profile changes.
  function paintProfileIcon(canvas, pname) {
    if (!canvas) return
    var ctx = canvas.getContext("2d")
    var W = canvas.width, H = canvas.height
    ctx.clearRect(0, 0, W, H)
    if (W < 6 || H < 6) return
    var c = root.bar ? String(root.bar.foreground) : "#ffffff"
    pname = String(pname || "")
    if (pname === "performance") {
      // Lightning bolt (same polygon as the charging overlay).
      var pts = [[0.58, 0.02], [0.18, 0.56], [0.44, 0.56], [0.38, 0.98], [0.82, 0.42], [0.55, 0.42]]
      ctx.beginPath()
      ctx.moveTo(pts[0][0] * W, pts[0][1] * H)
      for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0] * W, pts[i][1] * H)
      ctx.closePath()
      ctx.fillStyle = c
      ctx.fill()
    } else if (pname === "power-saver") {
      // Leaf: two quadratic cheeks + a stem.
      ctx.beginPath()
      ctx.moveTo(W * 0.20, H * 0.85)
      ctx.quadraticCurveTo(W * 0.25, H * 0.30, W * 0.85, H * 0.15)
      ctx.quadraticCurveTo(W * 0.75, H * 0.72, W * 0.20, H * 0.85)
      ctx.closePath()
      ctx.fillStyle = c
      ctx.fill()
      ctx.beginPath()
      ctx.moveTo(W * 0.24, H * 0.88)
      ctx.lineTo(W * 0.52, H * 0.55)
      ctx.strokeStyle = c
      ctx.lineWidth = Math.max(1, W * 0.07)
      ctx.lineCap = "round"
      ctx.stroke()
    } else {
      // Gauge with centered needle (balanced).
      var cx = W / 2, cy = H * 0.72, r = Math.min(W * 0.38, H * 0.55)
      ctx.beginPath()
      ctx.arc(cx, cy, r, Math.PI, 0)
      ctx.strokeStyle = c
      ctx.lineWidth = Math.max(1.25, W * 0.08)
      ctx.lineCap = "round"
      ctx.stroke()
      ctx.beginPath()
      ctx.moveTo(cx, cy)
      ctx.lineTo(cx, cy - r)
      ctx.strokeStyle = c
      ctx.lineWidth = Math.max(1.25, W * 0.08)
      ctx.lineCap = "round"
      ctx.stroke()
      ctx.beginPath()
      ctx.arc(cx - r, cy, Math.max(1, W * 0.05), 0, Math.PI * 2)
      ctx.arc(cx + r, cy, Math.max(1, W * 0.05), 0, Math.PI * 2)
      ctx.fillStyle = c
      ctx.fill()
    }
  }
  readonly property real iconH: Math.max(12, Math.min(22, barSize - 8))
  readonly property real iconW: iconH * (iosPct ? 2.8 : 2.3)
  readonly property real stH: iconH * iconScale
  readonly property real stW: iconW * iconScale
  readonly property bool anythingVisible: showIcon || showWattage || showPercentage

  property bool hovered: false

  property bool popupOpen: false
  // Advanced (workings) section: expanded via its header, or instantly by
  // right-clicking the widget. Session-only; display choices persist.
  property bool showAdvanced: false
  // Customize section: same collapsible pattern, expanded via its header.
  property bool showCustomize: false
  function close() { popupOpen = false }

  // --- 24h history chart (rendered by battery-chart into SVG) ---
  readonly property string chartBin: Quickshell.env("HOME") + "/.local/bin/battery-chart"
  readonly property string chartDb: (Quickshell.env("XDG_DATA_HOME")
    || (Quickshell.env("HOME") + "/.local/share")) + "/omarchy-battery/history.db"
  readonly property string chartPath: (Quickshell.env("XDG_DATA_HOME")
    || (Quickshell.env("HOME") + "/.local/share")) + "/omarchy-battery/chart.svg"
  readonly property string chartJson: (Quickshell.env("XDG_DATA_HOME")
    || (Quickshell.env("HOME") + "/.local/share")) + "/omarchy-battery/chart.json"
  property var graphData: null
  property bool graphReady: false
  property string chartStatus: "Opening…"
  property int hoverIdx: -1
  property real hoverT: 0
  property real graphReveal: 0
  readonly property bool hoverDetails: setting("hoverDetails", true) === true

  // Re-rendered on every popup open (fresh SQLite query, never cached).
  function refreshChart() {
    chartStatus = "Updating chart…"
    chartProc.command = [root.chartBin, "--db", root.chartDb,
      "--out", root.chartPath, "--json-out", root.chartJson, "--hours", "24"]
    if (!chartProc.running) chartProc.running = true
  }

  // Display order of the three elements. Persisted via saveSetting;
  // sanitized so a corrupt/missing value degrades to the default order.
  readonly property var elementOrder: {
    var v = setting("elementOrder", ["icon", "watts", "pct"])
    var arr = Array.isArray(v) ? v.slice() : []
    var keys = ["icon", "watts", "pct"]
    var out = []
    for (var i = 0; i < arr.length; i++)
      if (keys.indexOf(arr[i]) >= 0 && out.indexOf(arr[i]) < 0) out.push(arr[i])
    for (var j = 0; j < keys.length; j++)
      if (out.indexOf(keys[j]) < 0) out.push(keys[j])
    return out
  }

  function elementLabel(key) {
    if (key === "icon") return "Battery icon"
    if (key === "watts") return "Wattage"
    return "Percentage"
  }

  // Manual layout positions (NOT a Row positioner): Row children cannot be
  // reordered declaratively, and restacking via reparenting fires anchor
  // warnings mid-flight. Each block binds x to its slot in elementOrder.
  function blockW(key) {
    if (key === "icon") return showIcon ? stW : 0
    if (key === "watts") return showWattage ? wattsLabel.implicitWidth : 0
    return showPercentage ? pctText.implicitWidth : 0
  }

  function xFor(key) {
    var x = 0, sp = Style.space(8), p = 0
    for (var i = 0; i < elementOrder.length; i++) {
      var k = elementOrder[i]
      if (k === key) break
      var w = blockW(k)
      if (w > 0) { x += w; p++ }
    }
    return p > 0 ? x + sp * p : x
  }

  readonly property real totalW: {
    var s = blockW("icon") + blockW("watts") + blockW("pct")
    var v = (blockW("icon") > 0 ? 1 : 0) + (blockW("watts") > 0 ? 1 : 0) + (blockW("pct") > 0 ? 1 : 0)
    return s + (v > 1 ? (v - 1) * Style.space(8) : 0)
  }

  function moveElement(key, delta) {
    var order = elementOrder.slice()
    var i = order.indexOf(key), j = i + delta
    if (i < 0 || j < 0 || j >= order.length) return
    var t = order[i]
    order[i] = order[j]
    order[j] = t
    saveSetting("elementOrder", order)
  }

  onGraphRevealChanged: { if (historyCanvas) historyCanvas.requestPaint() }
  onHoverIdxChanged: { if (historyCanvas) historyCanvas.requestPaint() }
  // The cursor time changes on EVERY mousemove (unlike hoverIdx, which
  // only flips at sample boundaries) — without this the crosshair redraws
  // in steps while the caption glides.
  onHoverTChanged: { if (historyCanvas) historyCanvas.requestPaint() }

  function graphPoints() {
    if (!graphData || !Array.isArray(graphData.points)) return []
    return graphData.points
  }

  // Shared geometry so paint + hover hit-testing agree exactly. X is
  // piecewise: history maps [t0, tHistEnd] onto the main zone, the
  // forecast maps (tHistEnd, t1] onto the reserved right zone. (A single
  // mapping squeezed the forecast into the history edge and left the
  // prediction zone empty.)
  function graphMap(W, H) {
    var pts = graphPoints()
    if (pts.length < 2 || W <= 40 || H <= 30) return null
    var t0 = Number(graphData.t0), t1 = Number(graphData.t1)
    if (!(t1 > t0)) return null
    var nowTs = Number(graphData.now) || Date.now() / 1000
    var tHistEnd = Math.max(Number(pts[pts.length - 1].t), Math.min(nowTs, t1))
    if (tHistEnd > t1) tHistEnd = t1
    var padL = 30, padR = 10, padT = 6, padB = 16
    var pred = (graphData && graphData.prediction) ? graphData.prediction : null
    var predZone = pred ? Math.round(W * 0.30) : 0
    var histX1 = W - padR - predZone
    var rightX = W - padR
    function PX(t) { return padL + (Number(t) - t0) * (histX1 - padL) / Math.max(1, tHistEnd - t0) }
    function FX(t) { return histX1 + (Number(t) - tHistEnd) * (rightX - histX1) / Math.max(1, t1 - tHistEnd) }
    function TX(t) { t = Number(t); return t <= tHistEnd ? PX(t) : FX(t) }
    return { pts: pts, t0: t0, t1: t1, tHistEnd: tHistEnd, nowTs: Math.min(nowTs, t1),
      padL: padL, padR: padR, padT: padT, padB: padB,
      histX1: histX1, rightX: rightX, W: W, H: H, pred: pred,
      PX: PX, FX: FX, TX: TX }
  }

  // Monotone cubic (Fritsch–Carlson) tangents in data space. Unlike
  // Catmull-Rom this can never overshoot, so sharp charge spikes and
  // steep drops render without back-and-forth wiggles. One engine feeds
  // both stroking and hover evaluation, so the hover dot always sits
  // exactly on the drawn curve.
  property var curveRuns: []

  function monoTangents(xs, ys) {
    var n = xs.length
    if (n < 2) return []
    var d = []
    for (var i = 0; i < n - 1; i++) {
      var h = xs[i + 1] - xs[i]
      d.push(h > 0 ? (ys[i + 1] - ys[i]) / h : 0)
    }
    if (n === 2) return [d[0], d[0]]
    var m = [d[0]]
    for (var j = 1; j < n - 1; j++) {
      if (d[j - 1] === 0 || d[j] === 0 || (d[j - 1] < 0) !== (d[j] < 0)) m.push(0)
      else m.push((d[j - 1] + d[j]) / 2)
    }
    m.push(d[n - 2])
    for (var k = 0; k < n - 1; k++) {
      if (d[k] === 0) { m[k] = 0; m[k + 1] = 0; continue }
      var a = m[k] / d[k], b = m[k + 1] / d[k]
      var s2 = a * a + b * b
      if (s2 > 9) {
        var tau = 3 / Math.sqrt(s2)
        m[k] = tau * a * d[k]
        m[k + 1] = tau * b * d[k]
      }
    }
    return m
  }

  function evalBez(y0, m0, y1, m1, h, s) {
    var u = 1 - s
    var c1 = y0 + m0 * h / 3, c2 = y1 - m1 * h / 3
    return u * u * u * y0 + 3 * u * u * s * c1 + 3 * u * s * s * c2 + s * s * s * y1
  }

  function finishRun(arr, charge) {
    var xs = [], ys = []
    for (var i = 0; i < arr.length; i++) {
      xs.push(Number(arr[i].t))
      ys.push(Number(arr[i].level))
    }
    return { pts: arr, m: monoTangents(xs, ys), charge: charge }
  }

  // Split samples into charge/drain runs and fit monotone tangents once per
  // dataset (not per paint — paint and hover just consume curveRuns).
  function rebuildCurve() {
    var pts = graphPoints()
    var runs = []
    if (pts.length > 0) {
      var cur = [pts[0]]
      var curCh = pts[0].status === "Charging"
      for (var i = 1; i < pts.length; i++) {
        var rising = Number(pts[i].level) >= Number(pts[i - 1].level)
        var ch = pts[i].status === "Charging" && rising
        if (ch !== curCh) {
          runs.push(finishRun(cur, curCh))
          cur = [pts[i - 1]]
          curCh = ch
        }
        cur.push(pts[i])
      }
      runs.push(finishRun(cur, curCh))
    }
    root.curveRuns = runs
  }

  // Level on the fitted curve at wall time t (continuous hover values —
  // every x pixel resolves, not just sample instants).
  function curveAt(t) {
    var runs = root.curveRuns
    if (!runs || runs.length === 0) return null
    t = Number(t)
    for (var r = 0; r < runs.length; r++) {
      var P = runs[r].pts, M = runs[r].m
      if (P.length === 0) continue
      if (t < Number(P[0].t)) {
        if (r > 0) continue
        return { y: Number(P[0].level) }
      }
      if (t > Number(P[P.length - 1].t)) continue
      for (var i = 0; i < P.length - 1; i++) {
        var t0 = Number(P[i].t), t1 = Number(P[i + 1].t)
        if (t >= t0 && t <= t1) {
          var h = t1 - t0
          var s = h > 0 ? (t - t0) / h : 0
          return { y: evalBez(Number(P[i].level), M[i], Number(P[i + 1].level), M[i + 1], h, s) }
        }
      }
    }
    var lr = runs[runs.length - 1].pts
    var lp = lr[lr.length - 1]
    return { y: Number(lp.level) }
  }

  function strokeMono(ctx, run, PX, PY, color, width) {
    var P = run.pts, M = run.m
    if (P.length === 1) {
      ctx.beginPath()
      ctx.arc(PX(P[0].t), PY(P[0].level), Math.max(1.2, width * 0.7), 0, Math.PI * 2)
      ctx.fillStyle = color
      ctx.fill()
      return
    }
    ctx.beginPath()
    ctx.moveTo(PX(P[0].t), PY(P[0].level))
    for (var i = 0; i < P.length - 1; i++) {
      var h = Number(P[i + 1].t) - Number(P[i].t)
      ctx.bezierCurveTo(
        PX(Number(P[i].t) + h / 3), PY(Number(P[i].level) + M[i] * h / 3),
        PX(Number(P[i + 1].t) - h / 3), PY(Number(P[i + 1].level) - M[i + 1] * h / 3),
        PX(P[i + 1].t), PY(P[i + 1].level))
    }
    ctx.strokeStyle = color
    ctx.lineWidth = width
    ctx.lineJoin = "round"
    ctx.lineCap = "round"
    ctx.stroke()
  }

  function traceMonoPath(ctx, PX, PY) {
    var first = true
    for (var r = 0; r < root.curveRuns.length; r++) {
      var P = root.curveRuns[r].pts, M = root.curveRuns[r].m
      if (P.length === 0) continue
      if (P.length === 1) {
        if (first) { ctx.moveTo(PX(P[0].t), PY(P[0].level)); first = false }
        else ctx.lineTo(PX(P[0].t), PY(P[0].level))
        continue
      }
      if (first) { ctx.moveTo(PX(P[0].t), PY(P[0].level)); first = false }
      else ctx.lineTo(PX(P[0].t), PY(P[0].level))
      for (var i = 0; i < P.length - 1; i++) {
        var h = Number(P[i + 1].t) - Number(P[i].t)
        ctx.bezierCurveTo(
          PX(Number(P[i].t) + h / 3), PY(Number(P[i].level) + M[i] * h / 3),
          PX(Number(P[i + 1].t) - h / 3), PY(Number(P[i + 1].level) - M[i + 1] * h / 3),
          PX(P[i + 1].t), PY(P[i + 1].level))
      }
    }
  }

  function paintGraph() {
    var canvas = historyCanvas
    if (!canvas) return
    var ctx = canvas.getContext("2d")
    var W = canvas.width, H = canvas.height
    ctx.clearRect(0, 0, W, H)
    var g = graphMap(W, H)
    if (!g) return
    var fg = root.bar ? String(root.bar.barForeground) : "#ffffff"
    var accent = String(Color.accent)
    var chg = "#4CC38A"
    var pts = g.pts
    function PX(t) { return g.PX(t) }
    function PY(v) { return g.padT + (1 - Math.max(0, Math.min(100, Number(v))) / 100) * (H - g.padT - g.padB) }
    var lw = Math.max(1.25, H * 0.014)

    // Reveal sweep clips the trace; forecast fades in during the last bit.
    // NOTE: the clip must span the FULL plot width including the forecast
    // zone — clipping at the history edge amputates the forecast entirely.
    var edge = g.padL + (g.rightX - g.padL) * Math.max(0, Math.min(1, root.graphReveal))
    var predAlpha = Math.max(0, Math.min(1, (root.graphReveal - 0.55) / 0.45))
    ctx.save()
    ctx.beginPath()
    ctx.rect(0, 0, edge, H)
    ctx.clip()

    // Gridlines + labels.
    ctx.font = "9px monospace"
    ctx.fillStyle = Util.alpha(fg, 0.55)
    ctx.textBaseline = "middle"
    var marks = [100, 75, 50, 25, 0]
    for (var m = 0; m < marks.length; m++) {
      var gy = Math.round(PY(marks[m])) + 0.5
      ctx.strokeStyle = Util.alpha(fg, 0.16)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(g.padL, gy)
      ctx.lineTo(W - g.padR, gy)
      ctx.stroke()
      ctx.fillText(marks[m] + "%", 2, gy)
    }
    var lastTickRight = -1e9
    for (var t = 0; t <= 3; t++) {
      var tt = g.t0 + (g.t1 - g.t0) * t / 3
      var tlabel = Qt.formatDateTime(new Date(tt * 1000), "hh:mm")
      var tw = 34
      try { tw = ctx.measureText(tlabel).width } catch (e) {}
      var anchor = t === 0 ? "start" : (t === 3 ? "end" : "middle")
      var tx = g.TX(tt)
      var tleft = anchor === "start" ? tx : (anchor === "end" ? tx - tw : tx - tw / 2)
      if (t > 0 && tleft < lastTickRight + 3) continue
      lastTickRight = tleft + tw
      ctx.textAlign = anchor
      ctx.fillText(tlabel, tx, H - 6)
    }
    ctx.textAlign = "start"

    // Gradient wash under the fitted trace.
    var grad = ctx.createLinearGradient(0, g.padT, 0, H - g.padB)
    grad.addColorStop(0, Util.alpha(fg, 0.26))
    grad.addColorStop(1, Util.alpha(fg, 0.02))
    ctx.beginPath()
    traceMonoPath(ctx, PX, PY)
    if (pts.length > 0) {
      ctx.lineTo(PX(pts[pts.length - 1].t), H - g.padB)
      ctx.lineTo(PX(pts[0].t), H - g.padB)
      ctx.closePath()
    }
    ctx.fillStyle = grad
    ctx.fill()

    // Charge vs drain runs, monotone-smoothed (no overshoot wiggles).
    for (var ri = 0; ri < root.curveRuns.length; ri++) {
      var rr2 = root.curveRuns[ri]
      strokeMono(ctx, rr2, PX, PY, rr2.charge ? chg : fg, lw)
    }

    // "Now" dot.
    ctx.beginPath()
    ctx.arc(PX(pts[pts.length - 1].t), PY(pts[pts.length - 1].level), Math.max(1.8, lw), 0, Math.PI * 2)
    ctx.fillStyle = fg
    ctx.fill()

    // Dashed forecast with empty-point ring. Runs through the reserved
    // prediction zone via the TX mapping (history end → right edge).
    if (g.pred && predAlpha > 0.01) {
      var rate = Number(g.pred.rate || 0)
      var lastP = pts[pts.length - 1]
      var endT = Math.min(Number(g.pred.zero || g.t1), g.t1)
      var startT = Math.min(g.nowTs, endT)
      var zx = g.TX(endT)
      var zy = PY(Math.max(0, Number(lastP.level) - rate * Math.max(0, endT - startT) / 60))
      var x1 = g.TX(startT), y1 = PY(lastP.level)
      var dx = zx - x1, dy = zy - y1
      var len = Math.sqrt(dx * dx + dy * dy)
      ctx.globalAlpha = predAlpha
      if (len > 4) {
        var dash = 5, gap = 4, drawn = 0
        ctx.strokeStyle = accent
        ctx.lineWidth = lw
        ctx.lineCap = "butt"
        while (drawn < len) {
          var a = drawn / len, b = Math.min(1, (drawn + dash) / len)
          ctx.beginPath()
          ctx.moveTo(x1 + dx * a, y1 + dy * a)
          ctx.lineTo(x1 + dx * b, y1 + dy * b)
          ctx.stroke()
          drawn += dash + gap
        }
        ctx.beginPath()
        ctx.arc(zx, zy, Math.max(1.8, lw), 0, Math.PI * 2)
        ctx.strokeStyle = accent
        ctx.lineWidth = Math.max(1, lw * 0.7)
        ctx.stroke()
      }
      ctx.globalAlpha = 1
    }
    ctx.restore()

    // Hover crosshair (never clipped). The dot rides the fitted curve at
    // the cursor time — every x resolves a value, not just sample instants.
    if (root.hoverDetails && root.hoverIdx >= 0 && root.hoverIdx < pts.length) {
      var hv = curveAt(root.hoverT)
      var hx = PX(Math.max(g.t0, Math.min(g.t1, root.hoverT)))
      var hy = PY(hv ? hv.y : pts[root.hoverIdx].level)
      ctx.strokeStyle = Util.alpha(fg, 0.35)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(hx, g.padT)
      ctx.lineTo(hx, H - g.padB)
      ctx.stroke()
      ctx.beginPath()
      ctx.arc(hx, hy, Math.max(2.5, lw + 1), 0, Math.PI * 2)
      ctx.fillStyle = accent
      ctx.fill()
      ctx.beginPath()
      ctx.arc(hx, hy, Math.max(2.5, lw + 1), 0, Math.PI * 2)
      ctx.strokeStyle = Util.alpha(fg, 0.8)
      ctx.lineWidth = 1
      ctx.stroke()
    }
  }

  function graphHoverAt(mx) {
    var box = graphBox
    if (!box) return -1
    var g = graphMap(box.width, box.height)
    if (!g) return -1
    // Invert the piecewise TX mapping.
    var t
    if (mx <= g.histX1) {
      t = g.t0 + (mx - g.padL) * (g.tHistEnd - g.t0) / Math.max(1, g.histX1 - g.padL)
    } else {
      t = g.tHistEnd + (mx - g.histX1) * (g.t1 - g.tHistEnd) / Math.max(1, g.rightX - g.histX1)
    }
    var best = -1, bd = 1e18
    for (var i = 0; i < g.pts.length; i++) {
      var d = Math.abs(Number(g.pts[i].t) - t)
      if (d < bd) { bd = d; best = i }
    }
    root.hoverT = t
    return best
  }

  readonly property string hoverCaption: {
    if (root.hoverDetails && root.hoverIdx >= 0 && graphData && Array.isArray(graphData.points)
        && root.hoverIdx < graphData.points.length) {
      var p = graphData.points[root.hoverIdx]
      // Continuous value off the fitted curve (covers every x step), with
      // the nearest sample's status for context.
      var cv = curveAt(root.hoverT)
      var lvl = cv ? cv.y.toFixed(1) : Number(p.level).toFixed(1)
      return Qt.formatDateTime(new Date(root.hoverT * 1000), "hh:mm")
        + " · " + lvl + "% · " + String(p.status || "")
    }
    return root.graphSummary
  }

  readonly property string graphSummary: {
    if (!graphData || !Array.isArray(graphData.points) || graphData.points.length < 2)
      return "Collecting samples…"
    var pts = graphData.points
    var first = pts[0], last = pts[pts.length - 1]
    var mins = Math.max(1, Math.round((Number(last.t) - Number(first.t)) / 60))
    var spanTxt = mins < 120 ? mins + "m" : Math.floor(mins / 60) + "h " + (mins % 60) + "m"
    var s = Number(first.level) + "% → " + Number(last.level) + "% · " + spanTxt
    if (graphData.prediction && graphData.prediction.label)
      s += " · dotted: " + String(graphData.prediction.label)
    return s
  }
  // Push widget settings into the shared service (singletons don't get
  // per-widget settings injected, so the visible widget forwards them).
  function pushSettings() {
    if (!svc) return
    var p = Number(setting("pollIntervalMs", 15000))
    var s = Number(setting("sampleIntervalMs", 60000))
    if (isFinite(p) && p >= 5000 && p <= 60000) svc.pollIntervalMs = p
    if (isFinite(s) && s >= 15000 && s <= 600000) svc.sampleIntervalMs = s
  }
  // Workings, as persisted settings (driven by the Advanced steppers and
  // the bar settings form; pushed to the service on change).
  readonly property int pollMs: Number(setting("pollIntervalMs", 15000)) || 15000
  readonly property int sampleMs: Number(setting("sampleIntervalMs", 60000)) || 60000
  function stepPoll(deltaMs) {
    saveSetting("pollIntervalMs", Math.max(5000, Math.min(60000, pollMs + deltaMs)))
  }
  function stepSample(deltaMs) {
    saveSetting("sampleIntervalMs", Math.max(15000, Math.min(600000, sampleMs + deltaMs)))
  }
  function resetWorkings() {
    saveSetting("pollIntervalMs", 15000)
    saveSetting("sampleIntervalMs", 60000)
  }
  onSettingsChanged: { pushSettings(); repaintIcon() }
  onSvcChanged: {
    pushSettings()
    wattsShown = wattsVal
    if (svc && typeof svc.refreshProfiles === "function") svc.refreshProfiles()
  }
  onPctChanged: repaintIcon()
  onChargingChanged: repaintIcon()
  onBarSizeChanged: repaintIcon()
  // Park the phase at rest when FX stops so the first pulse starts clean.
  onChargeFxChanged: { if (!chargeFx) chargePhase = 0 }
  // Counting style: glide toward each new reading (Behavior animates it).
  onWattsValChanged: { if (wattageFx === "Counting") wattsShown = wattsVal }
  onWattageFxChanged: { if (wattageFx === "Counting") wattsShown = wattsVal }
  // Shimmer style: whenever the rendered text changes, reveal the glow
  // across the digits in the direction of travel, then fade it out.
  onWattsDisplayChanged: {
    if (wattageFx === "Shimmer" && showWattage) {
      wattsDir = wattsVal >= shimmerPrevVal ? 1 : -1
      shimmerOpacity = 1
      shimmerAnim.restart()
    }
    shimmerPrevVal = wattsVal
    rebuildShimmer()
  }
  onShimmerSweepChanged: rebuildShimmer()

  function repaintIcon() {
    if (batteryCanvas) batteryCanvas.requestPaint()
    if (boltCanvas) boltCanvas.requestPaint()
  }

  function rr(ctx, x, y, w, h, r) {
    r = Math.max(0, Math.min(r, w / 2, h / 2))
    ctx.beginPath()
    ctx.moveTo(x + r, y)
    ctx.lineTo(x + w - r, y)
    ctx.arc(x + w - r, y + r, r, -Math.PI / 2, 0)
    ctx.lineTo(x + w, y + h - r)
    ctx.arc(x + w - r, y + h - r, r, 0, Math.PI / 2)
    ctx.lineTo(x + r, y + h)
    ctx.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI)
    ctx.lineTo(x, y + r)
    ctx.arc(x + r, y + r, r, Math.PI, Math.PI * 1.5)
    ctx.closePath()
  }

  // Battery body: outline + terminal cap + fill width == real percentage.
  // Red fill at <=20%, foreground otherwise. No font glyphs involved, so it
  // can never render as tofu.
  function paintBattery() {
    var canvas = batteryCanvas
    if (!canvas) return
    var ctx = canvas.getContext("2d")
    var W = canvas.width, H = canvas.height
    ctx.clearRect(0, 0, W, H)
    if (W < 6 || H < 6) return
    var p = (root.pct >= 0 ? Math.max(0, Math.min(100, root.pct)) : 0) / 100
    var fg = root.bar ? String(root.bar.barForeground) : "#ffffff"
    var lw = Math.max(1.25, H * 0.09)
    var capW = Math.max(2, H * 0.16)
    var gap = Math.max(1.5, H * 0.09)
    var bw = W - capW - gap
    var fill = (root.pct >= 0 && root.pct <= 20) ? String(Color.urgent) : fg
    rr(ctx, lw / 2, lw / 2, bw - lw, H - lw, H * 0.30)
    ctx.strokeStyle = fg
    ctx.lineWidth = lw
    ctx.stroke()
    var capH = H * 0.45
    rr(ctx, bw + gap, (H - capH) / 2, capW, capH, Math.min(2, capH / 2))
    ctx.fillStyle = fg
    ctx.fill()
    var inset = lw + 1.5
    var fw = (bw - inset * 2) * p
    // The +% variant never fills: the number inside carries the level.
    if (!root.iosPct && fw > 0.5) {
      rr(ctx, inset, inset, Math.max(fw, 2), H - inset * 2, Math.min(2, (H - inset * 2) / 2))
      ctx.fillStyle = fill
      ctx.fill()
    }
  }

  // Lightning bolt for charging: drawn polygon (font-independent),
  // accent fill with a dark rim so it reads over the level fill too.
  function paintBolt() {
    var canvas = boltCanvas
    if (!canvas) return
    var ctx = canvas.getContext("2d")
    var W = canvas.width, H = canvas.height
    ctx.clearRect(0, 0, W, H)
    if (W < 4 || H < 4) return
    var pts = [[0.58, 0.02], [0.18, 0.56], [0.44, 0.56], [0.38, 0.98], [0.82, 0.42], [0.55, 0.42]]
    ctx.beginPath()
    ctx.moveTo(pts[0][0] * W, pts[0][1] * H)
    for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0] * W, pts[i][1] * H)
    ctx.closePath()
    ctx.strokeStyle = (root.bar && root.bar.background) ? String(root.bar.background) : "#000000"
    ctx.lineWidth = Math.max(1, H * 0.07)
    ctx.lineJoin = "round"
    ctx.stroke()
    ctx.fillStyle = String(Color.accent)
    ctx.fill()
  }

  // Persist one widget setting into shell.json (same pattern as other
  // Omarchy widgets) so the Customize page below survives restarts.
  // Applied instantly via root.settings + onSettingsChanged.
  function saveSetting(name, value) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[name] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Picking Battery + % hides the separate % label (it would duplicate the
  // number inside the icon); going back to plain Battery restores it — but
  // only if WE hid it (tracked via _pctAutoHidden), never overriding an
  // explicit manual toggle.
  function pickStyle(name) {
    saveSetting("iconStyle", name)
    var auto = setting("_pctAutoHidden", false) === true
    if (name === "Battery + %") {
      if (root.showPercentage) {
        saveSetting("showPercentage", false)
        saveSetting("_pctAutoHidden", true)
      }
    } else if (auto) {
      saveSetting("showPercentage", true)
      saveSetting("_pctAutoHidden", false)
    }
  }

  function manualPctToggle() {
    saveSetting("_pctAutoHidden", false)
    saveSetting("showPercentage", !root.showPercentage)
  }

  visible: present && anythingVisible
  implicitWidth: (present && anythingVisible) ? row.width + Style.space(16) : 0
  implicitHeight: barSize

  // Hover pill: soft backdrop fading in behind the content.
  BorderSurface {
    id: hoverPill
    anchors.centerIn: parent
    width: row.width + Style.space(14)
    height: barSize - Style.space(4)
    radius: height / 2
    color: root.bar ? Util.alpha(root.bar.barForeground, 0.13) : "transparent"
    borderSpec: Border.none()
    opacity: root.hovered ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
  }

  Item {
    id: row
    anchors.centerIn: parent
    width: root.totalW
    height: barSize
    scale: root.hovered ? 1.07 : 1.0
    transformOrigin: Item.Center
    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    Item {
      id: iconBox
      width: root.stW
      height: root.stH
      x: root.xFor("icon")
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showIcon
      Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

      Canvas {
        id: batteryCanvas
        anchors.fill: parent
        renderTarget: Canvas.FramebufferObject
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: root.paintBattery()
      }

      // Soft halo behind the icon while charging — a plain rounded rect
      // whose opacity breathes with chargePhase (no repaints, no effects
      // imports, so it works on any shell theme).
      Rectangle {
        id: chargeHalo
        anchors.centerIn: parent
        width: parent.width + 8
        height: parent.height + 6
        radius: height / 2
        color: root.chargeGlowColor
        opacity: root.chargeFx ? (0.10 + root.chargePhase * 0.22) : 0
        visible: opacity > 0.01
      }

      // Charging bolt overlay. Painted once per resize; the pulse below
      // only animates opacity/scale (properties, not repaints), and only
      // runs while charging — zero cost on battery.
      Canvas {
        id: boltCanvas
        width: root.stH * 0.55
        height: root.stH * 0.85
        anchors.centerIn: parent
        renderTarget: Canvas.FramebufferObject
        visible: root.charging
        transformOrigin: Item.Center
        scale: root.chargeFx ? (1.0 + root.chargePhase * 0.18) : 1.0
        opacity: root.charging ? (1.0 - root.chargePhase * 0.75) : 0.0
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: root.paintBolt()
      }

      // Percentage inside the (unfilled) icon. Plain foreground: with no
      // fill behind it there is nothing to contrast-flip against.
      Text {
        id: iconPct
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.pct >= 0 ? root.pct + "%" : ""
        color: root.bar ? root.bar.barForeground : "white"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        // Dual-dynamic: follows the system font up, capped by what fits
        // inside the icon (which itself tracks the bar size).
        font.pixelSize: Math.max(7, Math.min(Style.font.body, root.stH * 0.55))
        font.bold: true
        visible: root.iosPct && root.pct >= 0
      }

      SequentialAnimation {
        id: chargePulse
        running: root.chargeFx
        loops: Animation.Infinite
        NumberAnimation { target: root; property: "chargePhase"; from: 0; to: 1; duration: 700; easing.type: Easing.InOutQuad }
        NumberAnimation { target: root; property: "chargePhase"; from: 1; to: 0; duration: 700; easing.type: Easing.InOutQuad }
      }
    }

    // Wattage halo: same text/position as wattsLabel, drawn behind it in
    // the charging color. Glow + Counting breathe it with chargePhase —
    // brighter under real load (sips softly, gulps brightly). Load factor
    // maps ~0-25W onto 0.35-1.0. Inert when not charging.
    Text {
      id: wattsGlow
      textFormat: Text.PlainText
      x: root.xFor("watts")
      anchors.verticalCenter: parent.verticalCenter
      Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      text: root.wattsDisplay
      color: root.chargeGlowColor
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
      visible: root.showWattage && root.chargeFx && text !== ""
        && (root.wattageFx === "Glow" || root.wattageFx === "Counting")
      opacity: root.chargePhase
        * (0.35 + 0.65 * Math.min(1, root.wattsVal / 25))
    }

    Text {
      id: wattsLabel
      textFormat: Text.PlainText
      x: root.xFor("watts")
      anchors.verticalCenter: parent.verticalCenter
      Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      text: root.wattsDisplay
      // Heat tints by live draw (green <10W, amber <20W, urgent above);
      // every other style keeps the full foreground color.
      color: root.wattageFx === "Heat" ? root.wattsHeatColor(root.wattsVal)
        : (root.bar ? root.bar.barForeground : "white")
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      // System body size so it scales with the system font, full
      // foreground color so it doesn't read thin next to the percentage.
      font.pixelSize: Style.font.body
      // The Counting style replaces this with the odometer roller below
      // (this label stays as the layout measurer via blockW).
      visible: root.showWattage && text !== "" && root.wattageFx !== "Counting"
      // Clips the shimmer overlay below to the text bounds.
      clip: true

      // Shimmer text-glow: an exact twin of this label in StyledText where
      // revealed digits glow and everything else is transparent — so the
      // glow lives ON the digits themselves, tracking each change. A child
      // at (0, 0) in the same font aligns pixel-perfect with no x math.
      Text {
        id: wattsShimmerText
        textFormat: Text.StyledText
        text: root.shimmerHtml
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.body
        visible: root.showWattage && root.wattageFx === "Shimmer" && root.shimmerOpacity > 0.01
        opacity: root.shimmerOpacity
      }
    }

    // Hidden metrics for the odometer roller: digit cell size. "8" is
    // typically the widest digit; all digit cells share this width so the
    // strip never jitters as values change.
    Text {
      id: wattsMetrics
      visible: false
      textFormat: Text.PlainText
      text: "8"
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      font.pixelSize: Style.font.body
    }

    // Odometer roller for the Counting style: every digit of the wattage
    // gets its own 0-9 strip in a clipped cell, so numbers physically roll
    // up/down to their new value like a mechanical counter. Decimal point
    // and "W" render as static text between the rollers. The strip position
    // animates (Behavior on y), so direction follows the value — rolling up
    // when power climbs, down when it drops. (9↔0 wraps take the short path
    // back, like a real counter spinning home.)
    Row {
      id: wattsRoller
      x: root.xFor("watts")
      anchors.verticalCenter: parent.verticalCenter
      Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      visible: root.showWattage && root.wattageFx === "Counting" && root.wattsDisplay !== ""
      spacing: 0

      Repeater {
        model: root.wattsDisplay.length
        delegate: Item {
          required property int index
          readonly property string ch: (root.wattsDisplay[index] || "")
          readonly property bool isDig: ch >= "0" && ch <= "9"
          readonly property int dig: isDig ? Number(ch) : 0
          width: isDig ? wattsMetrics.implicitWidth : stat.implicitWidth
          height: wattsMetrics.implicitHeight
          clip: true

          Text {
            id: stat
            visible: !parent.isDig
            textFormat: Text.PlainText
            text: parent.ch
            color: root.bar ? root.bar.barForeground : "white"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: Style.font.body
          }

          Column {
            visible: parent.isDig
            y: -parent.dig * wattsMetrics.implicitHeight
            Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

            Repeater {
              model: 10
              delegate: Text {
                required property int index
                textFormat: Text.PlainText
                text: index
                width: wattsMetrics.implicitWidth
                height: wattsMetrics.implicitHeight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: root.bar ? root.bar.barForeground : "white"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: Style.font.body
              }
            }
          }
        }
      }
    }

    Text {
      id: pctText
      textFormat: Text.PlainText
      x: root.xFor("pct")
      anchors.verticalCenter: parent.verticalCenter
      Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      text: root.pct >= 0 ? root.pct + "%" : "—"
      color: root.bar ? root.bar.barForeground : "white"
      font.family: root.bar ? root.bar.fontFamily : "monospace"
      // System body size, matching the wattage readout.
      font.pixelSize: Style.font.body
      font.bold: true
      visible: root.showPercentage
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.pressable ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    enabled: root.interactive
    // Route through triggerPress (the bar contract), NOT a direct handler —
    // same as WidgetButton: internal area is the fallback path, the bar's
    // slot-forwarding is the primary path. Exactly one of them fires.
    onClicked: function(mouse) { if (root.pressable) root.triggerPress(mouse.button) }
    onEntered: {
      root.hovered = true
      if (root.bar && root.tipText !== "") root.bar.showTooltip(root, root.tipText)
    }
    onExited: {
      root.hovered = false
      if (root.bar) root.bar.hideTooltip(root)
    }
  }

  Process {
    id: chartProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: chartErr; waitForEnd: true }
    onExited: function(code) {
      if (code === 0) {
        chartFile.reload()
      } else {
        root.graphData = null
        root.graphReady = false
        var detail = String(chartErr.text || "").trim().split("\n")[0]
        root.chartStatus = detail !== "" ? detail : "Chart renderer failed (exit " + code + ")"
      }
    }
  }

  FileView {
    id: chartFile
    path: root.chartJson
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var obj = JSON.parse(text())
        if (obj && Array.isArray(obj.points) && obj.points.length >= 1) {
          root.graphData = obj
          root.rebuildCurve()
          root.graphReady = obj.points.length >= 2
          root.chartStatus = ""
          root.hoverIdx = -1
          root.graphReveal = 0
          revealAnim.restart()
        } else {
          root.graphData = null
          root.rebuildCurve()
          root.graphReady = false
          root.chartStatus = "Collecting samples…"
        }
      } catch (e) {
        root.graphData = null
        root.rebuildCurve()
        root.graphReady = false
        root.chartStatus = "Could not read history data"
      }
      if (historyCanvas) historyCanvas.requestPaint()
    }
    onLoadFailed: {
      root.graphData = null
      root.graphReady = false
      root.chartStatus = "Chart data unavailable — is the collector running?"
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(col.implicitHeight)

    Column {
      id: col
      anchors.fill: parent
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: "Power profile"
        color: root.bar ? root.bar.foreground : "white"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        text: (root.svc && root.svc.timeToEmptyText && root.svc.timeToEmptyText !== "—")
          ? ("~" + root.svc.timeToEmptyText + " until empty")
          : (root.charging ? "Charging" : (root.svc ? String(root.svc.stateName) : ""))
        color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        visible: text !== ""
      }

      // Profile cards: icon over label, 3-across (or N-across for however
      // many backends report). Equal widths, shared spacing; selection is
      // fill + border, hover is a soft wash. Click applies + dismisses.
      Row {
        id: profileRow
        width: col.width
        spacing: Style.space(6)
        visible: root.svc && root.svc.profiles.length > 0

        Repeater {
          model: root.svc ? root.svc.profiles : []
          delegate: BorderSurface {
            required property var modelData
            readonly property string pname: String(modelData || "")
            readonly property bool selected: root.svc && root.svc.activeProfile === pname
            readonly property int nCards: root.svc ? root.svc.profiles.length : 1
            property bool hovered: false

            width: (col.width - Style.space(6) * Math.max(0, nCards - 1)) / Math.max(1, nCards)
            height: profCol.implicitHeight + Style.space(12)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(root.bar.foreground, Color.accent)
              : hovered ? Util.alpha(root.bar.foreground, 0.08) : "transparent"
            borderSpec: selected ? Border.controlSpec("normal", root.bar.foreground, Color.accent) : Border.none()
            Behavior on color { ColorAnimation { duration: 120 } }

            Column {
              id: profCol
              anchors.centerIn: parent
              spacing: Style.space(4)

              Canvas {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 24
                height: 24
                renderTarget: Canvas.FramebufferObject
                onPaint: root.paintProfileIcon(this, pname)
              }

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.shortProfileName(pname)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: selected
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: hovered = true
              onExited: hovered = false
              onClicked: {
                if (root.svc) root.svc.setProfile(pname)
                root.close()
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "Battery history (24h)"
        color: root.bar ? root.bar.foreground : "white"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        text: root.chartStatus
        color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
        visible: text !== ""
      }

      Item {
        id: graphBox
        width: col.width
        height: 170
        visible: root.graphReady

        Canvas {
          id: historyCanvas
          anchors.fill: parent
          renderTarget: Canvas.FramebufferObject
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: root.paintGraph()
        }

        // Hover-only layer: never accepts buttons, so clicks pass through
        // to the popup rows beneath.
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          enabled: root.hoverDetails
          onPositionChanged: function(mouse) {
            var idx = root.graphHoverAt(mouse.x)
            if (idx !== root.hoverIdx) root.hoverIdx = idx
          }
          onExited: root.hoverIdx = -1
        }
      }

      NumberAnimation {
        id: revealAnim
        target: root
        property: "graphReveal"
        from: 0
        to: 1
        duration: 650
        easing.type: Easing.OutCubic
      }

      Text {
        textFormat: Text.PlainText
        text: root.hoverDetails ? root.hoverCaption : root.graphSummary
        color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
        visible: root.graphReady && text !== ""
      }

      Toggle {
        width: col.width
        label: "Graph hover details"
        checked: root.hoverDetails
        foreground: root.bar.foreground
        visible: root.graphReady
        onClicked: root.saveSetting("hoverDetails", !root.hoverDetails)
      }

      Item {
        width: col.width
        height: custHeader.implicitHeight + Style.space(4)

        Text {
          id: custHeader
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: (root.showCustomize ? "▾ Customize" : "▸ Customize")
          color: root.bar ? root.bar.foreground : "white"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.showCustomize = !root.showCustomize
        }
      }

      Row {
        id: styleRow
        visible: root.showCustomize
        width: col.width
        spacing: Style.space(6)

        Button {
          width: (col.width - Style.space(6)) / 2
          text: "Battery"
          selected: !root.iosPct
          foreground: root.bar.foreground
          onClicked: root.pickStyle("Battery")
        }

        Button {
          width: (col.width - Style.space(6)) / 2
          text: "Battery + %"
          selected: root.iosPct
          foreground: root.bar.foreground
          onClicked: root.pickStyle("Battery + %")
        }
      }

      // Element cards: icon over label, one per bar element. Tap toggles
      // visibility (same cards pattern as the profile row above).
      Row {
        id: elementRow
        visible: root.showCustomize
        width: col.width
        spacing: Style.space(6)

        Repeater {
          model: ["icon", "watts", "pct"]
          delegate: BorderSurface {
            required property string modelData
            readonly property string ekey: modelData
            readonly property bool isOn: root.elementOn(ekey)
            property bool hovered: false

            width: (col.width - Style.space(6) * 2) / 3
            height: elemCol.implicitHeight + Style.space(12)
            radius: Style.spacing.labelGap
            color: isOn ? Style.selectedFillFor(root.bar.foreground, Color.accent)
              : hovered ? Util.alpha(root.bar.foreground, 0.08) : "transparent"
            borderSpec: isOn ? Border.controlSpec("normal", root.bar.foreground, Color.accent) : Border.none()
            Behavior on color { ColorAnimation { duration: 120 } }

            Column {
              id: elemCol
              anchors.centerIn: parent
              spacing: Style.space(4)

              Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 24
                height: 24
                opacity: isOn ? 1.0 : 0.4
                Behavior on opacity { NumberAnimation { duration: 120 } }

                Canvas {
                  anchors.fill: parent
                  visible: ekey !== "pct"
                  renderTarget: Canvas.FramebufferObject
                  onPaint: root.paintElementIcon(this, ekey)
                }

                Text {
                  visible: ekey === "pct"
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "%"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.shortElementLabel(ekey)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: isOn
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: hovered = true
              onExited: hovered = false
              onClicked: root.toggleElement(ekey)
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.showCustomize
        text: "Wattage effect"
        color: root.bar ? root.bar.foreground : "white"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        visible: root.showCustomize && text !== ""
        text: "Applies instantly to the bar"
        color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
      }

      // Effect cards: glyph over label, all five in one row (same cards
      // pattern as the rows above). Tap previews live in the bar.
      Row {
        id: fxRow
        visible: root.showCustomize
        width: col.width
        spacing: Style.space(6)

        Repeater {
          model: ["Glow", "Counting", "Shimmer", "Heat", "Off"]
          delegate: BorderSurface {
            required property string modelData
            readonly property string fxName: modelData
            readonly property bool selected: root.wattageFx === fxName
            property bool hovered: false

            width: (col.width - Style.space(6) * 4) / 5
            height: fxCol.implicitHeight + Style.space(12)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(root.bar.foreground, Color.accent)
              : hovered ? Util.alpha(root.bar.foreground, 0.08) : "transparent"
            borderSpec: selected ? Border.controlSpec("normal", root.bar.foreground, Color.accent) : Border.none()
            Behavior on color { ColorAnimation { duration: 120 } }

            Column {
              id: fxCol
              anchors.centerIn: parent
              spacing: Style.space(4)

              Canvas {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 24
                height: 24
                renderTarget: Canvas.FramebufferObject
                onPaint: root.paintFxIcon(this, fxName)
              }

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: fxName === "Counting" ? "Count" : fxName
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: selected
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: hovered = true
              onExited: hovered = false
              onClicked: root.saveSetting("wattageFx", fxName)
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.showCustomize
        text: "Order"
        color: root.bar ? root.bar.foreground : "white"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Repeater {
        model: ["icon", "watts", "pct"]
        delegate: Row {
          required property string modelData
          visible: root.showCustomize
          readonly property string ekey: modelData
          readonly property int epos: root.elementOrder.indexOf(modelData)

          width: col.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: (epos + 1) + " · " + root.elementLabel(ekey)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width - Style.space(76)
            anchors.verticalCenter: parent.verticalCenter
          }

          Button {
            width: Style.space(32)
            text: "<"
            foreground: root.bar.foreground
            enabled: epos > 0
            opacity: enabled ? 1.0 : 0.35
            onClicked: root.moveElement(ekey, -1)
          }

          Button {
            width: Style.space(32)
            text: ">"
            foreground: root.bar.foreground
            enabled: epos >= 0 && epos < root.elementOrder.length - 1
            opacity: enabled ? 1.0 : 0.35
            onClicked: root.moveElement(ekey, 1)
          }
        }
      }

      Item {
        width: col.width
        height: advHeader.implicitHeight + Style.space(4)

        Text {
          id: advHeader
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: (root.showAdvanced ? "▾ Advanced" : "▸ Advanced")
          color: root.bar ? root.bar.foreground : "white"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.showAdvanced = !root.showAdvanced
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "Polling, sampling, internals"
        color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        visible: root.showAdvanced && text !== ""
      }

      Row {
        width: col.width
        spacing: Style.space(6)
        visible: root.showAdvanced

        Text {
          textFormat: Text.PlainText
          text: "Fallback poll"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          width: parent.width - Style.space(32) * 2 - Style.space(44) - Style.space(6) * 3
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          width: Style.space(32)
          text: "-"
          foreground: root.bar.foreground
          onClicked: root.stepPoll(-5000)
        }

        Text {
          textFormat: Text.PlainText
          text: Math.round(root.pollMs / 1000) + "s"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          width: Style.space(44)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          width: Style.space(32)
          text: "+"
          foreground: root.bar.foreground
          onClicked: root.stepPoll(5000)
        }
      }

      Row {
        width: col.width
        spacing: Style.space(6)
        visible: root.showAdvanced

        Text {
          textFormat: Text.PlainText
          text: "History sample"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          width: parent.width - Style.space(32) * 2 - Style.space(44) - Style.space(6) * 3
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          width: Style.space(32)
          text: "-"
          foreground: root.bar.foreground
          onClicked: root.stepSample(-15000)
        }

        Text {
          textFormat: Text.PlainText
          text: Math.round(root.sampleMs / 1000) + "s"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          width: Style.space(44)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          width: Style.space(32)
          text: "+"
          foreground: root.bar.foreground
          onClicked: root.stepSample(15000)
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "Fallback poll runs only when UPower has no battery (5–60s). History sample feeds prediction + graph (15–600s)."
        color: root.bar ? Qt.darker(root.bar.foreground, 1.8) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
        visible: root.showAdvanced
      }

      Button {
        width: col.width
        text: "Reset workings to defaults"
        foreground: root.bar.foreground
        visible: root.showAdvanced
        onClicked: root.resetWorkings()
      }

      Text {
        textFormat: Text.PlainText
        text: "Right-click the widget for workings · click a profile to apply · click to dismiss"
        color: root.bar ? Qt.darker(root.bar.foreground, 1.8) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }
    }
  }
}
