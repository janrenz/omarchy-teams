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

  // Properties, not a pad() call inside each binding. A binding that reaches
  // its dependency through a function call does not reliably re-run when that
  // dependency changes - which is exactly what happened here: the numbers
  // changed and the rows did not move.
  readonly property int rowGap: Math.max(1, Math.round(Style.spacing.sm * density))
  readonly property int rowPadding: Math.max(1, Math.round(Style.spacing.md * density))
  // Not scaled: a wider left margin on every row just narrows the names.
  readonly property int rowIndent: Style.spacing.md

  // The column the unread dot and the team chevron stand in, to the left of
  // every label. The pane holding this list is expected to hand the list this
  // much of its own left padding to stand in, so that the labels - not the
  // markers - line up with the window title. Carved out of the rows instead,
  // it read as an unexplained indent in front of every name.
  property int markerGutter: rowIndent + Style.space(10)

  function pad(px) { return Math.max(1, Math.round(px * density)) }

  signal picked(var row)
  // Where the cursored row sits, so the pane holding this list can keep it on
  // screen. The list cannot scroll itself: it does not know it is in one.
  signal cursorMoved(real itemY, real itemHeight)

  spacing: rowGap

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
      // The row's own padding, top and bottom, is what "spacing" is judged by.
      // It comes off md rather than sm because a multiplier over 4px cannot
      // produce a difference anybody can see.
      implicitHeight: body.implicitHeight + root.rowPadding * 2
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
        // Stops where the timestamp starts. Without this the title is free to
        // be as wide as it likes, elide does nothing, and a long name runs
        // straight under the time - which it did, at compact spacing.
        anchors.right: stamp.visible ? stamp.left : parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: root.markerGutter
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
        id: stamp
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.md
        anchors.top: parent.top
        anchors.topMargin: root.rowPadding
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
