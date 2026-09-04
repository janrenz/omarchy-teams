import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Booking a meeting: what it is called, when it is, who is in it.
//
// The draft is one object rather than a field each, so that what is typed
// survives the form being closed and reopened - somebody who went to look at
// next Tuesday before finishing an invitation should not come back to an
// empty form. The window owns it; this only edits it.
//
// The guest list is the people search the new-chat card already uses. There is
// one directory and one way of searching it, and a second copy of that would
// be a second thing to get wrong.
Column {
  id: root

  property var service: null
  // { subject, date, from, to, allDay, days, online, where, text, attendees[] }
  property var draft: ({})
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal changed(string field, var value)
  signal createRequested()
  signal closeRequested()

  readonly property var guests: root.draft.attendees || []
  readonly property bool allDay: root.draft.allDay === true
  readonly property string problem: Model.newMeetingProblem(root.draft)
  readonly property bool canWrite: !!root.service && root.service.canWriteCalendar === true

  function has(address) {
    for (var i = 0; i < root.guests.length; i++)
      if (String(root.guests[i].address) === String(address)) return true
    return false
  }

  function addGuest(person) {
    var address = String(person.address || "").trim()
    if (address === "" || has(address)) return
    root.changed("attendees", root.guests.concat([{
      address: address, name: String(person.name || ""), kind: "required"
    }]))
  }

  function dropGuest(address) {
    var kept = []
    for (var i = 0; i < root.guests.length; i++)
      if (String(root.guests[i].address) !== String(address)) kept.push(root.guests[i])
    root.changed("attendees", kept)
  }

  function toggleGuestKind(address) {
    var next = []
    for (var i = 0; i < root.guests.length; i++) {
      var guest = root.guests[i]
      next.push(String(guest.address) !== String(address) ? guest
                : { address: guest.address, name: guest.name,
                    kind: guest.kind === "optional" ? "required" : "optional" })
    }
    root.changed("attendees", next)
  }

  function nudgeDate(days) {
    root.changed("date", Model.addDays(String(root.draft.date || ""), days))
  }

  spacing: Style.spacing.md

  Text {
    width: parent.width
    text: "New meeting"
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }

  LabeledField {
    width: parent.width
    label: "Subject"
    placeholder: "What it is about"
    value: String(root.draft.subject || "")
    fg: root.fg
    accent: root.accent
    fontFamily: root.fontFamily
    onEdited: function(value) { root.changed("subject", value) }
  }

  // ---------------- when ----------------

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    LabeledField {
      width: Style.space(130)
      label: "Date"
      placeholder: "2026-09-04"
      value: String(root.draft.date || "")
      fg: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      onEdited: function(value) { root.changed("date", value) }
    }

    Column {
      anchors.bottom: parent.bottom
      spacing: Style.spacing.xxs

      Row {
        spacing: Style.spacing.xxs

        Button {
          text: "\u{F0141}"   // nf-md-chevron-left
          tooltipText: "The day before"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.nudgeDate(-1)
        }

        Button {
          text: "\u{F0142}"   // nf-md-chevron-right
          tooltipText: "The day after"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.nudgeDate(1)
        }
      }
    }

    LabeledField {
      width: Style.space(90)
      visible: !root.allDay
      label: "From"
      placeholder: "09:00"
      value: String(root.draft.from || "")
      fg: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      onEdited: function(value) { root.changed("from", value) }
    }

    LabeledField {
      width: Style.space(90)
      visible: !root.allDay
      label: "To"
      placeholder: "09:30"
      value: String(root.draft.to || "")
      fg: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      onEdited: function(value) { root.changed("to", value) }
    }

    NumberField {
      anchors.bottom: parent.bottom
      visible: root.allDay
      label: "Days"
      from: 1
      to: 30
      stepSize: 1
      value: Math.max(1, Number(root.draft.days || 1))
      foreground: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      onModified: function(value) { root.changed("days", value) }
    }
  }

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    Button {
      text: "All day"
      selected: root.allDay
      bordered: true
      foreground: root.allDay ? root.accent : Qt.darker(root.fg, 1.4)
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.changed("allDay", !root.allDay)
    }

    Button {
      text: "Teams meeting"
      tooltipText: "Books the online meeting with it and puts the join link in the "
                 + "invitation, which is what makes it a Teams meeting rather than an "
                 + "appointment in your own calendar."
      selected: root.draft.online !== false
      bordered: true
      foreground: root.draft.online !== false ? root.accent : Qt.darker(root.fg, 1.4)
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.changed("online", root.draft.online === false)
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      text: {
        if (root.allDay) return ""
        var payload = Model.newMeetingPayload(root.draft)
        return Model.newMeetingProblem(root.draft) === ""
          ? Model.durationLabel({ minutes: Math.round(
              (new Date(payload.end) - new Date(payload.start)) / 60000) })
          : ""
      }
      textFormat: Text.PlainText
      color: Qt.darker(root.fg, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  LabeledField {
    width: parent.width
    label: "Where"
    placeholder: "A room, or nowhere in particular"
    value: String(root.draft.where || "")
    fg: root.fg
    accent: root.accent
    fontFamily: root.fontFamily
    onEdited: function(value) { root.changed("where", value) }
  }

  // ---------------- who ----------------

  Text {
    width: parent.width
    text: "Who"
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Flow {
    width: parent.width
    spacing: Style.spacing.xxs
    visible: root.guests.length > 0

    Repeater {
      model: root.guests

      delegate: Rectangle {
        required property var modelData
        width: guestRow.implicitWidth + Style.spacing.md
        height: guestRow.implicitHeight + Style.spacing.xs
        radius: height / 2
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        border.width: String(modelData.kind) === "optional" ? Style.space(1) : 0
        border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)

        Row {
          id: guestRow
          anchors.centerIn: parent
          spacing: Style.spacing.xs

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: String(modelData.name || modelData.address)
                  + (String(modelData.kind) === "optional" ? " (optional)" : "")
            textFormat: Text.PlainText
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "\u{F0156}"   // nf-md-close
            textFormat: Text.PlainText
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.spacing.xxs
              cursorShape: Qt.PointingHandCursor
              onClicked: root.dropGuest(modelData.address)
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          // Clicking the chip is how somebody stops being required, which is
          // the only other thing there is to say about a guest.
          onClicked: root.toggleGuestKind(modelData.address)
          z: -1
        }
      }
    }
  }

  TextField {
    id: guestSearch
    width: parent.width
    placeholderText: "Invite somebody - name or address"
    foreground: root.fg
    accent: root.accent
    onTextChanged: guestDebounce.restart()
  }

  Timer {
    id: guestDebounce
    interval: 300
    // The directory is a network round trip, so not on every keystroke.
    onTriggered: if (root.service) root.service.searchPeople(guestSearch.text)
  }

  Column {
    width: parent.width
    spacing: Style.spacing.xxs
    visible: !!root.service && root.service.peopleResults.length > 0
             && guestSearch.text.length >= 2

    Repeater {
      model: root.service ? root.service.peopleResults : []

      delegate: Rectangle {
        required property var modelData
        width: parent ? parent.width : 0
        implicitHeight: person.implicitHeight + Style.spacing.sm
        radius: Style.space(4)
        color: personPointer.containsMouse
          ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1) : "transparent"

        Text {
          id: person
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.spacing.sm
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: String(modelData.name || "")
                + (String(modelData.address || "") !== ""
                   ? "  ·  " + String(modelData.address) : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: personPointer
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.addGuest(modelData)
            guestSearch.text = ""
            if (root.service) root.service.clearPeople()
          }
        }
      }
    }
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.peopleError !== ""
    text: root.service ? root.service.peopleError : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---------------- what about ----------------

  Rectangle {
    width: parent.width
    height: Style.space(72)
    radius: Style.space(5)
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
    border.width: Style.space(1)
    border.color: agenda.activeFocus
      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7)
      : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)

    ScrollView {
      anchors.fill: parent
      anchors.margins: Style.spacing.sm
      clip: true

      TextArea {
        id: agenda
        placeholderText: "Agenda, if there is one"
        wrapMode: TextArea.Wrap
        color: root.fg
        placeholderTextColor: Qt.darker(root.fg, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        background: null
        text: String(root.draft.text || "")
        onTextChanged: if (text !== String(root.draft.text || "")) root.changed("text", text)
      }
    }
  }

  // ---------------- sending it ----------------

  Text {
    width: parent.width
    visible: text !== ""
    text: {
      if (!root.canWrite)
        return "This sign-in can read your calendar but not add to it. Turn on \"Answer "
             + "and create meetings\" in settings and sign in again."
      if (root.service && root.service.createEventError !== "")
        return root.service.createEventError
      return ""
    }
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    spacing: Style.spacing.sm

    Button {
      enabled: root.canWrite && root.problem === ""
               && !!root.service && !root.service.creatingEvent
      text: root.service && root.service.creatingEvent ? "Sending…" : "Create"
      bordered: true
      foreground: root.problem === "" ? root.accent : Qt.darker(root.fg, 1.6)
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.createRequested()
    }

    Button {
      text: "Cancel"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.closeRequested()
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      // What is still wrong with it, rather than a Create button that is
      // simply dead and does not say why.
      visible: root.problem !== "" && String(root.draft.subject || "") !== ""
      text: root.problem
      textFormat: Text.PlainText
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
