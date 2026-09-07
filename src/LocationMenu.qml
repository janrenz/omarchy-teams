import QtQuick
import qs.Commons
import "Model.js" as Model

// Where you are working from, as Teams' own location control does it: pick
// one and it holds until it is handed back. Both surfaces show this one - the
// window's header and the bar's popover - and it is the one place that knows
// row 0 means Automatic.
//
// A picker of its own rather than four more rows in PresenceMenu, for the
// reason Graph and Teams both treat them as two things: a presence says
// whether you can be interrupted and a location says where you are, they are
// written by two different calls, and one list of ten rows would have run out
// of single digits to number them with.
//
// Takes the Service rather than a handful of values, for the same reason its
// neighbour does: it does not only draw the location, it sets it, and then
// reports that write's progress and its error.
Column {
  id: root

  property var service: null
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  // The footer line, written by the host: the window closes the picker over a
  // conversation and the popover backs out to the list behind it, so what
  // Escape promises is the host's to say. Empty leaves the line out; "Setting…"
  // still overrides it while a write is in flight, because that is about the
  // picker rather than about the host.
  property string hint: "A number picks one.  Esc closes this"

  // Automatic leads, the same as the presence picker: handing the location
  // back is the state the other three are a departure from, and it is the row
  // somebody who said "remote" on Monday is looking for on Wednesday.
  readonly property var rows: [{
    state: "auto", label: "Automatic", hint: "whatever your working hours say"
  }].concat(service ? service.locationChoices : [])

  // Told, so a host can shut its own overlay on the way out.
  signal chose(string state)

  function pickAt(index) {
    if (!service || index < 0 || index >= rows.length) return
    var state = String(rows[index].state || "")
    root.chose(state)
    service.setLocation(state)
  }

  spacing: Style.spacing.xs

  Text {
    width: parent.width
    text: "Your work location"
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.locationError !== ""
    text: root.service ? root.service.locationError : ""
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

      readonly property var now: root.service ? root.service.myLocation : null

      // Which row is true right now. Unlike the presence picker, Automatic is
      // a row that can be ticked here: Graph aggregates three layers and says
      // in `source` which of them won, so "nothing has been said about today"
      // is a state it will actually report rather than one we would have to
      // infer from the absence of a memory.
      readonly property bool current: String(modelData.state || "") === "auto"
        ? (!!root.service && root.service.signedIn && !now)
        : (!!now && String(now.state || "") === String(modelData.state || ""))

      // And where the winning layer came from, for the row that won it. A
      // location the calendar expects and a location somebody chose read the
      // same on screen otherwise, and only one of them is a decision.
      readonly property string via: {
        if (!line.current || !now) return ""
        var source = String(now.source || "")
        if (source === "scheduled") return "from your working hours"
        if (source === "automatic") return "noticed by a Teams client"
        return ""
      }

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

      Text {
        id: rowText
        anchors.left: numberText.right
        anchors.leftMargin: Style.spacing.sm
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        text: String(line.modelData.label || "")
              + (line.modelData.hint ? "  ·  " + line.modelData.hint : "")
              + (line.current ? "  ·  now" : "")
              + (line.via !== "" ? ", " + line.via : "")
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
        enabled: !!root.service && !root.service.settingLocation
        onClicked: root.pickAt(line.index)
      }
    }
  }

  Text {
    width: parent.width
    visible: root.hint !== "" || (!!root.service && root.service.settingLocation)
    text: root.service && root.service.settingLocation ? "Setting…" : root.hint
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.8)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
