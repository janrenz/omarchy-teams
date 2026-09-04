import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One meeting, opened: when and where it is, who is coming, what it is about,
// and the three things there are to do about it - join it, answer it, call it
// off.
//
// The answer buttons are numbered because the keyboard picks by number, the
// same way the reaction picker does. They are only here when there is a
// question: an organiser has nothing to accept, and an appointment nobody was
// invited to has nobody to answer.
//
// The agenda is drawn the way a message is - flattened in teams.py, escaped
// here, and the only tag built is the <a> around a link. An invitation is
// HTML somebody else wrote, and rich text fetches what it is told to.
Column {
  id: root

  property var service: null
  property var event: null
  property var palette: ({})
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal closeRequested()

  readonly property bool canWrite: !!service && service.canWriteCalendar === true
  readonly property bool answerable: Model.answerable(root.event)
  readonly property bool mine: !!root.event && root.event.isOrganizer === true
  readonly property string joinUrl: root.event ? String(root.event.joinUrl || "") : ""
  readonly property var attendees: (root.event && root.event.attendees) || []

  // Accept, tentative, decline - in that order, because that is the order the
  // number keys are in and the order Teams offers them.
  readonly property var answers: [
    { key: "accept", label: "Accept", state: "accepted" },
    { key: "tentative", label: "Tentative", state: "tentative" },
    { key: "decline", label: "Decline", state: "declined" }
  ]

  // Whether the line for the organiser has the keyboard. The window's key
  // catcher stands down while it does - it claims bare letters, and 1, 2 and
  // 3 are answers out here and digits in there.
  readonly property bool typing: comment.activeFocus

  // The same two-step the button does, for the keyboard: the first press asks
  // and the second answers. There is no route back from either.
  function armCancel() {
    if (!root.canWrite || !root.event) return
    if (!root.cancelArmed) { root.cancelArmed = true; return }
    root.cancelArmed = false
    if (root.service) root.service.cancelEvent(String(root.event.id), "")
  }

  function answerAt(index) {
    if (!root.answerable || !root.canWrite || index < 0 || index >= answers.length) return
    root.service.rsvp(String(root.event.id), answers[index].key,
                      root.service.rsvpComment, !root.service.rsvpReplies)
  }

  function responseColor(response) {
    var colors = root.palette || {}
    switch (String(response || "")) {
      case "accepted":  return colors.green || root.accent
      case "tentative": return colors.yellow || colors.orange || root.accent
      case "declined":  return colors.red || Color.urgent
      case "organizer": return colors.blue || root.accent
      default:          return Qt.darker(root.fg, 2.0)
    }
  }

  spacing: Style.spacing.md

  // ---------------- what and when ----------------

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(4)
      height: Math.max(Style.space(20), subject.implicitHeight)
      radius: width / 2
      color: {
        var tint = Model.eventTint(root.event, root.palette)
        return tint !== "" ? tint : root.accent
      }
    }

    Text {
      id: subject
      width: Math.max(0, parent.width - x - Style.spacing.sm)
      text: root.event ? String(root.event.subject || "") : ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      font.strikeout: !!root.event && root.event.cancelled === true
    }
  }

  Text {
    width: parent.width
    visible: !!root.event && root.event.cancelled === true
    text: "This meeting has been cancelled"
    textFormat: Text.PlainText
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    text: root.event
      ? Model.rangeLabel("day", [String(root.event.startDate || "")], new Date())
        + "  ·  " + Model.eventTimeLabel(root.event)
        + (Model.durationLabel(root.event) !== "" && root.event.allDay !== true
           ? "  ·  " + Model.durationLabel(root.event) : "")
      : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // The lines that are only there when they say something: a room, a repeat,
  // how it counts against your day.
  Text {
    width: parent.width
    visible: text !== ""
    text: {
      if (!root.event) return ""
      var parts = []
      if (String(root.event.where || "") !== "") parts.push(String(root.event.where))
      if (root.event.recurring === true) parts.push("Repeats")
      if (root.event.online === true) parts.push("Teams meeting")
      var shown = Model.showAsLabel(root.event.showAs)
      if (shown !== "" && shown !== "Busy") parts.push(shown)
      if (root.event.private === true) parts.push("Private")
      return parts.join("  ·  ")
    }
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(root.fg, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    visible: text !== ""
    text: {
      if (!root.event) return ""
      var who = String((root.event.organizer || {}).name || "")
      if (who === "") return ""
      return root.mine ? "Organised by you" : "Organised by " + who
    }
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: Qt.darker(root.fg, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---------------- joining ----------------

  Row {
    width: parent.width
    spacing: Style.spacing.sm
    visible: root.joinUrl !== "" || root.answerable

    Button {
      visible: root.joinUrl !== ""
      text: "Join"
      tooltipText: "Opens the meeting in whatever handles Teams meetings on this machine - "
                 + "a window like this one cannot carry audio and video."
      bordered: true
      foreground: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: if (root.service) root.service.joinMeeting(root.joinUrl)
    }

    // What you have said so far, beside the buttons that change it - so the
    // three below read as "change your answer" rather than as an unanswered
    // question you have already answered.
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      text: root.event ? Model.responseLabel(root.event.response) : ""
      textFormat: Text.PlainText
      color: root.responseColor(root.event ? root.event.response : "")
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // ---------------- answering ----------------

  Column {
    width: parent.width
    spacing: Style.spacing.sm
    visible: root.answerable

    PanelSeparator { width: parent.width }

    Row {
      width: parent.width
      spacing: Style.spacing.sm

      Repeater {
        model: root.answers

        delegate: Button {
          required property var modelData
          required property int index
          // Numbered, because the keyboard picks by number - the same idiom
          // the reaction picker uses.
          text: String(index + 1) + "  " + String(modelData.label)
          enabled: root.canWrite && !!root.service && !root.service.rsvpSending
          selected: !!root.event && String(root.event.response) === String(modelData.state)
          bordered: true
          foreground: root.responseColor(modelData.state)
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.answerAt(index)
        }
      }

      Spinner {
        anchors.verticalCenter: parent.verticalCenter
        visible: !!root.service && root.service.rsvpSending
        color: root.accent
        dotSize: Style.space(4)
      }
    }

    TextField {
      id: comment
      width: parent.width
      visible: root.canWrite
      placeholderText: "A line for the organiser, if you like"
      foreground: root.fg
      accent: root.accent
      text: root.service ? root.service.rsvpComment : ""
      onTextChanged: if (root.service && text !== root.service.rsvpComment)
        root.service.rsvpComment = text
    }

    Row {
      spacing: Style.spacing.sm
      visible: root.canWrite

      Button {
        text: (root.service && root.service.rsvpReplies ? "\u{F012C}  " : "")
              + "Let the organiser know"
        tooltipText: "Off answers the invitation without sending anybody a reply, "
                   + "which is what Teams' \"Don't send a response\" does."
        selected: !!root.service && root.service.rsvpReplies
        bordered: true
        foreground: (root.service && root.service.rsvpReplies)
          ? root.accent : Qt.darker(root.fg, 1.5)
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: if (root.service) root.service.rsvpReplies = !root.service.rsvpReplies
      }
    }

    Text {
      width: parent.width
      visible: !root.canWrite
      text: "This sign-in can read your calendar but not answer invitations. Turn on "
            + "\"Answer and create meetings\" in settings and sign in again."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: !!root.service && root.service.rsvpError !== ""
      text: root.service ? root.service.rsvpError : ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---------------- who is coming ----------------

  Column {
    width: parent.width
    spacing: Style.spacing.xs
    visible: root.attendees.length > 0

    PanelSeparator { width: parent.width }

    Text {
      width: parent.width
      text: root.attendees.length + " invited"
            + (Model.attendeeSummary(root.attendees) !== ""
               ? "  ·  " + Model.attendeeSummary(root.attendees) : "")
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: root.attendees

      delegate: Row {
        required property var modelData
        width: parent ? parent.width : 0
        spacing: Style.spacing.sm

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6)
          height: Style.space(6)
          radius: width / 2
          color: root.responseColor(modelData.response)
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - x - Style.spacing.sm)
          text: String(modelData.name || modelData.address || "")
                + (String(modelData.kind) === "optional" ? "  (optional)" : "")
                + (String(modelData.kind) === "resource" ? "  (room)" : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: String(modelData.response) === "declined"
            ? Qt.darker(root.fg, 1.7) : Qt.darker(root.fg, 1.2)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---------------- what it is about ----------------

  Column {
    width: parent.width
    spacing: Style.spacing.xs
    visible: !!root.event && String(root.event.text || "") !== ""

    PanelSeparator { width: parent.width }

    SelectableText {
      width: parent.width
      // Escaped first and linked afterwards, never the other way round: an
      // agenda is somebody else's markup and this is the only place a tag is
      // built out of it.
      readonly property bool linked: !!root.event
        && Model.hasLink(root.event.text, root.event.links)
      text: root.event
        ? (linked ? Model.linkify(root.event.text,
                                  (root.palette.blue || root.palette.accent || ""),
                                  root.event.links)
                  : String(root.event.text || ""))
        : ""
      textFormat: linked ? TextEdit.RichText : TextEdit.PlainText
      color: Qt.darker(root.fg, 1.1)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      onLinkActivated: function(url) { if (root.service) root.service.openUrl(url) }

      HoverHandler {
        enabled: parent.hoveredLink !== ""
        cursorShape: Qt.PointingHandCursor
      }
    }

    Text {
      width: parent.width
      visible: !!root.event && root.event.truncated === true
      text: "The rest of the agenda is longer than this window will draw."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(root.fg, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---------------- calling it off ----------------

  PanelSeparator { width: parent.width }

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    Button {
      text: "Close"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: root.closeRequested()
    }

    // Two different things behind one button, and which one it is depends on
    // whose meeting it is - so the button says which, rather than leaving it
    // to be found out afterwards.
    Button {
      visible: root.canWrite && !!root.event
      enabled: !!root.service && !root.service.cancelling
      text: root.service && root.service.cancelling ? "…"
            : (root.mine ? (root.cancelArmed ? "Really cancel it?" : "Cancel meeting")
                         : (root.cancelArmed ? "Really remove it?" : "Remove from my calendar"))
      tooltipText: root.mine
        ? "Cancels the meeting and tells everybody who was invited"
        : "Takes it off your own calendar. Nobody else is told."
      bordered: true
      foreground: root.cancelArmed ? Color.urgent : Qt.darker(root.fg, 1.4)
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      // Asked twice, because there is no route back: the first press arms the
      // question and the second answers it, the same as marking every chat
      // read in the dropdown.
      onClicked: {
        if (!root.cancelArmed) { root.cancelArmed = true; return }
        root.cancelArmed = false
        if (root.service) root.service.cancelEvent(String(root.event.id), "")
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: text !== ""
      text: root.service ? (root.service.cancelError !== "" ? root.service.cancelError
                            : root.service.eventError) : ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Armed by the first press of Cancel and disarmed by anything else,
  // including the pane being opened on another meeting - coming back to a
  // question still armed is how the answer gets given by accident.
  property bool cancelArmed: false
  onEventChanged: cancelArmed = false
}
