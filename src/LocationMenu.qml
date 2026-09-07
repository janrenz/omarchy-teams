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
  //
  // Then the buildings, if this sign-in may list them. They are `office`
  // rows with a place on them rather than a state of their own - which is
  // what setManualLocation takes - so "In the office" above them is the same
  // choice without a building, and stays for anybody whose tenant lists
  // none. Capped, because a row here is numbered with a digit and four are
  // already spoken for; the settings form lists every one.
  readonly property var rows: {
    // Row 0's hint says what handing it back would actually hand it to. With
    // wifi rules configured that is not only the schedule, and saying so is
    // what tells somebody who picked a row this morning why their wifi looks
    // as though it does nothing: their own choice outranks it until this row.
    var back = "whatever your working hours say"
    if (service && service.wifiRules && service.wifiRules.length > 0) {
      var says = service.wifiLocation
      back = says && String(says.label || "") !== ""
        ? "your wifi (" + String(says.label) + ") or your working hours"
        : "your wifi or your working hours"
    }
    var base = [{
      state: "auto", label: "Automatic", hint: back, placeId: ""
    }].concat(service ? service.locationChoices : [])
    if (!service) return base
    var places = (service.buildings || []).slice(0, Model.buildingMenuCap())
    for (var i = 0; i < places.length; i++)
      base.push({ state: "office", placeId: String(places[i].id || ""),
                  label: String(places[i].name || ""),
                  hint: String(places[i].label || "") })
    return base
  }

  // Told, so a host can shut its own overlay on the way out.
  signal chose(string state)

  function pickAt(index) {
    if (!service || index < 0 || index >= rows.length) return
    var row = rows[index]
    var state = String(row.state || "")
    root.chose(state)
    service.setLocation(state, String(row.placeId || ""))
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

      // Which row is true right now, compared on the place as well as the
      // state: "In the office" and a building are both `office` rows, and
      // without the place both would be ticked.
      //
      // Automatic can be ticked here, which it cannot in the presence picker.
      // Graph aggregates three layers and names the winner in `source`, so
      // "nothing has been said about today" is a state it will report rather
      // than one that would have to be inferred from the absence of a memory.
      readonly property bool current: String(modelData.state || "") === "auto"
        ? (!!root.service && root.service.signedIn && !now)
        : (!!now && String(now.state || "") === String(modelData.state || "")
           && String(now.placeId || "") === String(modelData.placeId || ""))

      // And where the winning layer came from, for the row that won it. A
      // location the calendar expects and a location somebody chose read the
      // same on screen otherwise, and only one of them is a decision.
      readonly property string via: {
        if (!line.current || !now) return ""
        var source = String(now.source || "")
        if (source === "scheduled") return "from your working hours"
        if (source !== "automatic") return ""
        // The automatic layer is one this plugin may have written itself, and
        // "from your wifi" is a truer thing to say about it than "a Teams
        // client noticed" when the client was this one.
        var mine = root.service ? String(root.service.reportedLocation || "") : ""
        var here = String(now.state || "") + ":" + String(now.placeId || "")
        return mine !== "" && mine === here ? "from your wifi" : "noticed by a Teams client"
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
