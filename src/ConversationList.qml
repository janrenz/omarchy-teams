import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The sidebar: chats, then each team's channels under its name. Rows arrive
// from Model.conversationRows already flattened and in order, so this only
// draws them and says which was picked.
Column {
  id: root

  property var rows: []
  property string selectedKey: ""
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int cursorIndex: -1

  signal picked(var row)

  spacing: Style.spacing.xxs

  readonly property var selectable: Model.selectableRows(rows)

  function moveCursor(step) {
    if (selectable.length === 0) return
    var next = cursorIndex < 0 ? (step > 0 ? 0 : selectable.length - 1) : cursorIndex + step
    cursorIndex = Math.max(0, Math.min(selectable.length - 1, next))
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= selectable.length) return
    root.picked(rows[selectable[cursorIndex]])
  }

  Repeater {
    model: root.rows

    delegate: Rectangle {
      id: line
      required property var modelData
      required property int index

      readonly property bool isHeading: modelData.kind === "heading"
      readonly property bool selected: !isHeading && root.selectedKey === String(modelData.key)
      readonly property int pickIndex: root.selectable.indexOf(index)
      readonly property bool cursored: !isHeading && root.cursorIndex >= 0
                                       && root.cursorIndex === pickIndex

      width: parent ? parent.width : 0
      implicitHeight: body.implicitHeight + Style.spacing.sm * 2
      radius: Style.space(5)
      color: {
        if (isHeading) return "transparent"
        if (selected) return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
        if (hover.containsMouse || cursored) return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        return "transparent"
      }
      Behavior on color { ColorAnimation { duration: 120 } }

      // Unread is a dot rather than a count: Graph will say whether a chat has
      // been read since its last message, but not how many are waiting, and a
      // made-up number is worse than an honest mark.
      Rectangle {
        id: dot
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(6)
        height: width
        radius: width
        visible: line.modelData.unread === true
        color: root.accent
      }

      Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.md + Style.space(8)
                            + Style.space(10) * line.modelData.depth
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: String(line.modelData.title || "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: line.isHeading ? root.dim : root.fg
          font.family: root.fontFamily
          font.pixelSize: line.isHeading ? Style.font.caption : Style.font.body
          font.bold: line.isHeading || line.modelData.unread === true || line.selected
          font.capitalization: line.isHeading ? Font.AllUppercase : Font.MixedCase
        }

        Text {
          width: parent.width
          visible: !line.isHeading && String(line.modelData.subtitle || "") !== ""
          text: String(line.modelData.subtitle || "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          maximumLineCount: 1
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.md
        anchors.top: parent.top
        anchors.topMargin: Style.spacing.sm
        visible: !line.isHeading && String(line.modelData.when || "") !== ""
        text: Model.whenLabel(line.modelData.when, new Date())
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: !line.isHeading
        enabled: !line.isHeading
        cursorShape: line.isHeading ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: {
          root.cursorIndex = line.pickIndex
          root.picked(line.modelData)
        }
      }
    }
  }
}
