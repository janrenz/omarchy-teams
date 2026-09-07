import QtQuick
import qs.Commons

// One line on the settings index: where you can go, and what is set there.
//
// The detail line is the point of it. An index of bare titles costs a click to
// answer "is the calendar on?", which is the question somebody opening settings
// usually has - so each row summarises its own page and most visits end without
// opening one.
Rectangle {
  id: root

  property string title: ""
  property string detail: ""
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property string fontFamily: Style.font.family

  signal clicked()

  implicitHeight: text.implicitHeight + Style.spacing.md * 2
  radius: Style.cornerRadius
  color: hover.containsMouse
    ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
    : "transparent"
  border.width: Style.space(1)
  border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

  Column {
    id: text
    anchors.left: parent.left
    anchors.right: chevron.left
    anchors.leftMargin: Style.spacing.md
    anchors.rightMargin: Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xxs

    Text {
      width: parent.width
      text: root.title
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: parent.width
      visible: root.detail !== ""
      text: root.detail
      textFormat: Text.PlainText
      // Wrapped rather than elided. The point of the line is that it answers
      // the question without opening the page, and "with channels · n…"
      // answers nothing - a second line costs less than a click.
      wrapMode: Text.WordWrap
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Text {
    id: chevron
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.md
    anchors.verticalCenter: parent.verticalCenter
    text: "\u{F0142}"   // nf-md-chevron-right
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
