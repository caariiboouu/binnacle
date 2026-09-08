import QtQuick
import qs.Commons
import qs.Ui

// A labeled switch row for the settings page. This is the shared kit's
// `Toggle` plus two things it cannot carry, both of which every switch in this
// plugin needs:
//
// **A state glyph.** A ToggleSwitch says on/off with track colour and knob
// position. Colour is the loud half of that pair and roughly one man in twelve
// cannot read it, which leaves a 5px knob offset carrying the whole meaning.
// The glyph is a redundant second channel — shape, not hue — so the row states
// its value without the reader seeing the track at all. It sits *beside* the
// track rather than inside the knob because the knob is 13px at this row's
// track height, and a check mark drawn into 13px is a smudge.
//
// **Optimistic state.** Every switch here writes to shell.json and waits for
// the shell to patch `settings` back onto the widget. That round trip is quick
// but not instant, and some of these writes resize nothing — a Celsius →
// Fahrenheit flip in dial mode changes no geometry — so they trigger no layout
// pass to flush the binding, and the knob would sit still until something
// unrelated poked it. `pending` throws the knob on click and stands down when
// the persisted value catches up, which is also what makes a write that was
// rejected (a bad value, an unwritable shell.json) visibly snap back.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""

  // The persisted value. The row never writes it: bind it to the setting and
  // act on `requested`.
  property bool actual: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Overridable so a row whose meaning is not "enabled" can say something
  // truer — eye / eye-off for a visibility switch, say.
  property string onIcon: "󰄬"
  property string offIcon: "󰅖"

  // Emitted with the value the user asked for, not the one in effect.
  signal requested(bool next)

  // -1 follows `actual`; 0/1 is a click waiting for the write to land.
  property int pending: -1
  readonly property bool checked: pending === -1 ? actual : (pending === 1)
  onActualChanged: if (pending !== -1 && actual === (pending === 1)) pending = -1

  function activate() {
    pending = checked ? 0 : 1
    root.requested(pending === 1)
  }

  activeFocusOnTab: true
  Keys.onReturnPressed: root.activate()
  Keys.onEnterPressed: root.activate()
  Keys.onSpacePressed: root.activate()

  implicitHeight: Math.max(Style.space(48), content.implicitHeight + Style.spacing.xxl)
  radius: Style.cornerRadius

  readonly property bool _hot: mouse.containsMouse
  color: Style.controlFill(activeFocus, _hot, foreground, accent)
  borderSpec: Border.controlSpec(activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), foreground, accent)

  Behavior on color { ColorAnimation { duration: 100 } }

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.borderLeft + Style.spacing.rowPaddingX
    anchors.rightMargin: root.borderRight + Style.spacing.rowPaddingX
    spacing: Style.spacing.controlGap

    Column {
      width: parent.width - stateIcon.width - track.width - parent.spacing * 2
      spacing: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        text: root.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        elide: Text.ElideRight
        width: parent.width
      }

      // The description is what the setting currently *means* ("Panel only"),
      // not a restatement of the label, so it is the one line that tells a
      // three-state placement apart from a two-state switch.
      Text {
        textFormat: Text.PlainText
        visible: root.description !== ""
        text: root.description
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }

    // Dimmed when off rather than hidden: a glyph that disappears reads as a
    // rendering fault, and the off state is a value the row is asserting, not
    // an absence.
    Text {
      id: stateIcon
      textFormat: Text.PlainText
      text: root.checked ? root.onIcon : root.offIcon
      color: root.foreground
      opacity: root.checked ? 0.95 : 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      anchors.verticalCenter: parent.verticalCenter
      renderType: Text.NativeRendering

      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    // The row owns the click, so the switch is presentation only — same
    // arrangement the shared `Toggle` uses.
    ToggleSwitch {
      id: track
      checked: root.checked
      foreground: root.foreground
      accent: root.accent
      interactive: false
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activate()
  }
}
