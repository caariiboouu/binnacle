import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Live system load: a strip of instruments in the bar, and a click-through
// panel with the same instruments drawn large plus the exact numbers.
//
// Rooted at Panel rather than BarWidget because this widget owns a popup, and
// Panel is what carries the open/close + IPC lifecycle the bar's summon/toggle
// routing expects. Panel does not supply BarWidget's `vertical` / `barSize`
// conveniences, so they are redeclared here.
Panel {
  id: root
  moduleName: "com.cuthriell.binnacle"
  ipcTarget: "com.cuthriell.binnacle"

  readonly property bool vertical: bar ? bar.vertical : false
  // The bar supplies the themed face; Style is the fallback when a widget
  // is instantiated outside one. Hoisted because it was spelled out 12 times.
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family

  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  readonly property int refreshInterval: setting("interval", 2000)
  readonly property int historyLength: setting("history", 32)
  readonly property real graphWidth: setting("graphWidth", 38)

  // Deliberately larger than Style.bar.iconFont, which is what the other bar
  // widgets use: these glyphs label a graph rather than standing alone, so at
  // the shared size they read as noise next to the box. Capped at heading
  // rather than iconLarge because the tallest glyphs in this set ink out ~2px
  // over their nominal size, and at iconLarge that pushed them past the top
  // and bottom of the box they sit beside.
  readonly property real iconSize: setting("iconSize", Style.font.heading)

  // Percentage graphs are pinned to 0..100 so their height always means the
  // same thing. Network has no natural ceiling, so it scales to its own recent
  // peak instead — and the floor stops an idle link from drawing background
  // chatter at full height.
  readonly property real netFloor: setting("netFloorBytes", 131072)  // 128 KB/s

  // Dial floor. Below this the die is simply idle and the arc may as well read
  // empty; scaling from 0°C would waste most of the sweep on temperatures this
  // machine never sees.
  readonly property real tempFloor: setting("tempFloorC", 30)

  // Ceiling for a dial whose sensor publishes no critical point. Sensors that
  // do publish one use theirs: this NVMe crits at 87°C, the package at 100.
  readonly property real tempCeiling: setting("tempCeilingC", 100)

  // Where each kind of instrument appears. The bar strip is a scarce, always-on
  // surface and the panel is not, so every instrument can be demoted to the
  // dropdown without being lost. Stored as inline settings on this widget's
  // shell.json entry — the single source of truth — which the panel's toggles
  // write back through bar.shell.mutateShellConfig(), the same path the bar's
  // own drag-and-drop persists through. The Bar patches `settings` on the live
  // widget after a write, so the strip follows a switch with no restart.
  readonly property string placeCpu:   setting("placeCpu",   "Bar + panel")
  readonly property string placeIgpu:  setting("placeIgpu",  "Bar + panel")
  readonly property string placeDgpu:  setting("placeDgpu",  "Bar + panel")
  readonly property string placeTemps: setting("placeTemps", "Bar + panel")
  readonly property string placeMem:   setting("placeMem",   "Bar + panel")
  readonly property string placeNet:   setting("placeNet",   "Bar + panel")
  readonly property string placeDisk:  setting("placeDisk",  "Bar + panel")
  readonly property string placeTop:   setting("placeTop",   "Panel only")
  readonly property int leaderWindow: setting("leaderWindow", 60)

  // Anything discovered that predates these settings — a second GPU, a vendor
  // this build has never seen — defaults to visible rather than vanishing.
  function placementOf(key) {
    if (key === "cpu") return placeCpu
    if (key === "igpu") return placeIgpu
    if (key === "dgpu") return placeDgpu
    if (key === "mem") return placeMem
    if (key === "net") return placeNet
    if (key.indexOf("t:") === 0) return placeTemps
    if (key.indexOf("cap:") === 0) return placeDisk
    return "Bar + panel"
  }
  function inBar(key) { return placementOf(key) === "Bar + panel" }
  function inPanel(key) { return placementOf(key) !== "Hidden" }

  // The one setting a placement key writes to. "t:" and "cap:" stand for their
  // whole families, which is also all the settings can express.
  function placementSettingKey(key) {
    if (key === "cpu") return "placeCpu"
    if (key === "igpu") return "placeIgpu"
    if (key === "dgpu") return "placeDgpu"
    if (key === "mem") return "placeMem"
    if (key === "net") return "placeNet"
    if (key.indexOf("t:") === 0) return "placeTemps"
    if (key.indexOf("cap:") === 0) return "placeDisk"
    return ""
  }

  function setPlacementValue(key, value) {
    var sk = placementSettingKey(key)
    if (!sk) return
    if (value !== "Bar + panel" && value !== "Panel only" && value !== "Hidden") return
    if (!bar || !bar.shell || typeof bar.shell.mutateShellConfig !== "function") return
    var id = root.moduleName
    bar.shell.mutateShellConfig(function(config) {
      if (!config.bar || !config.bar.layout) return
      var regions = ["left", "center", "right"]
      for (var r = 0; r < regions.length; r++) {
        var entries = config.bar.layout[regions[r]]
        if (!Array.isArray(entries)) continue
        for (var i = 0; i < entries.length; i++) {
          var e = entries[i]
          // A bare-string entry is legal shell.json; give it a body to hold
          // the setting rather than assuming the object form.
          if (e === id) { var o = { id: id }; o[sk] = value; entries[i] = o; return }
          if (e && typeof e === "object" && e.id === id) { e[sk] = value; return }
        }
      }
    })
  }

  function setBarVisible(key, show) {
    // From "Hidden", switching on restores the instrument everywhere — a
    // toggle that could only reach "Panel only" would look dead.
    setPlacementValue(key, show ? "Bar + panel" : "Panel only")
  }

  // Scriptable placement, and the cheapest proof this version of the QML is
  // actually mounted: `omarchy-shell com.cuthriell.binnacle.bar hide cpu`.
  IpcHandler {
    target: "com.cuthriell.binnacle.bar"

    function show(key: string): void { root.setBarVisible(key, true) }
    function hide(key: string): void { root.setBarVisible(key, false) }
    function place(key: string, value: string): void { root.setPlacementValue(key, value) }

    // The refit inputs, readable from a terminal. This is how the height
    // budget was debugged, and how to re-check it on a new screen or theme.
    function metrics(): string {
      return JSON.stringify({
        cardH: panel.availableCardHeight,
        inset: panel.verticalContentInset,
        budget: root.contentBudget,
        columnH: panelColumn.implicitHeight,
        leftH: leftPane.implicitHeight,
        rightH: rightPane.implicitHeight,
        viewportH: scrollArea.height,
        graphH: root.blockGraphH,
        blocks: root.panelBlocks.length,
        topRows: root.topRows.length,
        compact: root.compactPanel,
        opened: root.opened
      })
    }
  }

  // Instrument geometry. On a horizontal bar an instrument is a wide, short box
  // laid out along the bar; on a vertical one the bar's width is the budget, so
  // the box turns to run across it and the icon moves above rather than beside.
  // Both derive from barSize so a thicker bar gets bigger instruments.
  readonly property real instrumentSpan:
    vertical ? Math.max(12, Math.round(barSize * 0.62)) : graphWidth
  readonly property real instrumentThickness:
    Math.max(vertical ? 8 : 12, Math.round(barSize * (vertical ? 0.26 : 0.5)))
  readonly property real dialSide:
    Math.max(12, Math.round(barSize * (vertical ? 0.56 : 0.5)))

  // The collector answers with discovered lists, not fixed keys — see the
  // header of binnacle-collect. Nothing below names a chip, a vendor or a
  // sampling technique: the machine says what it has, and this builds
  // instruments for whatever that turns out to be.
  property var stats: ({ load: [], temps: [], caps: [], mem: {}, net: {}, disk: {} })

  // Histories keyed by instrument id. A single object rather than one property
  // per metric, because the set of metrics is not known until the collector
  // reports. Reassigned wholesale each sample: mutating in place would not
  // emit the change signal the graph bindings depend on.
  property var hist: ({})

  readonly property var glyphs: ({
    cpu: "󰻠", igpu: "󰢮", dgpu: "󰾲", gpu: "󰢮",
    mem: "󰍛", net: "󰛳", cap: "󰋊", temp: "󰔏", other: "󰘚"
  })
  function glyphOf(id) { return glyphs[id] || glyphs.other }

  // ---- lookups into the discovered lists ------------------------------------
  function loadEntry(id) {
    var L = stats.load || []
    for (var i = 0; i < L.length; i++) if (L[i].id === id) return L[i]
    return null
  }

  function tempEntry(id) {
    var T = stats.temps || []
    for (var i = 0; i < T.length; i++) if (T[i].id === id) return T[i]
    return null
  }

  function capEntry(id) {
    var C = stats.caps || []
    for (var i = 0; i < C.length; i++) if (C[i].id === id) return C[i]
    return null
  }

  // The temperature that belongs beside a load instrument. `tracks` is set by
  // the collector, which is the only layer that knows an Intel iGPU shares the
  // CPU die and an AMD one does not.
  function tempTracking(loadId) {
    var T = stats.temps || []
    for (var i = 0; i < T.length; i++) {
      var tr = T[i].tracks || []
      for (var j = 0; j < tr.length; j++) if (tr[j] === loadId) return T[i]
    }
    return null
  }

  // A sensor with no crit gets the dial's configured ceiling. Sensors differ:
  // this NVMe crits at 87°C where the package crits at 100.
  function critOf(t) {
    return (t && t.crit !== null && t.crit !== undefined) ? t.crit : tempCeiling
  }

  // ---- instrument tables, built from what was discovered --------------------
  // The bar strip: each load instrument, with its temperature dial immediately
  // after it when one tracks it.
  readonly property var metricDefs: {
    var out = []
    var L = stats.load || []
    // One sensor can track several instruments — an Intel iGPU shares the CPU
    // die, so the package reading is the honest temperature for both. Drawing
    // it once per tracker put the identical dial on the strip twice, so a
    // sensor gets a dial the first time it is claimed and not again.
    var dialled = {}
    for (var i = 0; i < L.length; i++) {
      if (inBar(L[i].id))
        out.push({ key: L[i].id, icon: glyphOf(L[i].id), kind: "graph", name: L[i].label })
      var t = tempTracking(L[i].id)
      if (t && !dialled[t.id] && inBar("t:" + t.id)) {
        dialled[t.id] = true
        out.push({ key: "t:" + t.id, icon: glyphs.temp, kind: "dial", name: L[i].label + " temp" })
      }
    }
    if (inBar("mem")) out.push({ key: "mem", icon: glyphs.mem, kind: "graph", name: "Memory" })
    if (inBar("net")) out.push({ key: "net", icon: glyphs.net, kind: "graph", name: "Network" })
    var C = stats.caps || []
    if (C.length > 0 && inBar("cap:" + C[0].id))
      out.push({ key: "cap:" + C[0].id, icon: glyphs.cap, kind: "gauge", name: C[0].label })

    // Demoting every instrument to the panel would leave a zero-width widget
    // and no way to click the panel open. One bare glyph keeps it reachable.
    if (out.length === 0)
      out.push({ key: "", icon: glyphs.other, kind: "none", name: "System stats" })
    return out
  }

  // The panel groups differently: a temperature belongs beside the thing it
  // measures, so each block carries an optional companion dial rather than
  // occupying a block of its own. Every filesystem gets a row here, where the
  // strip shows only the first.
  // Everything below feeds the dropdown only. The panel's content tree is
  // instantiated declaratively at startup, so without this gate its models
  // rebuild and its Canvas items repaint on every sample for a surface nobody
  // is looking at. Measured: the render path cost 232 ms/s with the panel
  // CLOSED, against a 2.5 ms/s shell baseline and 7 ms/s for the whole
  // collector — 32x the data plane, spent on invisible pixels.
  readonly property var panelBlocks: {
    if (!opened) return []
    var out = []
    var L = stats.load || []
    for (var i = 0; i < L.length; i++) {
      if (!inPanel(L[i].id)) continue
      var t = tempTracking(L[i].id)
      var showTemp = t && inPanel("t:" + t.id)
      out.push({ key: L[i].id, icon: glyphOf(L[i].id), kind: "graph",
                 name: L[i].label, temp: showTemp ? "t:" + t.id : "" })
    }
    if (inPanel("mem"))
      out.push({ key: "mem", icon: glyphs.mem, kind: "graph", name: "Memory", temp: "" })
    if (inPanel("net"))
      out.push({ key: "net", icon: glyphs.net, kind: "graph", name: "Network", temp: "" })
    var C = stats.caps || []
    for (var k = 0; k < C.length; k++) {
      if (!inPanel("cap:" + C[k].id)) continue
      out.push({ key: "cap:" + C[k].id, icon: glyphs.cap, kind: "gauge",
                 name: C[k].label, temp: "" })
    }
    return out
  }

  // ---- history --------------------------------------------------------------
  function pushed(arr, value) {
    var next = (arr || []).slice()
    next.push(value)
    while (next.length > historyLength) next.shift()
    return next
  }

  function peak(arr) {
    var m = 0
    for (var i = 0; i < (arr || []).length; i++) if (arr[i] > m) m = arr[i]
    return m
  }

  function normalized(arr, scale) {
    var out = []
    if (scale <= 0) return out
    for (var i = 0; i < (arr || []).length; i++) out.push(Util.clamp(arr[i] / scale, 0, 1))
    return out
  }

  // The network graph's box ceiling. Hoisted so the panel can state it — an
  // auto-scaled box is meaningless until you know its top.
  readonly property real netScale: Math.max(netFloor, peak(hist["net-down"]), peak(hist["net-up"]))

  function tempSeries(arr, crit) {
    var span = crit - tempFloor
    if (span <= 0) return []
    var out = []
    for (var i = 0; i < (arr || []).length; i++)
      out.push(Util.clamp((arr[i] - tempFloor) / span, 0, 1))
    return out
  }

  function seriesFor(key) {
    if (key === "mem") return normalized(hist.mem, 100)
    if (key === "net") return normalized(hist["net-down"], netScale)
    if (key.indexOf("cap:") === 0) return []
    if (key.indexOf("t:") === 0) {
      var t = tempEntry(key.substring(2))
      return t ? tempSeries(hist[key], critOf(t)) : []
    }
    return normalized(hist[key], 100)
  }

  // Only network is a mirrored pair; everything else fills from the bottom.
  function belowFor(key) {
    if (key !== "net") return null
    return normalized(hist["net-up"], netScale)
  }

  // A capacity gauge, not a graph: fraction of the filesystem in use.
  function gaugeFor(key) {
    if (key.indexOf("cap:") !== 0) return 0
    var c = capEntry(key.substring(4))
    return c ? c.pct / 100 : 0
  }

  // ---- dials ----------------------------------------------------------------
  function tempOf(key) {
    if (key.indexOf("t:") !== 0) return null
    var t = tempEntry(key.substring(2))
    return t ? t.c : null
  }

  function dialFor(key) {
    if (key.indexOf("t:") !== 0) return 0
    var t = tempEntry(key.substring(2))
    if (!t) return 0
    var span = critOf(t) - tempFloor
    if (span <= 0) return 0
    return Util.clamp((t.c - tempFloor) / span, 0, 1)
  }

  // Where throttling starts, as a position along this dial's own sweep.
  function markerFor(key) {
    if (key.indexOf("t:") !== 0) return -1
    var t = tempEntry(key.substring(2))
    if (!t || t.crit === null || t.crit === undefined) return -1
    var span = t.crit - tempFloor
    if (span <= 0) return -1
    return Util.clamp(((t.crit - 10) - tempFloor) / span, 0, 1)
  }

  // ---- formatting -----------------------------------------------------------
  function humanBytes(n) {
    if (!n || n < 1) return "0 B"
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = Math.floor(Math.log(n) / Math.log(1024))
    i = Math.max(0, Math.min(i, units.length - 1))
    var v = n / Math.pow(1024, i)
    return (v >= 100 || i === 0 ? v.toFixed(0) : v.toFixed(1)) + " " + units[i]
  }

  // One-line current reading per instrument, for the panel headers and the
  // bar tooltip.
  function readingFor(key) {
    if (key === "mem") {
      var m = stats.mem || {}
      return (m.pct || 0) + "%  ·  " + humanBytes(m.used) + " / " + humanBytes(m.total)
    }
    if (key === "net") {
      var n = stats.net || {}
      return "↓ " + humanBytes(n.down) + "/s   ↑ " + humanBytes(n.up) + "/s"
    }
    if (key.indexOf("cap:") === 0) {
      var c = capEntry(key.substring(4))
      return c ? c.pct + "% full  ·  " + humanBytes(c.used) + " / " + humanBytes(c.size) : "—"
    }
    if (key.indexOf("t:") === 0) {
      var t = tempEntry(key.substring(2))
      return t ? t.c + "°C" : "—"
    }
    var l = loadEntry(key)
    if (!l) return "—"
    var s = l.pct + "%"
    if (l.vramTotal > 0) s += "  ·  " + l.vramUsed + " / " + l.vramTotal + " MiB VRAM"
    return s
  }

  // What the instrument's full scale means. Every word of this now comes from
  // the collector, which read it from the kernel or from lspci — the view no
  // longer knows the name of any chip on this machine.
  function scaleFor(key) {
    if (key === "mem")
      return "0 – 100%   ·   " + humanBytes((stats.mem || {}).total) + " total"
    if (key === "net")
      return "±" + humanBytes(netScale) + "/s   ·   " + ((stats.net || {}).iface || "—")
             + "   ·   ↑ below the rule"
    if (key.indexOf("cap:") === 0) {
      var c = capEntry(key.substring(4))
      return c ? "0 – 100% of " + humanBytes(c.size) + " on " + c.label : ""
    }
    if (key.indexOf("t:") === 0) {
      var t = tempEntry(key.substring(2))
      if (!t) return ""
      return tempFloor + " – " + critOf(t) + "°C   ·   " + t.label
             + (t.chip && t.chip !== t.label ? "   ·   " + t.chip : "")
             + (t.crit === null || t.crit === undefined ? "   ·   no critical point published" : "")
    }
    var l = loadEntry(key)
    return l ? "0 – 100%   ·   " + l.label + "   ·   " + l.scale : ""
  }

  // The dropdown's bar toggles. Deliberately NOT a binding on `stats`: a
  // Repeater model that re-evaluated per sample would tear down and rebuild
  // the Toggle delegates every tick, and a switch that vanishes under the
  // pointer between press and release drops the click. Rebuilt in ingest()
  // only when the discovered topology actually changes.
  //
  // (The strip's metricDefs binding below DOES re-evaluate per tick. Measured
  // before leaving it that way: dropping the tick rate 5x moved shell CPU by
  // ~2 ms/s, inside the +/-6.5 ms/s noise floor — so the rebuild is not worth
  // a caching layer. The toggles differ because theirs is an interaction bug,
  // not a cost.)
  property var toggleRows: []
  property string toggleSig: ""

  // ---- responsive panel height ----------------------------------------------
  // The dropdown should fit the screen it opens on instead of scrolling. The
  // text sections are what they are, so the give is in the graphs: this is the
  // per-block instrument height, refit to the panel's height budget whenever
  // the content or the screen changes.
  property real blockGraphH: Style.space(40)
  readonly property real blockGraphMin: Style.space(26)
  readonly property real blockGraphMax: Style.space(40)

  // What the card can hold, from the panel's own clamp inputs — declarative
  // facts about the screen, independent of the content, so reading them here
  // cannot form a binding loop.
  readonly property real contentBudget:
    panel.availableCardHeight - panel.verticalContentInset

  // Graph height alone cannot absorb a small screen: measured on the eDP-1
  // panel (logical 1152), the column overflowed the 1082px budget by 32px
  // with every graph already at the floor — before the leaderboard section
  // even arrived. When that happens the per-block scale captions (~200px of
  // static annotation) are the next thing to give. One-way while open so the
  // two decisions cannot oscillate; a budget increase (new screen) resets it.
  property bool compactPanel: false

  // One-shot solve, not a binding: fixed = everything that is not graph area,
  // measured off the laid-out column. blockGraphH appears on both sides of
  // that measurement, but the relation is linear, so a single pass lands on
  // the answer and a second pass confirms it — where a binding on
  // implicitHeight would loop. Runs again on every sample tick, so it also
  // converges after a deferred relayout and absorbs sections that appear
  // later (the leaderboard lands at its first window boundary).
  function refit() {
    if (!opened) return
    var n = panelBlocks.length
    if (n <= 0) return
    var fixed = leftPane.implicitHeight - n * blockGraphH
    var h = (contentBudget - fixed) / n
    if (h < blockGraphMin && !compactPanel) {
      compactPanel = true
      Qt.callLater(refit)   // captions gone: re-measure and re-solve
    }
    h = Math.round(Util.clamp(h, blockGraphMin, blockGraphMax))
    if (Math.abs(h - blockGraphH) >= 1) blockGraphH = h
  }
  onOpenedChanged: if (opened) Qt.callLater(refit)
  onPanelBlocksChanged: if (opened) Qt.callLater(refit)
  onContentBudgetChanged: { compactPanel = false; if (opened) Qt.callLater(refit) }

  property string summary: "Reading system load…"

  function buildSummary() {
    var parts = []
    var L = stats.load || []
    for (var i = 0; i < L.length; i++) {
      var p = L[i].label + " " + L[i].pct + "%"
      var t = tempTracking(L[i].id)
      if (t) p += " " + t.c + "°C"
      parts.push(p)
    }
    var m = stats.mem || {}
    if (m.pct !== undefined) parts.push("Mem " + m.pct + "%")
    return parts.join("   ·   ")
  }

  // ---- collector ------------------------------------------------------------
  // Resolved relative to this file rather than found on PATH: the helper ships
  // inside the plugin, so `omarchy plugin add` installs a working widget. It
  // also sidesteps the shadowing trap — /usr/share/omarchy/bin precedes
  // ~/.local/bin on the shell's PATH, and Omarchy ships its own
  // omarchy-system-stats.
  readonly property string helperPath:
    String(Qt.resolvedUrl("binnacle-collect")).replace("file://", "")

  function ingest(line) {
    var d
    try {
      d = JSON.parse(line)
    } catch (e) {
      return   // keep the last good sample rather than poisoning the histories
    }
    if (!d || !d.load) return

    var h = {}
    for (var k in hist) h[k] = hist[k]

    var L = d.load
    for (var i = 0; i < L.length; i++) h[L[i].id] = pushed(h[L[i].id], L[i].pct)
    var T = d.temps || []
    for (var j = 0; j < T.length; j++) h["t:" + T[j].id] = pushed(h["t:" + T[j].id], T[j].c)
    h.mem = pushed(h.mem, (d.mem || {}).pct || 0)
    h["net-down"] = pushed(h["net-down"], (d.net || {}).down || 0)
    h["net-up"] = pushed(h["net-up"], (d.net || {}).up || 0)

    stats = d
    hist = h
    summary = buildSummary()

    var rows = []
    for (i = 0; i < L.length; i++) rows.push({ key: L[i].id, label: L[i].label })
    for (j = 0; j < T.length; j++)
      if ((T[j].tracks || []).length > 0) { rows.push({ key: "t:", label: "Temperature dials" }); break }
    rows.push({ key: "mem", label: "Memory" })
    rows.push({ key: "net", label: "Network" })
    if ((d.caps || []).length > 0) rows.push({ key: "cap:", label: "Disk capacity" })
    var sig = JSON.stringify(rows)
    if (sig !== toggleSig) { toggleSig = sig; toggleRows = rows }
  }

  // One long-lived collector, not a process per sample. A re-exec'd one-shot
  // measured ~15ms a tick against ~7ms here, because a cold process pays
  // execve, bash init and first-touch page faults every time.
  Process {
    id: statsProc
    running: true
    command: [root.helperPath, "--stream", String(root.refreshInterval), String(root.leaderWindow)]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: line => root.ingest(line)
    }
    // A collector that cannot read a sensor says so on stderr; surface it
    // rather than letting the strip silently freeze on its last good sample.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: line => console.warn("binnacle collector:", line)
    }
    // A collector that dies (OOM, a bad sensor read) must not take the widget
    // with it. Restart on a delay so a crash loop cannot spin the CPU.
    onExited: (code, status) => restartTimer.start()
  }

  Timer {
    id: restartTimer
    interval: 5000
    repeat: false
    onTriggered: if (!statsProc.running) statsProc.running = true
  }

  // Changing the interval or the leaderboard window means restarting the
  // collector: both are arguments to a process that is already running, and a
  // Process does not relaunch when its command binding changes.
  function restartCollector() {
    if (statsProc.running) {
      statsProc.running = false
      restartTimer.start()
    }
  }
  onRefreshIntervalChanged: restartCollector()
  onLeaderWindowChanged: restartCollector()

  // ---------------------------------------------------------------- bar strip

  Component {
    id: graphComponent

    Sparkline {
      values: root.seriesFor(parent ? parent.metricKey : "")
      below: root.belowFor(parent ? parent.metricKey : "")
      stroke: root.barForeground
    }
  }

  Component {
    id: gaugeComponent

    Gauge {
      value: root.gaugeFor(parent ? parent.metricKey : "")
      stroke: root.barForeground
    }
  }

  Component {
    id: dialComponent

    ArcDial {
      value: root.dialFor(parent ? parent.metricKey : "")
      marker: root.markerFor(parent ? parent.metricKey : "")
      stroke: root.barForeground
    }
  }

  // The button carries the size; the root takes it from the button and the
  // button fills the root. Without these two lines anchors.fill has nothing to
  // fill and the whole widget collapses to zero — silently, with no QML error.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: 6
    verticalPadding: 4
    tooltipText: root.summary

    // WidgetButton sizes itself off its text label, which this widget does not
    // use, so drive both axes off the laid-out content instead.
    //
    // BOTH axes, in both orientations. Passing -1 for the cross axis asks
    // WidgetButton to size that axis from the label — and with labelVisible
    // false the label is empty, so on a vertical bar the widget came out zero
    // wide and vanished entirely while every other widget rendered fine.
    fixedWidth: content.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: content.implicitHeight + scaledVerticalPadding * 2

    onPressed: root.toggle()

    Grid {
      id: content
      anchors.centerIn: parent
      columns: root.vertical ? 1 : root.metricDefs.length
      rows: root.vertical ? root.metricDefs.length : 1
      columnSpacing: Style.space(7)
      rowSpacing: Style.space(2)

      Repeater {
        model: root.metricDefs

        // Icon beside the instrument on a horizontal bar, above it on a
        // vertical one. A Grid rather than a Row/Column pair because Grid can
        // align its children itself — Row children need anchors to centre, and
        // anchors fight a Grid for control of x/y.
        Grid {
          required property var modelData
          columns: root.vertical ? 1 : 2
          rows: root.vertical ? 2 : 1
          spacing: Style.space(root.vertical ? 1 : 3)
          horizontalItemAlignment: Grid.AlignHCenter
          verticalItemAlignment: Grid.AlignVCenter

          Text {
            text: parent.modelData.icon
            color: root.barForeground
            font.family: root.barFont
            font.pixelSize: root.vertical ? root.iconSize * 0.85 : root.iconSize
            renderType: Text.NativeRendering
          }

          Loader {
            // A dial is round, so it takes one side for both axes rather than
            // the span the strip instruments use.
            readonly property string kind: parent.modelData.kind
            readonly property bool isDial: kind === "dial"
            visible: kind !== "none"
            width: kind === "none" ? 0 : (isDial ? root.dialSide : root.instrumentSpan)
            height: kind === "none" ? 0 : (isDial ? root.dialSide : root.instrumentThickness)
            sourceComponent: kind === "none" ? null
                           : isDial ? dialComponent
                           : kind === "gauge" ? gaugeComponent
                           : graphComponent

            // Bound here rather than inside each component so every instrument
            // reads the same delegate scope.
            readonly property string metricKey: parent.modelData.key
          }
        }
      }
    }
  }

  // -------------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Wide enough for the two panes; fittedContentWidth still clamps to the
    // screen on narrow displays, and the panes split proportionally.
    contentWidth: panel.fittedContentWidth(Style.space(720))
    // No explicit cap: fittedContentHeight already clamps to the screen's
    // available card height, so passing one only cut the panel short of room
    // it actually had. It still scrolls if the content genuinely overflows.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.launchBtop()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        // Two panes rather than one column: instruments on the left, the bar
        // toggles and the context sections on the right. Splitting sideways
        // is what actually bought the height headroom — the vertical budget
        // constrains max(left, right) instead of the sum, so the captions and
        // full-size graphs fit even on the laptop screen. (The panes keep the
        // single-column indentation of the code they absorbed; reindenting
        // ~250 lines would have drowned the actual change.)
        Row {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(20)

          Column {
          id: leftPane
          width: Math.round((panelColumn.width - panelColumn.spacing) * 0.58)
          spacing: Style.space(10)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              text: "󰾆"
              color: root.barForeground
              font.family: root.barFont
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "System"
                color: root.barForeground
                font.family: root.barFont
                font.pixelSize: Style.font.subtitle
              }

              Text {
                width: parent.width
                text: root.summary
                color: root.barForeground
                opacity: 0.7
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                font.family: root.barFont
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }

          // ---------- One block per metric ----------
          Repeater {
            model: root.panelBlocks

            Column {
              id: blockRoot
              required property var modelData
              width: leftPane.width
              spacing: Style.space(5)

              readonly property bool hasTemp: modelData.temp !== ""
              readonly property real dialSize: Style.space(40)

              // Anchored rather than laid out in a Row: the reading is
              // variable-width (a bare "17%" or a full "55% · 17.2 GB / 31.2
              // GB"), so it has to be pinned to the right edge and allowed to
              // elide, not pushed there by a computed spacer.
              Item {
                width: parent.width
                implicitHeight: Math.max(hIcon.implicitHeight, hName.implicitHeight, hRead.implicitHeight)

                Text {
                  id: hIcon
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(20)
                  horizontalAlignment: Text.AlignHCenter
                  text: blockRoot.modelData.icon
                  color: root.barForeground
                  font.family: root.barFont
                  font.pixelSize: Style.font.title
                }

                Text {
                  id: hName
                  anchors.left: hIcon.right
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: blockRoot.modelData.name
                  color: root.barForeground
                  font.family: root.barFont
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: hRead
                  anchors.left: hName.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  text: root.readingFor(blockRoot.modelData.key)
                        + (blockRoot.hasTemp ? "   ·   " + root.readingFor(blockRoot.modelData.temp) : "")
                  color: root.barForeground
                  font.family: root.barFont
                  font.pixelSize: Style.font.body
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(10)

                Loader {
                  active: root.opened
                  width: blockRoot.width - (blockRoot.hasTemp ? blockRoot.dialSize + Style.space(10) : 0)
                  height: root.blockGraphH
                  sourceComponent: blockRoot.modelData.kind === "gauge" ? bigGauge : bigGraph
                  readonly property string metricKey: blockRoot.modelData.key
                }

                Loader {
                  active: root.opened && blockRoot.hasTemp
                  visible: blockRoot.hasTemp
                  width: blockRoot.hasTemp ? blockRoot.dialSize : 0
                  height: root.blockGraphH
                  sourceComponent: blockRoot.hasTemp ? bigDial : null
                  readonly property string metricKey: blockRoot.modelData.temp
                }
              }

              Text {
                width: parent.width
                // Compact mode trades this line away: it is static context
                // ("what full scale means"), not a reading, and it is the
                // height that keeps a small screen from fitting.
                visible: !root.compactPanel
                text: root.scaleFor(blockRoot.modelData.key)
                      + (blockRoot.hasTemp ? "\n" + root.scaleFor(blockRoot.modelData.temp) : "")
                color: root.barForeground
                opacity: 0.55
                elide: Text.ElideRight
                font.family: root.barFont
                font.pixelSize: Style.font.caption
              }

              PanelSeparator {
                width: parent.width
                foreground: root.barForeground
              }
            }
          }
          }

          Column {
          id: rightPane
          width: panelColumn.width - leftPane.width - panelColumn.spacing
          spacing: Style.space(10)

          // ---------- Bar toggles ----------
          // One switch per discovered instrument family: on = in the bar
          // strip, off = dropdown only. Wired to the same place* settings the
          // settings panel edits, so the two surfaces can never disagree.
          // Placed under the instruments they control, above the detail
          // sections — at the bottom they sat below the fold on this screen.
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.toggleRows.length > 0

            PanelSectionHeader {
              width: parent.width
              text: "IN THE BAR"
              foreground: root.barForeground
            }

            // Compact rows rather than full-width `Toggle` rows: Toggle
            // carries a 54px floor per row, ~390px across seven instruments.
            // ToggleSwitch is the same control Toggle parks at the end of its
            // row, and its trackHeight exists exactly so a compact placement
            // can ask for a genuinely smaller switch.
            Column {
              id: toggleGrid
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.toggleRows

                Item {
                  required property var modelData
                  width: toggleGrid.width
                  implicitHeight: Math.max(tgLabel.implicitHeight, tgSwitch.implicitHeight) + Style.space(4)

                  Text {
                    id: tgLabel
                    anchors.left: parent.left
                    anchors.right: tgSwitch.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: parent.modelData.label
                    color: root.barForeground
                    opacity: 0.85
                    font.family: root.barFont
                    font.pixelSize: Style.font.body
                  }

                  ToggleSwitch {
                    id: tgSwitch
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    trackHeight: 18
                    foreground: root.barForeground
                    checked: root.placementOf(parent.modelData.key) === "Bar + panel"
                    onToggled: root.setBarVisible(parent.modelData.key, !checked)
                  }
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }

          // ---------- What used the CPU ----------
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.topRows.length > 0

            PanelSectionHeader {
              width: parent.width
              text: root.topHeading
              foreground: root.barForeground
            }

            Column {
              id: topGrid
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.topRows

                Item {
                  required property var modelData
                  width: topGrid.width
                  implicitHeight: Math.max(tLabel.implicitHeight, tValue.implicitHeight)

                  Text {
                    id: tLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: tValue.left
                    anchors.rightMargin: Style.space(8)
                    elide: Text.ElideRight
                    text: parent.modelData.label
                    color: root.barForeground
                    opacity: 0.7
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    id: tValue
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: parent.modelData.value
                    color: root.barForeground
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
            // Hidden with the leaderboard, or its separator and the toggles'
            // would sit stacked with nothing between them.
            visible: root.topRows.length > 0
          }

          // ---------- Thermal detail ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              width: parent.width
              text: "SENSORS"
              foreground: root.barForeground
            }

            // The label elides, never the value — a reading you cannot read
            // is a row not worth having.
            Column {
              id: sensorGrid
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.sensorRows

                Item {
                  required property var modelData
                  width: sensorGrid.width
                  implicitHeight: Math.max(sLabel.implicitHeight, sValue.implicitHeight)

                  Text {
                    id: sLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: sValue.left
                    anchors.rightMargin: Style.space(8)
                    elide: Text.ElideRight
                    text: parent.modelData.label
                    color: root.barForeground
                    opacity: 0.7
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    id: sValue
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: parent.modelData.value
                    color: root.barForeground
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }

          // ---------- Action ----------
          Button {
            width: parent.width
            iconText: "󰆍"
            text: "Open btop"
            bordered: true
            foreground: root.barForeground
            fontFamily: root.barFont
            onClicked: root.launchBtop()
          }
          }
        }
      }
    }
  }

  // What actually used the CPU over the last window, by cgroup. Not a live
  // process list: those only show what is running *while you look*, and the
  // things worth explaining — a build, a script, a burst — have exited by then.
  readonly property var topRows: {
    if (!opened) return []
    var t = stats.top
    if (!t || !t.entries || placeTop === "Hidden") return []
    var rows = []
    for (var i = 0; i < t.entries.length; i++) {
      var e = t.entries[i]
      var s = e.ms >= 1000 ? (e.ms / 1000).toFixed(1) + " s" : e.ms + " ms"
      if (t.totalMs > 0) s += "   ·   " + Math.round(e.ms * 100 / t.totalMs) + "%"
      rows.push({ label: e.label, value: s })
    }
    return rows
  }
  readonly property string topHeading:
    "CPU BY PROGRAM · LAST " + ((stats.top && stats.top.window) || 60) + "s"

  // Every sensor the collector found, named as the kernel names it. The chip
  // is appended only when it adds something: "CPU · thinkpad" disambiguates
  // the EC's reading from the package's, where "Composite · nvme" would just
  // repeat itself.
  readonly property var sensorRows: {
    if (!opened) return []
    var rows = []
    var T = placeTemps === "Hidden" ? [] : (stats.temps || [])
    for (var i = 0; i < T.length; i++) {
      var t = T[i]
      var label = (t.chip && t.chip !== t.label) ? t.label + "  ·  " + t.chip : t.label
      rows.push({ label: label, value: t.c + "°C" })
    }
    var L = stats.load || []
    for (var j = 0; j < L.length; j++)
      if (L[j].vramTotal > 0)
        rows.push({ label: L[j].label + " memory",
                    value: L[j].vramUsed + " / " + L[j].vramTotal + " MiB" })
    var m = stats.mem || {}
    if (m.swapTotal > 0)
      rows.push({ label: "Swap", value: humanBytes(m.swapUsed) + " / " + humanBytes(m.swapTotal) })
    var C = stats.caps || []
    for (var k = 1; k < C.length; k++)
      rows.push({ label: C[k].label, value: C[k].pct + "% of " + humanBytes(C[k].size) })
    return rows
  }

  // Deliberately not omarchy-launch-tui: that stamps an org.omarchy.<cmd>
  // app-id, which Hyprland tags floating-window and drops into a fixed
  // 875x600 float. Launching through the default terminal with its own
  // app-id lets btop tile like any other terminal.
  function launchBtop() {
    if (root.bar) root.bar.run("setsid uwsm-app -- xdg-terminal-exec -e btop")
    root.close()
  }

  Component {
    id: bigGraph

    Sparkline {
      values: root.seriesFor(parent ? parent.metricKey : "")
      below: root.belowFor(parent ? parent.metricKey : "")
      stroke: root.barForeground
      strokeWidth: 1.5
    }
  }

  Component {
    id: bigGauge

    Gauge {
      value: root.gaugeFor(parent ? parent.metricKey : "")
      stroke: root.barForeground
      strokeWidth: 1.5
    }
  }

  Component {
    id: bigDial

    ArcDial {
      value: root.dialFor(parent ? parent.metricKey : "")
      marker: root.markerFor(parent ? parent.metricKey : "")
      stroke: root.barForeground
      thickness: 5
      fontFamily: root.barFont
      centerFontSize: Style.font.caption
      centerText: {
        var t = root.tempOf(parent ? parent.metricKey : "")
        return (t === undefined || t === null) ? "—" : t + "°"
      }
    }
  }
}
