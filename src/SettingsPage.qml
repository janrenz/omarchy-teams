import QtQuick
import qs.Commons

// One page of the settings, with the way back at the top of it.
//
// A shell rather than six copies of the same header Row: the back affordance
// and the title are the only thing every page shares, and a page that wrote
// its own would be a page that drifts from its neighbours.
//
// Everything declared inside lands in the body, through the default property -
// so a page reads as its own controls with a title on it, which is what makes
// the form worth splitting up in the first place.
Item {
  id: root

  property string title: ""
  // Whether this is the page on screen. Named `open` rather than bound
  // straight to `visible` so the host says which page it wants and this
  // decides what that means for layout.
  property bool open: false
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property string fontFamily: Style.font.family
  property real spacing: Style.spacing.lg

  default property alias body: bodyColumn.data

  signal back()

  // Excluded from the enclosing Column entirely when it is not the page being
  // shown - a Column skips an invisible child, so the form is as tall as
  // whichever page is open and no taller.
  visible: root.open
  implicitHeight: root.open ? column.implicitHeight : 0

  Column {
    id: column
    width: parent.width
    spacing: root.spacing

    // The title doubles as the way back, all of it clickable: a chevron on its
    // own is a small target, and the words beside it are the thing being
    // pointed at.
    Rectangle {
      width: parent.width
      implicitHeight: heading.implicitHeight + Style.spacing.sm * 2
      radius: Style.cornerRadius
      color: back.containsMouse
        ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
        : "transparent"

      Row {
        id: heading
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "\u{F0141}"   // nf-md-chevron-left
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.title
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
      }

      MouseArea {
        id: back
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.back()
      }
    }

    Column {
      id: bodyColumn
      width: parent.width
      spacing: root.spacing
    }
  }
}
