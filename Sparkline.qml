import QtQuick
import qs.Commons

// One compact history graph for the bar. Values arrive pre-normalised to 0..1,
// oldest first, so this file holds no opinion about units or scaling.
//
// The frame is the point of reference: the box top is 1.0 and the box bottom
// is 0.0, so a flat line low in the box reads as genuinely idle rather than as
// a graph that might be scaled to anything. What 1.0 *means* is the caller's
// business — a fixed 100% for the percentage metrics, a rolling peak for the
// rate ones — and the tooltip spells that out.
//
// Setting `below` turns it into a mirrored pair: `values` fills upward from a
// centre rule and `below` fills downward. That is how network draws download
// against upload in a single slot.
Canvas {
  id: root

  property var values: []
  property var below: null
  property color stroke: "black"
  property real fillAlpha: 0.35
  property real strokeWidth: 1.2
  property bool frame: true
  property real frameAlpha: 0.32

  readonly property bool mirrored: below !== null && below !== undefined

  // Plot inset. One pixel of clearance inside the frame keeps a full-scale
  // peak from painting directly on top of the border line.
  readonly property real pad: frame ? 1 : 0

  onValuesChanged: requestPaint()
  onBelowChanged: requestPaint()
  onStrokeChanged: requestPaint()
  onFrameChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  // Draws one series as an outlined area. `sign` is +1 to grow up from the
  // baseline, -1 to grow down.
  function series(ctx, data, baseline, span, sign) {
    if (!data || data.length < 2 || span <= 0) return

    var n = data.length
    var left = pad
    var stepX = (width - pad * 2) / (n - 1)

    ctx.beginPath()
    ctx.moveTo(left, baseline - sign * (data[0] || 0) * span)
    for (var i = 1; i < n; i++)
      ctx.lineTo(left + i * stepX, baseline - sign * (data[i] || 0) * span)

    // Stroke the open path first, then close it down to the baseline and fill.
    // One path for both means the fill can never drift out of step with the
    // line the way two separately-built paths eventually do.
    ctx.strokeStyle = root.stroke
    ctx.lineWidth = root.strokeWidth
    ctx.lineJoin = "round"
    ctx.lineCap = "round"
    ctx.stroke()

    ctx.lineTo(left + (n - 1) * stepX, baseline)
    ctx.lineTo(left, baseline)
    ctx.closePath()
    ctx.fillStyle = Qt.rgba(root.stroke.r, root.stroke.g, root.stroke.b, root.fillAlpha)
    ctx.fill()
  }

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

    var inset = strokeWidth / 2

    if (mirrored) {
      var mid = height / 2
      var span = mid - pad - inset

      // The rule is drawn under both series so a busy graph does not look
      // like it has a line through it.
      ctx.beginPath()
      ctx.moveTo(pad, mid)
      ctx.lineTo(width - pad, mid)
      ctx.strokeStyle = Util.alpha(stroke, frameAlpha)
      ctx.lineWidth = 1
      ctx.stroke()

      series(ctx, values, mid, span, 1)
      series(ctx, below, mid, span, -1)
    } else {
      series(ctx, values, height - pad - inset, height - pad * 2 - strokeWidth, 1)
    }
  }
}
