import QtQuick
import qs.Commons
import "Model.js" as Model

// Where you are working from, and the handle the location picker drops from.
// The presence chip's neighbour in both headers, and one component rather
// than two that drift.
//
// No circle beside it, deliberately. A presence has four states and a colour
// is the fastest way to read one; a location has three and no colour anybody
// would agree on, and a second coloured dot next to the presence dot would
// only invite the question of which one meant what.
//
// A backing Item rather than a bare Row, for the reason its neighbour is one:
// the click target is the whole chip, and a MouseArea cannot be anchored
// inside a Row without Qt refusing the anchors.
Item {
  id: root

  // service.myLocation, or null when no layer has anything to say about today
  // - which is the ordinary case, not a failure.
  property var location: null
  // service.locationChoices, so the word comes from the helper's own table
  // rather than a second copy of it over here.
  property var choices: []
  property bool busy: false
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal clicked()

  implicitWidth: chipRow.implicitWidth
  implicitHeight: chipRow.implicitHeight

  Row {
    id: chipRow
    spacing: Style.spacing.xs

    Text {
      anchors.verticalCenter: parent.verticalCenter
      // "work location" while there is none to name, so the chip is still
      // something to click: an affordance that disappears when nobody has
      // used it is an affordance nobody finds.
      text: root.busy
        ? "setting…"
        : Model.choiceLabel(root.choices,
                            root.location ? root.location.state : "",
                            "work location").toLowerCase()
      textFormat: Text.PlainText
      color: Qt.darker(root.fg, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
