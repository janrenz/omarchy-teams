import QtQuick
import qs.Commons
import "Model.js" as Model

// How you look to other people, and the handle the picker drops from. Both
// surfaces carry one - the window's header and the bar's popover - so it is
// one component rather than two that drift.
//
// Only where it can be acted on: a dot saying how you look to other people,
// on a sign-in that cannot change it, is a fact with nothing to do about it.
// So both hosts gate this on canSetPresence rather than the chip pretending
// to be a button.
//
// A backing Item rather than a bare Row: the click target is the circle and
// the word together, and a MouseArea cannot be anchored inside a Row without
// Qt refusing the anchors.
Item {
  id: root

  // service.myPresence, or null before the first fetch has answered.
  property var presence: null
  property var palette: ({})
  property bool busy: false
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal clicked()

  implicitWidth: chipRow.implicitWidth
  implicitHeight: chipRow.implicitHeight

  Row {
    id: chipRow
    spacing: Style.spacing.xs

    PresenceDot {
      anchors.verticalCenter: parent.verticalCenter
      state: root.presence ? String(root.presence.state || "") : ""
      palette: root.palette
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      // "presence" rather than a state until a fetch has answered, for the
      // same reason the circle draws nothing: naming a state we have not
      // been told is worse than naming none.
      text: root.busy
        ? "setting…"
        : (root.presence
           ? Model.presenceLabel(root.presence.state, root.presence.activity).toLowerCase()
           : "presence")
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
