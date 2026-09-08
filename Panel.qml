import QtQuick
import QtQuick.Controls
import Quickshell
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

  // The shared data plane. One Service.qml instance exists per shell however
  // many monitors build this widget — each monitor's bar creates its own copy
  // of this Panel, and before the service split every copy ran its own
  // collector process. ensureService both fetches and lazily creates the
  // singleton; everything below binds to its stats/hist/summary.
  property var svc: null
  function bindService() {
    if (svc) return
    if (bar && bar.shell && typeof bar.shell.ensureService === "function")
      svc = bar.shell.ensureService(moduleName)
    if (svc) pushConfig()
  }
  // The service owns the collector but the settings live on this widget's
  // shell.json entry, so the view pushes them down. Idempotent across
  // monitors: every panel pushes the same values.
  function pushConfig() {
    if (svc) svc.configure(refreshInterval, historyLength, leaderWindow, useF)
  }
  Component.onCompleted: bindService()
  onBarChanged: bindService()
  onRefreshIntervalChanged: pushConfig()
  onHistoryLengthChanged: pushConfig()
  onLeaderWindowChanged: pushConfig()
  onUseFChanged: pushConfig()

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

  // Temperature presentation. The collector always speaks Celsius (so do the
  // dial scales, floors and ceilings — they are physical); conversion happens
  // only where a number is shown. tempStyle swaps the bar strip's arc dials
  // for the plain reading.
  readonly property bool useF: setting("tempUnit", "Celsius") === "Fahrenheit"
  readonly property bool tempDegreesInBar: setting("tempStyle", "Dial") === "Degrees"
  readonly property string tempSuffix: useF ? "°F" : "°C"
  function displayTemp(c) { return useF ? Math.round(c * 9 / 5 + 32) : Math.round(c) }

  // Whether the bar strip labels each instrument with its glyph. Off is for a
  // dense bar: the graphs are already distinguishable by shape and position,
  // and dropping seven glyphs plus their gaps gives the strip back roughly a
  // third of its width. The panel keeps its icons either way — it has the room,
  // and it is where you go when you want the strip spelled out.
  //
  // Tolerant of a string, because a hand-edited shell.json entry is a
  // supported way to set this and "false" there should not read as true.
  readonly property bool barIcons: {
    var v = setting("barIcons", true)
    return v !== false && v !== "false"
  }

  // Where each kind of instrument appears. The bar strip is a scarce, always-on
  // surface and the panel is not, so every instrument can be demoted to the
  // dropdown without being lost. Stored as inline settings on this widget's
  // shell.json entry — the single source of truth — written back through the
  // service (the same mutateShellConfig path the bar's own drag-and-drop
  // uses). The Bar patches `settings` on every live widget instance after a
  // write, so all monitors follow a switch with no restart.
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

  // Placement and presentation writes go through the service, which holds the
  // single write path into this widget's shell.json entry and the one
  // com.cuthriell.binnacle.bar IPC target — see Service.qml.
  function setBarVisible(key, show) { if (svc) svc.setBarVisible(key, show) }
  function writeSetting(key, value) { if (svc) svc.writeSetting(key, value) }

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
  readonly property var stats: (svc && svc.stats) ? svc.stats
    : ({ load: [], temps: [], caps: [], mem: {}, net: {}, disk: {} })

  // Histories keyed by instrument id, owned by the service. Reassigned
  // wholesale there each sample, which is what re-fires every binding here.
  readonly property var hist: (svc && svc.hist) ? svc.hist : ({})

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
        // "temp" renders the plain reading; "dial" the arc. The user picks
        // with the tempStyle toggle.
        out.push({ key: "t:" + t.id, icon: glyphs.temp,
                   kind: tempDegreesInBar ? "temp" : "dial",
                   name: L[i].label + " temp" })
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
      return t ? displayTemp(t.c) + tempSuffix : "—"
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
      return displayTemp(tempFloor) + " – " + displayTemp(critOf(t)) + tempSuffix
             + "   ·   " + t.label
             + (t.chip && t.chip !== t.label ? "   ·   " + t.chip : "")
             + (t.crit === null || t.crit === undefined ? "   ·   no critical point published" : "")
    }
    var l = loadEntry(key)
    return l ? "0 – 100%   ·   " + l.label + "   ·   " + l.scale : ""
  }

  // The settings screen's bar toggles, built by the service only when the discovered
  // topology changes — NOT per sample. A Repeater model that re-evaluated per
  // tick would tear down and rebuild the switch delegates, and a switch that
  // vanishes under the pointer between press and release drops the click.
  //
  // (The strip's metricDefs binding above DOES re-evaluate per tick. Measured
  // before leaving it that way: dropping the tick rate 5x moved shell CPU by
  // ~2 ms/s, inside the +/-6.5 ms/s noise floor — so the rebuild is not worth
  // a caching layer. The toggles differ because theirs is an interaction bug,
  // not a cost.)
  readonly property var toggleRows: svc ? svc.toggleRows : []

  // The panel is two screens: the instruments, and everything that configures
  // them. They swap rather than stack because the settings are ten switch rows
  // — as tall as the instrument column itself — and a panel carrying both was
  // a panel that scrolled on the laptop screen no matter what refit() did with
  // the graph heights. Reset on close so the panel always opens on the
  // instruments; nobody summons a system monitor to look at its settings.
  property bool settingsOpen: false
  function showSettings(on) { settingsOpen = on }

  // What a placement key currently means, spelled out under its switch. The
  // switch itself is binary (bar or not) where the setting has three values,
  // so "Hidden" would otherwise be indistinguishable from "Panel only".
  function placementLabel(key) {
    var p = placementOf(key)
    return p === "Bar + panel" ? "In the bar strip and the panel"
         : p === "Panel only"  ? "Panel only"
         : "Hidden everywhere"
  }

  // Whether any sensor drives a dial / any temperature exists at all — gates
  // for the temperature-presentation toggles.
  readonly property bool anyTempTracked: {
    var rows = toggleRows
    for (var i = 0; i < rows.length; i++) if (rows[i].key === "t:") return true
    return false
  }
  readonly property bool anyTemps: (stats.temps || []).length > 0

  // ---- sections, dealt into two balanced columns -----------------------------
  // Every stat is its own section — one instrument, the leaderboard, the
  // sensor list — and the panel deals them into two columns by height rather
  // than by category. What makes that safe is that the split is computed from
  // *estimated* heights, not measured ones: a partition that reacted to the
  // heights it produced would oscillate, and this panel already has one
  // one-way latch (compactPanel) guarding against exactly that.
  //
  // The estimate uses the nominal graph height rather than the solved
  // blockGraphH for the same reason — every instrument section carries the
  // same graph, so the balance point does not move as the solver works, and
  // the split cannot chase its own output.
  function sectionWeight(def) {
    var head = Style.font.title + Style.space(10)
    var rowH = Style.font.caption + Style.space(2)
    var pad = Style.space(16)
    if (def.kind !== "instrument") return head + def.rows * rowH + pad
    // A section with a companion dial captions both, so it is a line taller.
    return head + blockGraphMax + (def.temp !== "" ? 2 : 1) * rowH + pad
  }

  // Rebuilt only when the discovered shape changes, never per sample. The
  // models below feed Repeaters whose delegates own Canvas items; reassigning
  // them every tick tore those down and rebuilt them 30 times a minute for a
  // set of sections that had not changed.
  property var columnA: []
  property var columnB: []
  property string sectionSig: ""

  function rebuildSections() {
    if (!opened) {
      if (sectionSig !== "") { sectionSig = ""; columnA = []; columnB = [] }
      return
    }

    var defs = []
    var B = panelBlocks
    for (var i = 0; i < B.length; i++)
      defs.push({ kind: "instrument", key: B[i].key, icon: B[i].icon,
                  name: B[i].name, gkind: B[i].kind, temp: B[i].temp, rows: 0 })
    if (topRows.length > 0)
      defs.push({ kind: "top", key: "top", temp: "", rows: topRows.length })
    if (sensorRows.length > 0)
      defs.push({ kind: "sensors", key: "sensors", temp: "", rows: sensorRows.length })

    var sig = ""
    for (i = 0; i < defs.length; i++)
      sig += defs[i].kind + ":" + defs[i].key + ":" + defs[i].temp + ":" + defs[i].rows + ";"
    if (sig === sectionSig) return
    sectionSig = sig

    // Order-preserving split: the cut that leaves the two halves closest in
    // height. Order-preserving rather than greedy shortest-column packing
    // because the sections have a meaningful order — instruments, then what
    // used the CPU, then the sensors behind them — and greedy packing
    // interleaves it into a left-right-left zigzag no one can read down.
    var w = [], total = 0
    for (i = 0; i < defs.length; i++) { w.push(sectionWeight(defs[i])); total += w[i] }
    var cut = defs.length, bestDiff = Infinity, run = 0
    for (i = 0; i < defs.length; i++) {
      run += w[i]
      var diff = Math.abs(run - (total - run))
      if (diff < bestDiff) { bestDiff = diff; cut = i + 1 }
    }
    columnA = defs.slice(0, cut)
    columnB = defs.slice(cut)
  }

  function instrumentsIn(col) {
    var n = 0
    for (var i = 0; i < col.length; i++) if (col[i].kind === "instrument") n++
    return n
  }

  onTopRowsChanged: rebuildSections()
  onSensorRowsChanged: rebuildSections()

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
    // Nothing to solve while the settings screen is up, and worse than
    // nothing: the instrument column's children are invisible then, so its
    // Row and Column parents measure it at zero and the solver would hand
    // back the maximum graph height every tick.
    if (!opened || settingsOpen) return
    // Only the taller column can overflow, and only its instrument sections
    // can give: the graph height is the one dimension with slack in them.
    var n = instrumentsIn(colA.implicitHeight >= colB.implicitHeight ? columnA : columnB)
    if (n <= 0) return
    // Measured off the whole content column, not one pane: the masthead, the
    // separators and the action button are as much a claim on the budget as
    // the sections are, and they sit above and below the columns now.
    var fixed = panelColumn.implicitHeight - n * blockGraphH
    var h = (contentBudget - fixed) / n
    if (h < blockGraphMin && !compactPanel) {
      compactPanel = true
      Qt.callLater(refit)   // captions gone: re-measure and re-solve
    }
    h = Math.round(Util.clamp(h, blockGraphMin, blockGraphMax))
    if (Math.abs(h - blockGraphH) >= 1) blockGraphH = h

    // Publish this panel's numbers for the service's metrics IPC. Last writer
    // wins across monitors, which is fine for a debug readout.
    if (svc) svc.panelMetrics = {
      cardH: panel.availableCardHeight,
      inset: panel.verticalContentInset,
      budget: contentBudget,
      columnH: panelColumn.implicitHeight,
      colAH: colA.implicitHeight,
      colBH: colB.implicitHeight,
      sectionsA: columnA.length,
      sectionsB: columnB.length,
      viewportH: scrollArea.height,
      graphH: blockGraphH,
      blocks: n,
      compact: compactPanel,
      opened: opened
    }
  }
  onOpenedChanged: {
    // Always reopen on the instruments: nobody summons a system monitor to
    // look at its settings.
    if (!opened) settingsOpen = false
    rebuildSections()
    if (opened) Qt.callLater(refit)
  }
  onSettingsOpenChanged: if (opened && !settingsOpen) Qt.callLater(refit)
  onPanelBlocksChanged: {
    rebuildSections()
    if (opened) Qt.callLater(refit)
  }
  onContentBudgetChanged: { compactPanel = false; if (opened) Qt.callLater(refit) }

  // The tooltip/hero line, built by the service (it owns the data and the
  // unit preference this widget pushes down).
  readonly property string summary: svc ? svc.summary : "Reading system load…"

  // The bar underlines whichever module owns the open panel with a flat mark
  // in the theme's accent. On this widget it came out 55% of a slot that is
  // several times wider than a normal one — a long accent bar laid across the
  // bevelled bottom edge the OS 9 themes paint under the strip. Nothing
  // actually moves (the mark is absolutely positioned at z:50, and the slot's
  // size is bound to this widget's implicit size, so it cannot reflow
  // anything), but losing that bevel under the instruments reads as the strip
  // lifting off its baseline. A menu-bar item that underlines itself is also
  // not a thing OS 9 does.
  //
  // The bar takes the mark's length from these hints whenever they are
  // positive and falls back to its own 55% default otherwise — so a plain 0
  // asks for the default, and the only way to ask for no mark is a length
  // that rounds to none. Declared on both axes because the bar reads the one
  // that runs along it. If a future Omarchy clamps this to a floor, the mark
  // comes back at that floor rather than misbehaving.
  readonly property real openPanelIndicatorWidth: 0.4
  readonly property real openPanelIndicatorHeight: 0.4

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

  // The strip's textual temperature: the reading itself where the dial would
  // sit, in the unit the user chose.
  Component {
    id: tempTextComponent

    Text {
      text: {
        var t = root.tempOf(parent ? parent.metricKey : "")
        return (t === null || t === undefined) ? "—" : root.displayTemp(t) + "°"
      }
      color: root.barForeground
      font.family: root.barFont
      font.pixelSize: root.iconSize * 0.9
      renderType: Text.NativeRendering
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
    // No hover tooltip: the strip already shows the live readings, and the
    // click-through panel repeats the summary in its hero — a tooltip saying
    // the same numbers a few pixels above the graphs is pure redundancy.
    // (WidgetButton suppresses the tooltip entirely when tooltipText is empty.)
    tooltipText: ""

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
            // The fallback entry is exempt: with every instrument demoted it
            // IS the widget, and hiding it too would leave a zero-width button
            // with no way to click the panel open. (Grid drops an invisible
            // child from the layout outright, so the gap beside it goes too.)
            visible: root.barIcons || parent.modelData.kind === "none"
            text: parent.modelData.icon
            color: root.barForeground
            font.family: root.barFont
            font.pixelSize: root.vertical ? root.iconSize * 0.85 : root.iconSize
            renderType: Text.NativeRendering
          }

          Loader {
            // A dial is round, so it takes one side for both axes rather than
            // the span the strip instruments use; a bare reading ("62°") is
            // text and sizes itself.
            readonly property string kind: parent.modelData.kind
            readonly property bool isDial: kind === "dial"
            readonly property bool isTemp: kind === "temp"
            visible: kind !== "none"
            width: kind === "none" ? 0
                 : isTemp ? (item ? item.implicitWidth : 0)
                 : (isDial ? root.dialSide : root.instrumentSpan)
            height: kind === "none" ? 0
                  : isTemp ? (item ? item.implicitHeight : 0)
                  : (isDial ? root.dialSide : root.instrumentThickness)
            sourceComponent: kind === "none" ? null
                           : isDial ? dialComponent
                           : isTemp ? tempTextComponent
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
    // Wide enough for two readable section columns; fittedContentWidth still
    // clamps to the screen on narrow displays, and the columns split what is
    // left evenly.
    contentWidth: panel.fittedContentWidth(Style.space(720))
    // No explicit cap: fittedContentHeight already clamps to the screen's
    // available card height, so passing one only cut the panel short of room
    // it actually had. It still scrolls if the content genuinely overflows.
    //
    // Measured off whichever screen is up. The one that is down has invisible
    // children, so its column reports zero height — reading the wrong one here
    // collapses the panel to nothing.
    contentHeight: panel.fittedContentHeight(
      root.settingsOpen ? settingsPage.implicitHeight : panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Escape backs out of the settings screen before it closes the panel:
      // settings are a place you are inside, and a key that leaves the
      // building from the second floor loses the context you came for.
      onCloseRequested: root.settingsOpen ? root.showSettings(false) : root.close()
      onActivateRequested: if (!root.settingsOpen) root.launchBtop()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // ---------- Screen 1: the instruments ----------
      ScrollView {
        id: scrollArea
        anchors.fill: parent
        visible: !root.settingsOpen
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        // One masthead across the full width, then every section below it in
        // two height-balanced columns. Splitting sideways is what bought the
        // height headroom in the first place — the vertical budget constrains
        // max(colA, colB) instead of the sum — but which sections go where is
        // now decided by balance rather than by category. Hard-coding
        // instruments left and context right left one column short on any
        // machine whose shape differed from this one: few instruments and many
        // sensors, or the reverse.
        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(10)

          // ---------- Masthead ----------
          // Full width, so the summary gets the whole line and the way out to
          // the settings screen sits where a header action belongs.
          Item {
            id: masthead
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight,
                                     gearButton.implicitHeight)

            Text {
              id: heroIcon
              text: "󰾆"
              color: root.barForeground
              font.family: root.barFont
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              id: gearButton
              iconText: "󰒓"
              tooltipText: "Settings"
              foreground: root.barForeground
              fontFamily: root.barFont
              // Not `focusable`: PanelKeyCatcher takes Tab at BeforeItem
              // priority to switch between bar panels, so a focus ring here
              // would advertise a keyboard path that never arrives. Escape is
              // the keyboard affordance this screen actually has.
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.showSettings(true)
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: gearButton.left
              anchors.rightMargin: Style.space(10)
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
                elide: Text.ElideRight
                font.family: root.barFont
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }

          // ---------- The sections, dealt into two balanced columns ----------
          // Both columns run the same delegate over their own half of the
          // split; nothing here knows which kinds of section it is holding.
          Row {
            id: sectionRow
            width: parent.width
            spacing: Style.space(20)

            readonly property real columnWidth: Math.floor((width - spacing) / 2)

            Column {
              id: colA
              width: sectionRow.columnWidth
              spacing: Style.space(10)

              Repeater {
                model: root.columnA
                delegate: sectionDelegate
              }
            }

            Column {
              id: colB
              width: sectionRow.columnWidth
              spacing: Style.space(10)

              Repeater {
                model: root.columnB
                delegate: sectionDelegate
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

      // ---------- Screen 2: settings ----------
      // A screen rather than a section: these are ten switches, and at the
      // full panel width each one can say what it does under its label instead
      // of leaving a bare instrument name to carry the meaning.
      ScrollView {
        id: settingsArea
        anchors.fill: parent
        visible: root.settingsOpen
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: settingsPage.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: settingsArea.contentItem
          property: "interactive"
          value: settingsPage.implicitHeight > settingsArea.height
        }

        Column {
          id: settingsPage
          width: settingsArea.availableWidth
          spacing: Style.space(10)

          // ---------- Header ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(backButton.implicitHeight, settingsTitle.implicitHeight)

            PanelActionButton {
              id: backButton
              iconText: "󰅁"
              tooltipText: "Back"
              foreground: root.barForeground
              fontFamily: root.barFont
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.showSettings(false)
            }

            Text {
              id: settingsTitle
              anchors.left: backButton.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: "BINNACLE SETTINGS"
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.barFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }

          // ---------- Bar placement ----------
          // One row per discovered instrument family, same model the strip is
          // built from — so a machine with no discrete GPU has no row for one.
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.toggleRows.length > 0

            PanelSectionHeader {
              width: parent.width
              text: "IN THE BAR"
              foreground: root.barForeground
            }

            Column {
              id: barSettingGrid
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                // Gated on the screen being up, not on the panel being open:
                // these rows outlive a tick (toggleRows only changes when the
                // discovered topology does), but there is no reason to carry
                // ten BorderSurfaces for a screen nobody has asked for.
                model: root.settingsOpen ? root.toggleRows : []

                SettingRow {
                  required property var modelData
                  width: barSettingGrid.width
                  label: modelData.label
                  description: root.placementLabel(modelData.key)
                  actual: root.placementOf(modelData.key) === "Bar + panel"
                  // Eye rather than check: what this row asserts is whether the
                  // instrument is *visible* in the strip, not whether some
                  // capability is enabled.
                  onIcon: "󰈈"
                  offIcon: "󰈉"
                  foreground: root.barForeground
                  fontFamily: root.barFont
                  onRequested: function(next) { root.setBarVisible(modelData.key, next) }
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }

          // ---------- Appearance ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              width: parent.width
              text: "APPEARANCE"
              foreground: root.barForeground
            }

            Column {
              id: appearanceGrid
              width: parent.width
              spacing: Style.space(4)

              SettingRow {
                width: appearanceGrid.width
                label: "Instrument icons in the bar"
                description: root.barIcons
                  ? "Each strip instrument carries its glyph"
                  : "Graphs only — the strip gives back the width"
                actual: root.barIcons
                foreground: root.barForeground
                fontFamily: root.barFont
                onRequested: function(next) { root.writeSetting("barIcons", next) }
              }

              SettingRow {
                width: appearanceGrid.width
                visible: root.anyTemps
                label: "Fahrenheit"
                description: "Unit for every displayed reading. Dial scales stay physical."
                actual: root.useF
                foreground: root.barForeground
                fontFamily: root.barFont
                onRequested: function(next) { root.writeSetting("tempUnit", next ? "Fahrenheit" : "Celsius") }
              }

              SettingRow {
                width: appearanceGrid.width
                visible: root.anyTempTracked
                label: "Degrees in the bar, not dials"
                description: "The strip prints the reading; the panel shows the exact number either way."
                actual: root.tempDegreesInBar
                foreground: root.barForeground
                fontFamily: root.barFont
                onRequested: function(next) { root.writeSetting("tempStyle", next ? "Degrees" : "Dial") }
              }
            }
          }

          // The schema carries a dozen more settings — sample interval, graph
          // width, dial floor and ceiling — that are set once and never
          // touched. They stay where the shell already renders them rather
          // than doubling the length of this screen.
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Sample interval, graph size, sensor limits and the leaderboard window are in Setup → Plugins."
            color: root.barForeground
            opacity: 0.55
            font.family: root.barFont
            font.pixelSize: Style.font.caption
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
      rows.push({ label: label, value: displayTemp(t.c) + tempSuffix })
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
        return (t === undefined || t === null) ? "—" : root.displayTemp(t) + "°"
      }
    }
  }

  // ------------------------------------------------------------- section body
  // Both columns instantiate this. It draws the rule between sections and
  // hands the body to the component for this section's kind — which is the
  // whole reason a stat can move columns: nothing in the layout knows what
  // kind of section it is holding.
  Component {
    id: sectionDelegate

    Column {
      id: sectionRoot
      required property var modelData
      required property int index
      width: parent ? parent.width : 0
      spacing: Style.space(8)

      // Leading rather than trailing, so neither column ends on a rule
      // hanging under its last section, and neither needs to know how many
      // sections the other one was dealt.
      PanelSeparator {
        width: parent.width
        foreground: root.barForeground
        visible: sectionRoot.index > 0
      }

      Loader {
        width: parent.width
        readonly property var def: sectionRoot.modelData
        sourceComponent: sectionRoot.modelData.kind === "instrument" ? instrumentSection
                       : sectionRoot.modelData.kind === "top" ? topSection
                       : sensorsSection
      }
    }
  }

  // One instrument: its reading, its graph, and what full scale means.
  Component {
    id: instrumentSection

    Column {
      id: blockRoot
      readonly property var def: parent ? parent.def : null
      readonly property string metric: def ? def.key : ""
      readonly property string tempKey: def ? def.temp : ""
      readonly property bool hasTemp: tempKey !== ""
      readonly property real dialSize: Style.space(40)
      spacing: Style.space(5)

      // Anchored rather than laid out in a Row: the reading is variable-width
      // (a bare "17%" or a full "55% · 17.2 GB / 31.2 GB"), so it has to be
      // pinned to the right edge and allowed to elide, not pushed there by a
      // computed spacer.
      Item {
        width: parent.width
        implicitHeight: Math.max(hIcon.implicitHeight, hName.implicitHeight, hRead.implicitHeight)

        Text {
          id: hIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(20)
          horizontalAlignment: Text.AlignHCenter
          text: blockRoot.def ? blockRoot.def.icon : ""
          color: root.barForeground
          font.family: root.barFont
          font.pixelSize: Style.font.title
        }

        Text {
          id: hName
          anchors.left: hIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: blockRoot.def ? blockRoot.def.name : ""
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
          text: root.readingFor(blockRoot.metric)
                + (blockRoot.hasTemp ? "   ·   " + root.readingFor(blockRoot.tempKey) : "")
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
          sourceComponent: (blockRoot.def && blockRoot.def.gkind === "gauge") ? bigGauge : bigGraph
          readonly property string metricKey: blockRoot.metric
        }

        Loader {
          active: root.opened && blockRoot.hasTemp
          visible: blockRoot.hasTemp
          width: blockRoot.hasTemp ? blockRoot.dialSize : 0
          height: root.blockGraphH
          sourceComponent: blockRoot.hasTemp ? bigDial : null
          readonly property string metricKey: blockRoot.tempKey
        }
      }

      // Two Texts rather than one carrying a "\n": Text ignores `elide` once
      // it holds more than one line, so the joined version silently overran
      // its column and printed across the section beside it. The scale
      // captions are the longest static strings in the panel ("86 - 212°F ·
      // GeForce MX150 · nvidia · no critical point published"), and half the
      // panel width is the narrowest they have ever had to fit.
      Column {
        width: parent.width
        spacing: Style.space(1)
        // Compact mode trades these away: they are static context ("what full
        // scale means"), not readings, and they are the height that keeps a
        // small screen from fitting.
        visible: !root.compactPanel

        Text {
          width: parent.width
          text: root.scaleFor(blockRoot.metric)
          color: root.barForeground
          opacity: 0.55
          elide: Text.ElideRight
          font.family: root.barFont
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: blockRoot.hasTemp
          text: blockRoot.hasTemp ? root.scaleFor(blockRoot.tempKey) : ""
          color: root.barForeground
          opacity: 0.55
          elide: Text.ElideRight
          font.family: root.barFont
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // What actually used the CPU over the last window.
  Component {
    id: topSection

    Column {
      width: parent.width
      spacing: Style.space(4)

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
  }

  // Every sensor the collector found, named as the kernel names it.
  Component {
    id: sensorsSection

    Column {
      width: parent.width
      spacing: Style.space(4)

      PanelSectionHeader {
        width: parent.width
        text: "SENSORS"
        foreground: root.barForeground
      }

      // The label elides, never the value — a reading you cannot read is a
      // row not worth having.
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
  }
}
