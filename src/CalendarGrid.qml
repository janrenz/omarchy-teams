import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The day, work-week and week views: a column per day over a clock face.
//
// One component for all three, because they differ only in how many columns
// there are - which is what `days` already says. The header and the all-day
// strip stay put and only the clock face scrolls, the way every calendar
// does it: a week whose weekday names scroll away is a week you cannot read.
//
// Blocks are positioned by the minute rather than laid out, because that is
// what a time grid is: `Model.daySpan` says where in the day an event sits
// (clipped to it, so a meeting running past midnight is two blocks), and
// `Model.layoutColumns` decides which of them stand side by side.
Item {
  id: root

  property var days: []
  property var palette: ({})
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real density: 1.0
  // Which event the keyboard is on, as day-and-id: the same meeting appears
  // in two columns when it runs past midnight, and the cursor is on one of
  // them rather than on both.
  property string cursorKey: ""
  property string selectedId: ""
  // Ticks once a minute. Only the line across today binds to it, so nothing
  // else is rebuilt when it moves.
  property var clock: new Date()

  signal picked(string dayKey, var event)
  signal joinRequested(var event)
  signal dayPicked(string dayKey)
  // Where the cursored block ended up, so the pane holding this can keep it
  // on screen. The grid cannot scroll itself - it does not know it is in a
  // ScrollView.
  signal cursorAt(real itemY, real itemHeight)

  // An hour of the day, in pixels. Generous enough that a half-hour meeting
  // can carry its own name, and scaled by the spacing setting like everything
  // else.
  readonly property int hourHeight: Math.max(Style.space(28),
                                             Math.round(Style.space(44) * root.density))
  readonly property int gutter: Math.max(Style.space(38), Style.font.caption * 4)
  readonly property real columnWidth: root.days.length > 0
    ? Math.max(Style.space(40), (root.width - root.gutter) / root.days.length) : 0
  readonly property bool oneDay: root.days.length === 1

  // Where a fresh view should be looking. Midnight is nobody's working day.
  function scrollToHour(hour) {
    var flick = face.contentItem
    if (!flick) return
    var limit = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(limit, Math.round(hour * root.hourHeight)))
  }

  function scrollBy(dy) {
    var flick = face.contentItem
    if (!flick) return
    var limit = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(limit, flick.contentY + dy))
  }

  // Keep the block the keys are on in view, which is the same job the
  // conversation list does for its cursored row.
  function revealCursor() {
    var flick = face.contentItem
    if (!flick || root.cursorKey === "") return
    for (var d = 0; d < root.days.length; d++) {
      var day = root.days[d]
      for (var t = 0; t < day.timed.length; t++) {
        if (Model.eventCursorKey(day.key, day.timed[t].id) !== root.cursorKey) continue
        var span = Model.daySpan(day.timed[t], day.key)
        var top = span.start / 60 * root.hourHeight
        var height = Math.max(Style.space(14), (span.end - span.start) / 60 * root.hourHeight)
        var margin = Style.spacing.lg
        if (top - margin < flick.contentY) flick.contentY = Math.max(0, top - margin)
        else if (top + height + margin > flick.contentY + flick.height)
          flick.contentY = Math.max(0, top + height + margin - flick.height)
        return
      }
    }
  }

  onCursorKeyChanged: Qt.callLater(root.revealCursor)

  // Opened on the working day rather than on midnight - but not before there
  // is a working day to open on. The grid is built while the fetch is still
  // in flight, so a scroll at creation lands on an empty clock face and
  // scrolls to whatever the fallback said; this waits for the first days that
  // have something on them and then leaves the reader alone for good.
  property bool placed: false

  onDaysChanged: {
    if (root.placed) return
    for (var i = 0; i < root.days.length; i++) {
      if (root.days[i].timed.length === 0) continue
      root.placed = true
      placeTimer.restart()
      return
    }
  }

  // Through a timer rather than a callLater, because what is being waited for
  // is not the next tick but the ScrollView knowing how tall its content is:
  // until it does, contentHeight is zero, every position clamps to the top,
  // and the grid opens at midnight however carefully the hour was worked out.
  Timer {
    id: placeTimer
    interval: 120
    onTriggered: root.scrollToHour(Model.firstBusyHour(root.days, root.clock))
  }

  Column {
    anchors.fill: parent
    spacing: 0

    // ---------------- the weekday names ----------------
    Row {
      id: header
      width: parent.width
      height: headerHeight
      readonly property int headerHeight: Style.font.body + Style.font.caption
                                          + Style.spacing.md * 2

      Item { width: root.gutter; height: 1 }

      Repeater {
        model: root.days

        delegate: Item {
          required property var modelData
          width: root.columnWidth
          height: header.headerHeight

          Column {
            anchors.centerIn: parent
            spacing: 0

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.oneDay ? modelData.weekdayLong : modelData.weekday
              textFormat: Text.PlainText
              color: modelData.isToday ? root.accent : Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Today's number is the one thing on this row worth a circle -
            // it is how a calendar says where you are.
            Rectangle {
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.max(dayNumber.implicitWidth + Style.spacing.sm * 2,
                              dayNumber.implicitHeight + Style.spacing.xxs * 2)
              height: dayNumber.implicitHeight + Style.spacing.xxs * 2
              radius: height / 2
              color: modelData.isToday ? root.accent : "transparent"

              Text {
                id: dayNumber
                anchors.centerIn: parent
                text: String(modelData.day)
                textFormat: Text.PlainText
                color: modelData.isToday ? Color.background
                       : (modelData.isPast ? Qt.darker(root.fg, 1.6) : root.fg)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: modelData.isToday
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            // Clicking a weekday goes to that day, which is what a week view
            // is for once you have found the day you meant.
            onClicked: root.dayPicked(modelData.key)
          }
        }
      }
    }

    PanelSeparator { width: parent.width }

    // ---------------- what has no time of day ----------------
    Row {
      id: allDayStrip
      width: parent.width
      visible: root.anyAllDay
      height: visible ? root.allDayHeight : 0

      Text {
        width: root.gutter
        height: parent.height
        horizontalAlignment: Text.AlignRight
        rightPadding: Style.spacing.sm
        topPadding: Style.spacing.xs
        text: "All day"
        textFormat: Text.PlainText
        color: Qt.darker(root.fg, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.days

        delegate: Item {
          // Named, because the chip below declares a modelData of its own and
          // an unqualified one in there would be the chip's, not the day's.
          id: allDayCell
          required property var modelData
          width: root.columnWidth
          height: root.allDayHeight

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(1)
            spacing: Style.space(1)

            Repeater {
              model: modelData.allDay

              delegate: EventChip {
                required property var modelData
                readonly property string dayKey: allDayCell.modelData.key
                width: parent ? parent.width : 0
                height: root.allDayRowHeight
                event: modelData
                palette: root.palette
                fg: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                dense: true
                cursored: root.cursorKey === Model.eventCursorKey(dayKey, modelData.id)
                selected: root.selectedId === String(modelData.id)
                onPicked: root.picked(dayKey, modelData)
                onJoinRequested: root.joinRequested(modelData)
              }
            }
          }
        }
      }
    }

    PanelSeparator { width: parent.width; visible: allDayStrip.visible }

    // ---------------- the clock face ----------------
    ScrollView {
      id: face
      width: parent.width
      height: Math.max(0, parent.height - header.height - allDayStrip.height
                          - (allDayStrip.visible ? Style.space(2) : Style.space(1)))
      clip: true

      Item {
        id: faceContent
        // Implicit, not explicit: a ScrollView takes the size of what it is
        // scrolling from its child's *implicit* size, so an Item that sets
        // only `height` scrolls nowhere at all - contentHeight stays at the
        // viewport's and the grid is stuck at midnight. An Item's height
        // follows its implicitHeight anyway, so this says both.
        implicitWidth: face.width
        implicitHeight: root.hourHeight * 24

        // The hour lines, and the hours themselves down the left. Drawn once
        // for the whole grid rather than once per column: they are the same
        // twenty-four lines whichever day is under them.
        Repeater {
          model: 24

          delegate: Item {
            required property int index
            x: 0
            y: index * root.hourHeight
            width: faceContent.width
            height: root.hourHeight

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: root.gutter
              height: Style.space(1)
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
            }

            // The half-hour, fainter. It is what makes a thirty-minute
            // meeting look like half of an hour rather than like some block.
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: root.gutter
              y: Math.round(root.hourHeight / 2)
              height: Style.space(1)
              visible: root.hourHeight >= Style.space(36)
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
            }

            Text {
              x: 0
              y: -implicitHeight / 2
              width: root.gutter - Style.spacing.sm
              horizontalAlignment: Text.AlignRight
              // Midnight's label would sit half above the grid, and nobody
              // needs telling where a day starts.
              visible: index > 0
              text: (index < 10 ? "0" : "") + index + ":00"
              textFormat: Text.PlainText
              color: Qt.darker(root.fg, 1.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // The day columns, and the blocks in them.
        Repeater {
          model: root.days

          delegate: Item {
            id: dayColumn
            required property var modelData
            required property int index
            x: root.gutter + index * root.columnWidth
            y: 0
            width: root.columnWidth
            height: faceContent.height

            // A weekend, and any day that is already over, sit back a little
            // so today stands out without today having to shout.
            Rectangle {
              anchors.fill: parent
              visible: dayColumn.modelData.isWeekend || dayColumn.modelData.isToday
              color: dayColumn.modelData.isToday
                ? Util.alpha(root.accent, 0.04)
                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.03)
            }

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(1)
              visible: dayColumn.index > 0 || root.oneDay
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
            }

            // Clicking the empty part of a day is how a calendar starts a
            // meeting: at the hour that was clicked, on the day that was.
            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton
              onDoubleClicked: function(mouse) {
                root.slotPicked(dayColumn.modelData.key,
                                Math.floor(mouse.y / root.hourHeight))
              }
            }

            Repeater {
              model: Model.layoutColumns(dayColumn.modelData.timed, dayColumn.modelData.key)

              delegate: EventChip {
                required property var modelData
                readonly property real slotWidth:
                  (dayColumn.width - Style.space(2)) / Math.max(1, modelData.columns)
                x: Style.space(1) + modelData.column * slotWidth
                y: Math.round(modelData.start / 60 * root.hourHeight)
                width: Math.max(Style.space(20), slotWidth - Style.space(1))
                height: Math.max(Style.space(14),
                                 Math.round((modelData.end - modelData.start) / 60
                                            * root.hourHeight) - Style.space(1))
                event: modelData.event
                palette: root.palette
                fg: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                live: Model.isNow(modelData.event, root.clock)
                cursored: root.cursorKey
                          === Model.eventCursorKey(dayColumn.modelData.key, modelData.event.id)
                selected: root.selectedId === String(modelData.event.id)
                onPicked: root.picked(dayColumn.modelData.key, modelData.event)
                onJoinRequested: root.joinRequested(modelData.event)
              }
            }

            // Now, on the day it is now on. Over the blocks rather than under
            // them, because the whole point of the line is knowing which
            // meeting you are in the middle of.
            Item {
              readonly property var minutes: Model.nowMinutes(dayColumn.modelData.key, root.clock)
              anchors.left: parent.left
              anchors.right: parent.right
              y: minutes === null ? 0 : Math.round(minutes / 60 * root.hourHeight)
              height: Style.space(2)
              visible: minutes !== null
              z: 10

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(1)
                color: root.accent
              }

              Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(6)
                height: Style.space(6)
                radius: width / 2
                color: root.accent
              }
            }
          }
        }
      }
    }
  }

  // Whether the strip above the grid is needed at all. An empty one is a
  // stripe of nothing between the weekday names and the morning.
  readonly property bool anyAllDay: {
    for (var i = 0; i < root.days.length; i++)
      if (root.days[i].allDay.length > 0) return true
    return false
  }

  readonly property int allDayRowHeight: Style.font.caption + Style.spacing.sm
  readonly property int allDayHeight: {
    var most = 0
    for (var i = 0; i < root.days.length; i++)
      most = Math.max(most, root.days[i].allDay.length)
    // Three rows and then it scrolls inside itself, which is better than an
    // absence eating half the working day.
    return Math.min(3, Math.max(1, most)) * (root.allDayRowHeight + Style.space(1))
           + Style.spacing.xs
  }

  // Double-clicking an empty hour books a meeting there, which is what every
  // calendar does and the only way to start one without aiming at a button.
  signal slotPicked(string dayKey, int hour)
}
