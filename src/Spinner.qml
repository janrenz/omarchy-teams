import QtQuick
import qs.Commons

// Three dots, pulsing in turn: something is happening and it has not stalled.
//
// Dots rather than a rotating glyph. A Nerd Font icon does not sit in the
// middle of its own line box, so spinning one wobbles about an off-centre
// point, and every theme's font puts it somewhere slightly different. Three
// rectangles are the same shape in every theme and cannot wobble.
Row {
  id: root

  property color color: Color.accent
  property int dotSize: 4
  property int period: 900

  spacing: Math.max(2, Math.round(dotSize * 0.8))
  visible: opacity > 0

  Repeater {
    model: 3

    delegate: Rectangle {
      required property int index
      width: root.dotSize
      height: root.dotSize
      radius: width
      color: root.color
      anchors.verticalCenter: parent.verticalCenter

      // Each dot lags the one before it by a third of the cycle, which is what
      // reads as travel rather than as three things blinking together.
      SequentialAnimation on opacity {
        running: root.visible
        loops: Animation.Infinite
        PauseAnimation { duration: index * Math.round(root.period / 3) }
        NumberAnimation { to: 1.0; duration: Math.round(root.period / 3); easing.type: Easing.OutQuad }
        NumberAnimation { to: 0.25; duration: Math.round(root.period / 3); easing.type: Easing.InQuad }
        PauseAnimation { duration: root.period - 2 * Math.round(root.period / 3) - index * Math.round(root.period / 3) }
      }
    }
  }
}
