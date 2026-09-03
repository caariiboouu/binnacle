import QtQuick
import qs.Commons

// A fill meter drawn in the same framed box the sparklines use, so the row
// still reads as one instrument cluster rather than a graph with an odd one
// out. `value` is 0..1 and fills left to right.
//
// This is for quantities where history is pointless — disk capacity moves by
// fractions of a percent an hour, so a sparkline of it is a flat line that
// tells you nothing the fill level doesn't.
Canvas {
  id: root

  property real value: 0
  property color stroke: "black"
  property real fillAlpha: 0.35
  property real strokeWidth: 1.2
  property bool frame: true
  property real frameAlpha: 0.32
  property bool ticks: true

  readonly property real pad: frame ? 1 : 0

  onValueChanged: requestPaint()
  onStrokeChanged: requestPaint()
  onFrameChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.clearRect(0, 0, width, height)

    // Half of a 1px stroke sits outside the path, so a border drawn on the
    // exact edge renders as a soft 2px smear. The half-pixel offset lands it
    // on the pixel grid instead.
    if (frame) {
      ctx.beginPath()
      ctx.rect(0.5, 0.5, width - 1, height - 1)
      ctx.strokeStyle = Util.alpha(stroke, frameAlpha)
      ctx.lineWidth = 1
      ctx.stroke()
    }

    var innerW = width - pad * 2
    var innerH = height - pad * 2
    if (innerW <= 0 || innerH <= 0) return

    var frac = Util.clamp(value, 0, 1)
    var fillW = frac * innerW

    ctx.fillStyle = Util.alpha(stroke, fillAlpha)
    ctx.fillRect(pad, pad, fillW, innerH)

    // Quarter ticks, so 64% is distinguishable from 50% at a glance instead of
    // being "a bit past halfway". Drawn over the fill at low contrast.
    if (ticks) {
      ctx.strokeStyle = Util.alpha(stroke, frameAlpha * 0.8)
      ctx.lineWidth = 1
      for (var q = 1; q <= 3; q++) {
        var x = Math.round(pad + innerW * q / 4) + 0.5
        var len = (q === 2) ? innerH * 0.5 : innerH * 0.28
        ctx.beginPath()
        ctx.moveTo(x, pad)
        ctx.lineTo(x, pad + len)
        ctx.moveTo(x, pad + innerH)
        ctx.lineTo(x, pad + innerH - len)
        ctx.stroke()
      }
    }

    // Solid leading edge, so the exact level stays readable where the soft
    // fill meets the background.
    if (fillW > strokeWidth) {
      var ex = pad + fillW - strokeWidth / 2
      ctx.beginPath()
      ctx.moveTo(ex, pad)
      ctx.lineTo(ex, pad + innerH)
      ctx.strokeStyle = root.stroke
      ctx.lineWidth = root.strokeWidth
      ctx.stroke()
    }
  }
}
