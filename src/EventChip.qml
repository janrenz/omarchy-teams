import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One meeting, as the block a calendar draws it as.
//
// The same component in all three views, which is why it takes its height
// from whoever placed it rather than from its own content: in a day column
// that height is how long the meeting is, and a fifteen-minute call has to
// fit its name into a sliver. In the month grid and the agenda the content
// decides instead, and `implicitHeight` is what the parent binds to.
//
// What the colour means is availability, not the app's palette: what a
// meeting does to your day is the thing a calendar is read for. An
// invitation nobody has answered is drawn as an outline, because that is the
// one state with something still to do about it.
Rectangle {
  id: root

  required property var event
  property var palette: ({})
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  // Cramped rows: the month grid puts five of these in a cell.
  property bool dense: false
  property bool cursored: false
  property bool selected: false
  // Whether it is happening right now, which is worth more than any of the
  // other states and is the only one that gets the accent.
  property bool live: false

  signal picked()
  signal joinRequested()

  readonly property string tintName: Model.eventTint(root.event, root.palette)
  readonly property color tint: tintName !== "" ? tintName : root.accent
  readonly property bool unanswered: String(root.event.response || "") === "pending"
  readonly property bool ignored: root.event.cancelled === true
                                  || String(root.event.response || "") === "declined"
  // How much room there is to say anything. Two lines' worth is the point
  // where the time can go under the subject instead of in front of it.
  readonly property bool roomForTwo: root.height >= Style.font.caption * 2 + Style.spacing.md

  radius: Style.space(4)
  clip: true
  implicitHeight: (root.dense ? denseRow.implicitHeight : block.implicitHeight)
                  + Style.spacing.xs * 2
  color: root.unanswered || root.ignored
    ? "transparent"
    : Util.alpha(root.tint, root.selected ? 0.34 : (pointer.containsMouse ? 0.26 : 0.18))
  border.width: (root.unanswered || root.selected || root.cursored) ? Style.space(1) : 0
  border.color: root.cursored ? root.fg : Util.alpha(root.tint, root.ignored ? 0.5 : 0.9)
  opacity: root.ignored ? 0.6 : 1.0

  // Declared before everything it sits under, because declaration order is
  // stacking order: the Join button below has to be able to take its own
  // clicks, or joining would open the meeting instead.
  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.picked()
  }

  // The stripe down the side, which is what makes a column of these readable
  // as a column rather than as a stack of grey boxes.
  Rectangle {
    id: stripe
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(2)
    width: Style.space(2)
    radius: width / 2
    visible: !root.dense
    color: root.live ? root.accent : root.tint
  }

  // The cramped shape: one line, for a month cell.
  Row {
    id: denseRow
    visible: root.dense
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.xs
    anchors.rightMargin: Style.spacing.xs
    spacing: Style.spacing.xs

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(5)
      height: Style.space(5)
      radius: width / 2
      color: root.live ? root.accent : root.tint
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      text: root.event.allDay === true ? "" : Model.clockLabel(root.event.when)
      textFormat: Text.PlainText
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, denseRow.width - x)
      text: String(root.event.subject || "")
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.strikeout: root.event.cancelled === true
    }
  }

  // The roomy shape: a block in a day column, or a row in the agenda.
  Column {
    id: block
    visible: !root.dense
    anchors.left: stripe.right
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: Style.spacing.xs
    anchors.rightMargin: Style.spacing.xs
    anchors.topMargin: Style.spacing.xs
    spacing: 0

    Row {
      width: parent.width
      spacing: Style.spacing.xs

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.roomForTwo && text !== ""
        text: root.event.allDay === true ? "" : Model.clockLabel(root.event.when)
        textFormat: Text.PlainText
        color: Qt.darker(root.fg, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // The marks a calendar puts on a row: it repeats, it is online, nobody
      // has answered it. Glyphs rather than words, because the widest thing
      // in a day column is a fifteen-minute meeting's name.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
        text: (root.event.recurring === true ? "\u{F0456} " : "")   // nf-md-repeat
              + (root.event.online === true ? "\u{F0567} " : "")     // nf-md-video
              + (root.event.private === true ? "\u{F033E} " : "")    // nf-md-lock
        textFormat: Text.PlainText
        color: Qt.darker(root.fg, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - x)
        text: String(root.event.subject || "")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.strikeout: root.event.cancelled === true
      }
    }

    Text {
      width: parent.width
      visible: root.roomForTwo && text !== ""
      text: [Model.eventTimeLabel(root.event), String(root.event.where || "")]
            .filter(function(part) { return part !== "" }).join("  ·  ")
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // Only where there is room for a third line, which in practice means a
    // meeting of an hour or more - and those are the ones whose organiser is
    // worth knowing before opening it.
    Text {
      width: parent.width
      visible: !root.dense && root.height >= Style.font.caption * 4 && text !== ""
      text: String((root.event.organizer || {}).name || "")
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Qt.darker(root.fg, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Join without opening the meeting first, which is what somebody four
  // minutes late wants. Only on a block with room for it, and only while it
  // is being pointed at.
  Rectangle {
    id: joinButton
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.spacing.xs
    visible: !root.dense && String(root.event.joinUrl || "") !== ""
             && (pointer.containsMouse || root.cursored)
             && root.height >= joinText.implicitHeight + Style.spacing.md
    width: joinText.implicitWidth + Style.spacing.md
    height: joinText.implicitHeight + Style.spacing.xs
    radius: Style.space(3)
    color: joinPointer.containsMouse ? root.accent : Util.alpha(root.accent, 0.85)

    Text {
      id: joinText
      anchors.centerIn: parent
      text: "Join"
      textFormat: Text.PlainText
      color: Color.background
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      id: joinPointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.joinRequested()
    }
  }

}
