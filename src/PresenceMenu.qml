import QtQuick
import qs.Commons
import "Model.js" as Model

// Setting your own presence, as Teams' own status menu does it: pick one and
// it holds until it is handed back. The window drops it from the header chip
// and the bar's popover shows it inline, but it is the same list, the same
// numbers and the same one place that knows row 0 means Automatic.
//
// This takes the Service rather than a handful of values, unlike
// ConversationList next door, because it does not only draw the presence -
// it sets it, and then reports that write's progress and its error. Splitting
// the acting from the drawing would put the same five properties in both
// hosts and gain nothing.
Column {
  id: root

  property var service: null
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  // The footer line. The hosts differ on what Escape does from here - the
  // window closes the picker over a conversation, the popover backs out to the
  // list behind it - so what it promises is the host's to write. Empty leaves
  // the line out entirely; "Setting…" still overrides it while a write is in
  // flight, because that is about the picker rather than about the host.
  property string hint: "A number picks one.  Esc closes this"

  // Automatic leads, because handing presence back to Teams is the state
  // everything else is a departure from - and it is the row somebody who set
  // Do not disturb this morning is looking for.
  readonly property var rows: [{
    state: "auto", label: "Automatic", dot: "", availability: "",
    hint: "however Teams sees you"
  }].concat(service ? service.presenceChoices : [])

  // Told, so a host can shut its own overlay on the way out.
  signal chose(string state)

  // The nth row, by number, for the same reason the reactions are numbered:
  // six states arrowed through is slower than six states typed. Out of range
  // does nothing rather than guessing, because the digits arrive from a key
  // handler that cannot know how many rows there are.
  function pickAt(index) {
    if (!service || index < 0 || index >= rows.length) return
    var state = String(rows[index].state || "")
    root.chose(state)
    service.setPresence(state)
  }

  spacing: Style.spacing.xs

  Text {
    width: parent.width
    text: "Your presence"
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.presenceError !== ""
    text: root.service ? root.service.presenceError : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.rows

    delegate: Rectangle {
      id: line
      required property var modelData
      required property int index

      // Whichever row is what Graph reports right now. Compared on the
      // availability rather than the dot, so Busy and Do not disturb - one
      // colour, two states - are not both ticked. It says what is true now,
      // not what was chosen: Graph will read back a preferred presence but
      // not tell anyone it is one.
      readonly property bool current: !!root.service && root.service.myPresence
        && String(modelData.availability || "") !== ""
        && String(root.service.myPresence.availability || "") === String(modelData.availability)

      width: parent ? parent.width : 0
      implicitHeight: rowText.implicitHeight + Style.spacing.sm * 2
      radius: Style.space(5)
      color: hover.containsMouse
        ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1)
        : "transparent"

      Text {
        id: numberText
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        text: String(line.index)
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignRight
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PresenceDot {
        id: dot
        anchors.left: numberText.right
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        state: String(line.modelData.dot || "")
        palette: root.service ? root.service.themeColors : ({})
      }

      Text {
        id: rowText
        anchors.left: numberText.right
        anchors.leftMargin: Style.spacing.sm + dot.width + Style.spacing.sm
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        text: String(line.modelData.label || "")
              + (line.modelData.hint ? "  ·  " + line.modelData.hint : "")
              + (line.current ? "  ·  now" : "")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: line.current ? Color.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: !!root.service && !root.service.settingPresence
        onClicked: root.pickAt(line.index)
      }
    }
  }

  Text {
    width: parent.width
    visible: root.hint !== "" || (!!root.service && root.service.settingPresence)
    text: root.service && root.service.settingPresence ? "Setting…" : root.hint
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.8)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
