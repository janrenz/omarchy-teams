import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The month: six rows of seven days, each holding as many meetings as it has
// room for and a count of the ones it has not.
//
// The grid deliberately runs into the months either side rather than leaving
// the corners blank - those are real days with real meetings on them, and a
// grid that showed the 1st as empty because the week began in August would be
// saying something untrue. They are drawn quieter instead.
//
// How many chips a cell shows is worked out from the cell, not fixed: the
// same month on a tiled half-screen and on a full one should show as much as
// each can, and "+3 more" is what the difference costs.
Item {
  id: root

  property var days: []
  property var palette: ({})
  property color fg: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property string cursorKey: ""
  property string selectedId: ""
  property var clock: new Date()

  signal picked(string dayKey, var event)
  signal joinRequested(var event)
  signal dayPicked(string dayKey)

  readonly property int weeks: Math.max(1, Math.ceil(root.days.length / 7))
  readonly property real cellWidth: root.width / 7
  readonly property real cellHeight: Math.max(Style.space(52),
                                              (root.height - weekdayRow.height) / root.weeks)
  readonly property int chipHeight: Style.font.caption + Style.spacing.sm
  // What is left of a cell once its date has had its line.
  readonly property int chipsPerCell: Math.max(1, Math.floor(
    (root.cellHeight - Style.font.caption - Style.spacing.md * 2 - Style.space(4))
    / (root.chipHeight + Style.space(1))))

  Column {
    anchors.fill: parent
    spacing: 0

    Row {
      id: weekdayRow
      width: parent.width
      height: Style.font.caption + Style.spacing.sm * 2

      Repeater {
        // The first week is the row of names: whichever seven days the range
        // starts with are in the right order by construction, so nothing here
        // has to know whether the week starts on Monday.
        model: root.days.slice(0, 7)

        delegate: Text {
          required property var modelData
          width: root.cellWidth
          height: weekdayRow.height
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: modelData.weekday
          textFormat: Text.PlainText
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    PanelSeparator { width: parent.width }

    Item {
      width: parent.width
      height: Math.max(0, parent.height - weekdayRow.height - Style.space(1))
      clip: true

      Repeater {
        model: root.days

        delegate: Item {
          id: cell
          required property var modelData
          required property int index
          x: (index % 7) * root.cellWidth
          y: Math.floor(index / 7) * root.cellHeight
          width: root.cellWidth
          height: root.cellHeight
          // A busy day must not write into the day under it. What does not
          // fit is counted by the line below rather than drawn over its
          // neighbour.
          clip: true

          // "+3 more" needs a line of its own, so a cell that is going to
          // need one shows one chip fewer rather than one chip too many.
          readonly property int shown: cell.modelData.count <= root.chipsPerCell
            ? cell.modelData.count : Math.max(1, root.chipsPerCell - 1)

          Rectangle {
            anchors.fill: parent
            color: cell.modelData.isToday ? Util.alpha(root.accent, 0.06)
                   : (cell.modelData.otherMonth
                      ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.03) : "transparent")
            border.width: Style.space(1)
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            // A day in a month grid is a way in to that day, which is the
            // only thing there is room to do with it here.
            onClicked: root.dayPicked(cell.modelData.key)
          }

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            spacing: Style.space(1)

            Row {
              width: parent.width
              spacing: Style.spacing.xxs

              Rectangle {
                width: Math.max(number.implicitWidth + Style.spacing.sm,
                                number.implicitHeight + Style.spacing.xxs)
                height: number.implicitHeight + Style.spacing.xxs
                radius: height / 2
                color: cell.modelData.isToday ? root.accent : "transparent"

                Text {
                  id: number
                  anchors.centerIn: parent
                  // The 1st says which month it has moved into, which is the
                  // only labelling the leading and trailing cells need.
                  text: cell.modelData.firstOfMonth
                    ? (cell.modelData.day + " " + cell.modelData.month)
                    : String(cell.modelData.day)
                  textFormat: Text.PlainText
                  color: cell.modelData.isToday ? Color.background
                         : (cell.modelData.otherMonth ? Qt.darker(root.fg, 1.9)
                            : (cell.modelData.isPast ? Qt.darker(root.fg, 1.5) : root.fg))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: cell.modelData.isToday
                }
              }
            }

            Repeater {
              model: cell.modelData.allDay.concat(cell.modelData.timed).slice(0, cell.shown)

              delegate: EventChip {
                required property var modelData
                width: parent ? parent.width : 0
                height: root.chipHeight
                event: modelData
                palette: root.palette
                fg: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                dense: true
                live: Model.isNow(modelData, root.clock)
                cursored: root.cursorKey === Model.eventCursorKey(cell.modelData.key, modelData.id)
                selected: root.selectedId === String(modelData.id)
                onPicked: root.picked(cell.modelData.key, modelData)
                onJoinRequested: root.joinRequested(modelData)
              }
            }

            Text {
              width: parent.width
              visible: cell.modelData.count > cell.shown
              text: "+" + (cell.modelData.count - cell.shown) + " more"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
