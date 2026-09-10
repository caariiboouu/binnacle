import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The data plane, loaded exactly once per shell by the service loader — the
// bar builds one widget per monitor, and without this every monitor ran its
// own collector process and the duplicate IPC targets fought over who
// answered. Panels are pure views: they bind to `stats`/`hist`/`summary`
// here and push their settings down via configure().
//
// The shell injects `shell` (and `manifest`) into any service that declares
// the property, which is what lets the placement writes and the IPC target
// live here — single-instance, no per-monitor collisions.
Item {
  id: root

  // Injected by the shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "com.cuthriell.binnacle"

  // This widget's shell.json entry settings, pushed down by the panel. The bar
  // re-patches every live widget after a write, so this is the freshest base
  // available to a host API that rewrites the entry wholesale — see
  // writeSetting.
  property var entrySettings: ({})
  function observeSettings(s) {
    if (s && typeof s === "object") entrySettings = s
  }

  // Collector configuration, pushed down by the widget from its shell.json
  // settings. Defaults match the manifest so a service that starts before any
  // panel binds still collects something sensible.
  property int interval: 2000
  property int history: 32
  property int leaderWindow: 60
  property bool fahrenheit: false

  function configure(intervalMs, historyLen, leaderWindowSec, useF) {
    var restart = (intervalMs !== interval || leaderWindowSec !== leaderWindow)
    interval = intervalMs
    history = historyLen
    leaderWindow = leaderWindowSec
    if (fahrenheit !== useF) {
      fahrenheit = useF
      // The summary carries temperatures; re-render it in the new unit now
      // rather than waiting out the tick.
      if ((stats.load || []).length) summary = buildSummary()
    }
    // Interval and window are arguments to a process that is already running,
    // and a Process does not relaunch when its command binding changes.
    if (restart) restartCollector()
  }

  // The collector answers with discovered lists, not fixed keys — see the
  // header of binnacle-collect. Presence is membership: a machine with no
  // discrete GPU emits no dgpu entry rather than a zero.
  property var stats: ({ load: [], temps: [], caps: [], mem: {}, net: {}, disk: {} })

  // Histories keyed by instrument id. A single object rather than one property
  // per metric, because the set of metrics is not known until the collector
  // reports. Reassigned wholesale each sample: mutating in place would not
  // emit the change signal the graph bindings depend on.
  property var hist: ({})

  property string summary: "Reading system load…"

  // The settings screen's bar toggles. Deliberately NOT derived per sample: a
  // Repeater model that re-evaluated per tick would tear down and rebuild the
  // switch delegates, and a switch that vanishes under the pointer between
  // press and release drops the click. Rebuilt only when the discovered
  // topology actually changes.
  property var toggleRows: []
  property string toggleSig: ""

  // Whichever panel refit itself most recently publishes its numbers here so
  // the metrics IPC can report view state alongside collector state.
  property var panelMetrics: ({})

  function tempTracking(loadId) {
    var T = stats.temps || []
    for (var i = 0; i < T.length; i++) {
      var tr = T[i].tracks || []
      for (var j = 0; j < tr.length; j++) if (tr[j] === loadId) return T[i]
    }
    return null
  }

  function displayTemp(c) {
    return fahrenheit ? Math.round(c * 9 / 5 + 32) : Math.round(c)
  }

  function buildSummary() {
    var suffix = fahrenheit ? "°F" : "°C"
    var parts = []
    var L = stats.load || []
    for (var i = 0; i < L.length; i++) {
      var p = L[i].label + " " + L[i].pct + "%"
      var t = tempTracking(L[i].id)
      if (t) p += " " + displayTemp(t.c) + suffix
      parts.push(p)
    }
    var m = stats.mem || {}
    if (m.pct !== undefined) parts.push("Mem " + m.pct + "%")
    return parts.join("   ·   ")
  }

  function pushed(arr, value) {
    var next = (arr || []).slice()
    next.push(value)
    while (next.length > history) next.shift()
    return next
  }

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
      if ((T[j].tracks || []).length > 0) { rows.push({ key: "t:", label: "Temperature" }); break }
    rows.push({ key: "mem", label: "Memory" })
    rows.push({ key: "net", label: "Network" })
    if ((d.caps || []).length > 0) rows.push({ key: "cap:", label: "Disk capacity" })
    var sig = JSON.stringify(rows)
    if (sig !== toggleSig) { toggleSig = sig; toggleRows = rows }
  }

  // ---- placement writes -----------------------------------------------------
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

  // Every key this service will write, with its legal values. The IPC target
  // and the panel toggles both funnel through here, so nothing can land in
  // shell.json that the settings schema would not accept.
  readonly property var settable: ({
    placeCpu:   ["Bar + panel", "Panel only", "Hidden"],
    placeIgpu:  ["Bar + panel", "Panel only", "Hidden"],
    placeDgpu:  ["Bar + panel", "Panel only", "Hidden"],
    placeTemps: ["Bar + panel", "Panel only", "Hidden"],
    placeMem:   ["Bar + panel", "Panel only", "Hidden"],
    placeNet:   ["Bar + panel", "Panel only", "Hidden"],
    placeDisk:  ["Bar + panel", "Panel only", "Hidden"],
    placeTop:   ["Panel only", "Hidden"],
    tempUnit:   ["Celsius", "Fahrenheit"],
    tempStyle:  ["Dial", "Degrees"],
    // A boolean rather than a two-value enum because the settings panel
    // renders `type: boolean` as a switch, which is what this is. The list is
    // still the allow-list: `indexOf` works the same on booleans.
    barIcons:   [true, false]
  })

  function setPlacementValue(key, value) {
    var sk = placementSettingKey(key)
    if (sk) writeSetting(sk, value)
  }

  function writeSetting(sk, value) {
    var allowed = settable[sk]
    if (!allowed) return
    // The IPC speaks strings — `set barIcons false` arrives as "false" — but a
    // boolean setting has to land in shell.json as a real boolean or the
    // settings panel's switch reads it back as truthy and shows the wrong
    // state. Coerce here, once, where both callers pass through.
    if (typeof allowed[0] === "boolean" && typeof value === "string") {
      var v = value.toLowerCase()
      if (v === "true" || v === "on" || v === "yes") value = true
      else if (v === "false" || v === "off" || v === "no") value = false
    }
    if (allowed.indexOf(value) === -1) return
    if (!shell) return
    var id = pluginId

    // Omarchy 4.0.3 gates mutateShellConfig behind bar-replacement
    // capabilities, which a bar widget does not have: the call is still on the
    // plugin facade but returns false and writes nothing. updateEntryInline is
    // the sanctioned path for a plugin to write its own entry — it replaces the
    // entry wholesale, so carry every other setting across.
    if (typeof shell.updateEntryInline === "function") {
      var next = {}
      for (var k in entrySettings) if (k !== "id") next[k] = entrySettings[k]
      next[sk] = value
      if (shell.updateEntryInline(id, next)) {
        // Hold the new value now rather than waiting for the bar to patch it
        // back, so a second toggle cannot merge over a stale base.
        entrySettings = next
        return
      }
    }

    // Hosts older than 4.0.3 handed the widget the real ShellRoot.
    if (typeof shell.mutateShellConfig !== "function") return
    shell.mutateShellConfig(function(config) {
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

  // Scriptable placement, and the cheapest proof this version is actually
  // mounted: `omarchy-shell com.cuthriell.binnacle.bar hide cpu`. Lives on the
  // service so exactly one handler claims the target however many monitors
  // build a widget.
  IpcHandler {
    target: "com.cuthriell.binnacle.bar"

    function show(key: string): void { root.setBarVisible(key, true) }
    function hide(key: string): void { root.setBarVisible(key, false) }
    function place(key: string, value: string): void { root.setPlacementValue(key, value) }
    // Any schema setting by its own key: `set tempUnit Fahrenheit`,
    // `set tempStyle Degrees`. Validated against `settable`, so a typo is a
    // no-op rather than a bad write.
    function set(key: string, value: string): void { root.writeSetting(key, value) }

    // Collector state plus the most recent panel refit numbers — how the
    // height budget was debugged, and how to re-check it on a new screen.
    function metrics(): string {
      var m = {
        interval: root.interval,
        history: root.history,
        leaderWindow: root.leaderWindow,
        collectorRunning: statsProc.running,
        loads: (root.stats.load || []).length,
        temps: (root.stats.temps || []).length
      }
      var p = root.panelMetrics || {}
      for (var k in p) m[k] = p[k]
      return JSON.stringify(m)
    }
  }

  // ---- collector ------------------------------------------------------------
  // Resolved relative to this file rather than found on PATH: the helper ships
  // inside the plugin, so `omarchy plugin add` installs a working widget, and
  // nothing on the shell's PATH can shadow it.
  readonly property string helperPath:
    String(Qt.resolvedUrl("binnacle-collect")).replace("file://", "")

  // One long-lived collector, not a process per sample. A re-exec'd one-shot
  // measured ~15ms a tick against ~7ms here, because a cold process pays
  // execve, bash init and first-touch page faults every time.
  Process {
    id: statsProc
    running: true
    command: [root.helperPath, "--stream", String(root.interval), String(root.leaderWindow)]
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

  function restartCollector() {
    if (statsProc.running) {
      statsProc.running = false
      restartTimer.start()
    }
  }
}
