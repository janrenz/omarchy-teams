import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The calendar: a toolbar saying which days these are, and the days.
//
// Which body is drawn is a question of the view and of how much room there
// is. Month is always a grid of cells; day, work week and week are a clock
// face unless the window is too narrow for one, in which case they are an
// agenda - a week of columns forty pixels wide is a week nobody can read, and
// this window is as often tiled into a third of a screen as it is not.
Item {
  id: root

  property var service: null
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real density: 1.0
  // Which event the keyboard is on, as day-and-id.
  property string cursorKey: ""

  signal eventPicked(string dayKey, var event)
  signal slotPicked(string dayKey, int hour)
  signal newMeetingRequested()

  readonly property var days: root.service ? root.service.calendarDays : []
  readonly property var palette: root.service ? root.service.themeColors : ({})
  readonly property string mode: root.service ? root.service.calendarMode : "week"
  readonly property string openId: root.service ? root.service.openEventId : ""
  // A clock face needs about a hundred pixels a day before the names in it
  // stop being readable; below that the same days are worth more as a list.
  readonly property bool roomForGrid: root.width >= Style.space(120) * Math.max(1, root.days.length)

  function scrollBy(dy) {
    if (body.item && typeof body.item.scrollBy === "function") body.item.scrollBy(dy)
    else agendaScroll.contentItem.contentY = Math.max(
      0, Math.min(Math.max(0, agendaScroll.contentItem.contentHeight - agendaScroll.height),
                  agendaScroll.contentItem.contentY + dy))
  }

  Column {
    anchors.fill: parent
    spacing: Style.spacing.md

    // ---------------- which days these are ----------------
    Item {
      width: parent.width
      height: Math.max(toolbarLeft.implicitHeight, toolbarRight.implicitHeight)

      Row {
        id: toolbarLeft
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: toolbarRight.left
        anchors.rightMargin: Style.spacing.md
        spacing: Style.spacing.sm

        Button {
          text: "Today"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: if (root.service) root.service.calendarToday()
        }

        Button {
          text: "\u{F0141}"   // nf-md-chevron-left
          tooltipText: "The " + root.mode + " before"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: if (root.service) root.service.moveCalendar(-1)
        }

        Button {
          text: "\u{F0142}"   // nf-md-chevron-right
          tooltipText: "The " + root.mode + " after"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: if (root.service) root.service.moveCalendar(1)
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, toolbarLeft.width - x)
          text: root.service
            ? Model.rangeLabel(root.mode, root.service.calendarSpan.keys, root.service.clock)
            : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
      }

      Row {
        id: toolbarRight
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm

        Spinner {
          anchors.verticalCenter: parent.verticalCenter
          visible: !!root.service && root.service.calendarLoading
          color: root.accent
          dotSize: Style.space(4)
        }

        Repeater {
          // The four views, numbered: the keyboard picks them the same way it
          // picks a reaction, and a chip that says which number it is saves
          // anybody having to look the shortcut up.
          model: Model.calendarViewNames()

          delegate: Button {
            required property var modelData
            required property int index
            text: String(index + 1) + "  " + String(modelData).replace(
                    /^./, function(first) { return first.toUpperCase() })
            selected: root.mode === String(modelData)
            bordered: true
            foreground: root.mode === String(modelData) ? root.accent : Qt.darker(root.fg, 1.4)
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: if (root.service) root.service.setCalendarMode(String(modelData))
          }
        }

        Button {
          visible: !!root.service && root.service.canWriteCalendar
          text: "New meeting"
          bordered: true
          foreground: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.newMeetingRequested()
        }
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: {
        if (!root.service) return ""
        if (root.service.calendarError !== "") return root.service.calendarError
        if (root.service.calendarCapped)
          return "There are more meetings in this range than this window will draw. "
               + "A shorter range shows all of them."
        return ""
      }
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: (root.service && root.service.calendarError !== "")
        ? Color.urgent : Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // ---------------- the days ----------------
    Item {
      id: bodyBox
      width: parent.width
      height: Math.max(0, parent.height - y)

      LoadingRows {
        anchors.fill: parent
        visible: !!root.service && root.service.calendarLoading
                 && root.service.calendarEvents.length === 0
        rows: 6
        fg: root.fg
      }

      Loader {
        id: body
        anchors.fill: parent
        active: !(root.service && root.service.calendarLoading
                  && root.service.calendarEvents.length === 0)
                && (root.mode === "month" || root.roomForGrid)
        sourceComponent: root.mode === "month" ? monthView : gridView
      }

      // The same days as a list, for a window with no room for columns.
      ScrollView {
        id: agendaScroll
        anchors.fill: parent
        visible: !body.active
                 && !(root.service && root.service.calendarLoading
                      && root.service.calendarEvents.length === 0)
        clip: true

        Column {
          width: agendaScroll.width
          spacing: Style.spacing.xs

          Repeater {
            model: Model.agendaRows(root.days)

            delegate: Column {
              id: agendaRow
              required property var modelData
              width: parent ? parent.width : 0
              spacing: 0

              Text {
                width: parent.width
                visible: agendaRow.modelData.kind !== "event"
                height: visible ? implicitHeight : 0
                text: agendaRow.modelData.kind === "day"
                  ? agendaRow.modelData.day.weekdayLong + " " + agendaRow.modelData.day.day
                    + " " + agendaRow.modelData.day.month
                    + (agendaRow.modelData.day.isToday ? "  ·  today" : "")
                  : "Nothing on"
                textFormat: Text.PlainText
                color: agendaRow.modelData.kind === "day"
                  ? (agendaRow.modelData.day.isToday ? root.accent : Qt.darker(root.fg, 1.2))
                  : Qt.darker(root.fg, 1.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: agendaRow.modelData.kind === "day"
                topPadding: agendaRow.modelData.kind === "day" ? Style.spacing.sm : 0
              }

              EventChip {
                width: parent.width
                visible: agendaRow.modelData.kind === "event"
                height: visible ? implicitHeight : 0
                // A day heading has no event, and a chip built for one would
                // still evaluate every binding in it - so it is handed
                // something empty rather than nothing.
                event: agendaRow.modelData.event || ({})
                palette: root.palette
                fg: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                live: !!root.service && Model.isNow(agendaRow.modelData.event, root.service.clock)
                cursored: agendaRow.modelData.kind === "event"
                          && root.cursorKey === Model.eventCursorKey(
                               agendaRow.modelData.day.key, agendaRow.modelData.event.id)
                selected: agendaRow.modelData.kind === "event"
                          && root.openId === String(agendaRow.modelData.event.id || "")
                onPicked: root.eventPicked(agendaRow.modelData.day.key,
                                           agendaRow.modelData.event)
                onJoinRequested: if (root.service)
                  root.service.joinMeeting(String(agendaRow.modelData.event.joinUrl || ""))
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: gridView

    CalendarGrid {
      days: root.days
      palette: root.palette
      fg: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      density: root.density
      cursorKey: root.cursorKey
      selectedId: root.openId
      clock: root.service ? root.service.clock : new Date()
      onPicked: function(dayKey, event) { root.eventPicked(dayKey, event) }
      onJoinRequested: function(event) {
        if (root.service) root.service.joinMeeting(String(event.joinUrl || ""))
      }
      onDayPicked: function(dayKey) {
        if (!root.service) return
        root.service.calendarAnchor = dayKey
        root.service.setCalendarMode("day")
      }
      onSlotPicked: function(dayKey, hour) { root.slotPicked(dayKey, hour) }
    }
  }

  Component {
    id: monthView

    CalendarMonth {
      days: root.days
      palette: root.palette
      fg: root.fg
      accent: root.accent
      fontFamily: root.fontFamily
      cursorKey: root.cursorKey
      selectedId: root.openId
      clock: root.service ? root.service.clock : new Date()
      onPicked: function(dayKey, event) { root.eventPicked(dayKey, event) }
      onJoinRequested: function(event) {
        if (root.service) root.service.joinMeeting(String(event.joinUrl || ""))
      }
      onDayPicked: function(dayKey) {
        if (!root.service) return
        root.service.calendarAnchor = dayKey
        root.service.setCalendarMode("day")
      }
    }
  }
}
