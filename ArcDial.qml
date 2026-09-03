import QtQuick
import qs.Commons

// A small circular arc gauge, for the one metric in the cluster that is neither
// a rate nor a capacity: temperature.
//
// Named ArcDial, not Dial: QtQuick.Controls ships a Dial control, and an
// explicitly imported module outranks an implicit same-directory type, so a
// file called Dial.qml here is silently shadowed wherever Controls is imported.
//
// The 270° sweep with a gap at the bottom is the standard dial idiom, and it is
// what makes this readable at 18px where a ring would not be — the gap tells
// you instantly where "empty" is, so a quarter-full arc cannot be mistaken for
// a three-quarter-full one rotated.
Canvas {
  id: root

  property real value: 0        // 0..1 along the sweep
  property color stroke: "black"
  property real trackAlpha: 0.32
  property real thickness: 3

  // Canvas angles start at 3 o'clock and increase clockwise. 135° puts the
  // start at bottom-left; +270° ends at bottom-right.
  property real startAngle: 135
  property real sweepAngle: 270

  // Optional threshold pip, as a 0..1 position along the sweep. Marks the
  // point past which the reading matters — throttling, in the thermal case.
  property real marker: -1
  property real markerAlpha: 0.55

  // Centre readout. Empty in the bar, where there is no room for it; the
  // panel's larger dial uses it to put the number inside the arc.
  property string centerText: ""
  property string fontFamily: Style.font.family
  property real centerFontSize: Style.font.body

  onValueChanged: requestPaint()
  onCenterTextChanged: requestPaint()
  onMarkerChanged: requestPaint()
  onStrokeChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.clearRect(0, 0, width, height)

    var cx = width / 2
    var cy = height / 2
    var radius = Math.min(width, height) / 2 - thickness / 2
    if (radius <= 0) return

    var a0 = startAngle * Math.PI / 180
    var span = sweepAngle * Math.PI / 180

    ctx.lineCap = "round"

    // Track: the whole sweep, so the dial reads as a dial even at 0.
    ctx.beginPath()
    ctx.arc(cx, cy, radius, a0, a0 + span, false)
    ctx.strokeStyle = Util.alpha(stroke, trackAlpha)
    ctx.lineWidth = thickness
    ctx.stroke()

    var frac = Util.clamp(value, 0, 1)
    if (frac > 0) {
      ctx.beginPath()
      ctx.arc(cx, cy, radius, a0, a0 + span * frac, false)
      ctx.strokeStyle = root.stroke
      ctx.lineWidth = thickness
      ctx.stroke()
    }

    // Threshold pip, drawn across the track thickness.
    if (marker >= 0 && marker <= 1) {
      var ma = a0 + span * marker
      var inner = radius - thickness / 2
      var outer = radius + thickness / 2
      ctx.beginPath()
      ctx.moveTo(cx + Math.cos(ma) * inner, cy + Math.sin(ma) * inner)
      ctx.lineTo(cx + Math.cos(ma) * outer, cy + Math.sin(ma) * outer)
      ctx.strokeStyle = Util.alpha(stroke, markerAlpha)
      ctx.lineWidth = 1
      ctx.lineCap = "butt"
      ctx.stroke()
    }

    if (centerText !== "") {
      ctx.fillStyle = root.stroke
      ctx.font = Math.round(centerFontSize) + "px \"" + fontFamily + "\""
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      ctx.fillText(centerText, cx, cy)
    }
  }
}
