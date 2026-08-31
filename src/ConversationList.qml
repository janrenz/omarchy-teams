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
  // How generously to space the rows. 1.0 is the theme's own spacing.
  property real density: 1.0

  function pad(px) { return Math.max(1, Math.round(px * density)) }

  signal picked(var row)
  // Where the cursored row sits, so the pane holding this list can keep it on
  // screen. The list cannot scroll itself: it does not know it is in one.
  signal cursorMoved(real itemY, real itemHeight)

  spacing: pad(Style.spacing.xxs)

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
      readonly property bool isTeam: modelData.kind === "team"
      readonly property bool isNote: modelData.kind === "note"
      // Headings label; notes explain. Neither is something to click.
      readonly property bool inert: isHeading || isNote
      readonly property bool selected: !isHeading && root.selectedKey === String(modelData.key)
      readonly property int pickIndex: root.selectable.indexOf(index)
      readonly property bool cursored: !isHeading && root.cursorIndex >= 0
                                       && root.cursorIndex === pickIndex
      onCursoredChanged: if (cursored) root.cursorMoved(y, height)

      width: parent ? parent.width : 0
      implicitHeight: body.implicitHeight + root.pad(Style.spacing.sm) * 2
      radius: Style.space(5)
      color: {
        if (inert) return "transparent"
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

      // Which way a team is facing, so a closed one does not read as a team
      // with no channels. Spins to point down as it opens.
      Text {
        id: chevron
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        visible: line.isTeam
        text: "\uf0da"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        rotation: line.modelData.expanded === true ? 90 : 0
        Behavior on rotation { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
      }

      // Opening a team is a request; say so where the chevron is rather than
      // leaving the row looking like it did nothing.
      Spinner {
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        visible: line.modelData.loading === true
        color: root.accent
        dotSize: Style.space(3)
      }

      Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: root.pad(Style.spacing.md) + Style.space(10)
                            + Style.space(12) * line.modelData.depth
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: String(line.modelData.title || "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: line.inert ? root.dim : root.fg
          font.family: root.fontFamily
          font.pixelSize: line.isHeading ? Style.font.caption : Style.font.body
          font.bold: line.isHeading || line.modelData.unread === true || line.selected
          font.capitalization: line.isHeading ? Font.AllUppercase : Font.MixedCase
          font.italic: line.isNote
        }

        Text {
          width: parent.width
          visible: !line.inert && String(line.modelData.subtitle || "") !== ""
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
        visible: !line.inert && String(line.modelData.when || "") !== ""
        text: Model.whenLabel(line.modelData.when, new Date())
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: !line.inert
        enabled: !line.inert
        cursorShape: line.inert ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: {
          root.cursorIndex = line.pickIndex
          root.picked(line.modelData)
        }
      }
    }
  }
}
