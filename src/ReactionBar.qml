import QtQuick
import qs.Commons
import qs.Ui

// The reactions on one message, and the way to add your own.
//
// A chip is a toggle, not a label: it says how many people reacted and whether
// you are one of them, and clicking it adds or removes yours. That is why the
// helper counts them per emoji and marks `mine` rather than handing over the
// raw per-person list Graph returns.
Flow {
  id: root

  property var reactions: []
  // The emoji this plugin may send, from teams.py. Anything else is refused by
  // Graph, so the picker offers exactly what will work.
  property var choices: []
  property bool busy: false
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Open only while somebody is choosing, so a transcript is not a wall of
  // identical emoji rows.
  property bool picking: false

  signal toggled(string emoji)

  spacing: Style.spacing.xs
  visible: reactions.length > 0 || picking || hoverGate.containsMouse

  // Keeps the add button visible while the pointer is anywhere near the row,
  // rather than only exactly over it.
  MouseArea {
    id: hoverGate
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    z: -1
  }

  Repeater {
    model: root.reactions

    delegate: Rectangle {
      required property var modelData
      readonly property bool mine: modelData.mine === true

      implicitWidth: chip.implicitWidth + Style.spacing.md
      implicitHeight: chip.implicitHeight + Style.spacing.xs * 2
      radius: height / 2
      color: mine ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                  : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
      border.width: mine ? Style.space(1) : 0
      border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55)

      Row {
        id: chip
        anchors.centerIn: parent
        spacing: Style.spacing.xxs

        Text {
          text: String(modelData.emoji || "")
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: Number(modelData.count || 0) > 1
          text: String(modelData.count || 0)
          textFormat: Text.PlainText
          color: parent.parent.mine ? root.accent : Qt.darker(root.fg, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        enabled: !root.busy
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(String(modelData.emoji))
      }
    }
  }

  // Add one. A plus rather than a face, so it does not read as a seventh
  // reaction sitting among the six.
  Rectangle {
    implicitWidth: plus.implicitWidth + Style.spacing.md
    implicitHeight: plus.implicitHeight + Style.spacing.xs * 2
    radius: height / 2
    visible: !root.picking
    color: addHover.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                                  : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)

    Text {
      id: plus
      anchors.centerIn: parent
      text: "+"
      textFormat: Text.PlainText
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: addHover
      anchors.fill: parent
      hoverEnabled: true
      enabled: !root.busy
      cursorShape: Qt.PointingHandCursor
      onClicked: root.picking = true
    }
  }

  // The choices, inline rather than in a popup: a popup over a scrolling
  // transcript has to be positioned, and this only ever holds six things.
  Repeater {
    model: root.picking ? root.choices : []

    delegate: Rectangle {
      required property var modelData
      implicitWidth: face.implicitWidth + Style.spacing.md
      implicitHeight: face.implicitHeight + Style.spacing.xs * 2
      radius: height / 2
      color: pick.containsMouse ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.2)
                                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)

      Text {
        id: face
        anchors.centerIn: parent
        text: String(modelData.emoji || "")
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: pick
        anchors.fill: parent
        hoverEnabled: true
        enabled: !root.busy
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.picking = false
          root.toggled(String(modelData.emoji))
        }
      }
    }
  }
}
