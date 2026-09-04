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

  // The dropdown's bar toggles, built by the service only when the discovered
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

  // Whether any sensor drives a dial / any temperature exists at all — gates
  // for the temperature-presentation toggles.
  readonly property bool anyTempTracked: {
    var rows = toggleRows
    for (var i = 0; i < rows.length; i++) if (rows[i].key === "t:") return true
    return false
  }
  readonly property bool anyTemps: (stats.temps || []).length > 0

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

    // Publish this panel's numbers for the service's metrics IPC. Last writer
    // wins across monitors, which is fine for a debug readout.
    if (svc) svc.panelMetrics = {
      cardH: panel.availableCardHeight,
      inset: panel.verticalContentInset,
      budget: contentBudget,
      columnH: panelColumn.implicitHeight,
      leftH: leftPane.implicitHeight,
      rightH: rightPane.implicitHeight,
      viewportH: scrollArea.height,
      graphH: blockGraphH,
      blocks: n,
      compact: compactPanel,
      opened: opened
    }
  }
  onOpenedChanged: if (opened) Qt.callLater(refit)
  onPanelBlocksChanged: if (opened) Qt.callLater(refit)
  onContentBudgetChanged: { compactPanel = false; if (opened) Qt.callLater(refit) }

  // The tooltip/hero line, built by the service (it owns the data and the
  // unit preference this widget pushes down).
  readonly property string summary: svc ? svc.summary : "Reading system load…"

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
            visible: root.anyTemps
          }

          // ---------- Temperature presentation ----------
          // Unit for every displayed reading, and dial-vs-number for the bar
          // strip. Settings like the placement toggles above, so they persist
          // and the settings panel shows the same state.
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.anyTemps

            PanelSectionHeader {
              width: parent.width
              text: "TEMPERATURE"
              foreground: root.barForeground
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Item {
                width: parent.width
                implicitHeight: Math.max(fLabel.implicitHeight, fSwitch.implicitHeight) + Style.space(4)

                Text {
                  id: fLabel
                  anchors.left: parent.left
                  anchors.right: fSwitch.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: "Fahrenheit"
                  color: root.barForeground
                  opacity: 0.85
                  font.family: root.barFont
                  font.pixelSize: Style.font.body
                }

                ToggleSwitch {
                  id: fSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  trackHeight: 18
                  foreground: root.barForeground
                  checked: root.useF
                  onToggled: root.writeSetting("tempUnit", !checked ? "Fahrenheit" : "Celsius")
                }
              }

              Item {
                width: parent.width
                implicitHeight: Math.max(dLabel.implicitHeight, dSwitch.implicitHeight) + Style.space(4)
                visible: root.anyTempTracked

                Text {
                  id: dLabel
                  anchors.left: parent.left
                  anchors.right: dSwitch.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: "Degrees in the bar, not dials"
                  color: root.barForeground
                  opacity: 0.85
                  font.family: root.barFont
                  font.pixelSize: Style.font.body
                }

                ToggleSwitch {
                  id: dSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  trackHeight: 18
                  foreground: root.barForeground
                  checked: root.tempDegreesInBar
                  onToggled: root.writeSetting("tempStyle", !checked ? "Degrees" : "Dial")
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
}
