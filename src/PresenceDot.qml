import QtQuick
import qs.Commons
import "Model.js" as Model

// The presence circle, in the one place that draws it. The sidebar rows, the
// header chip, the picker and the bar's popover all show the same four
// states, and a reader should not have to learn them twice - nor a change to
// them have to be made in four places to stay one language.
//
// Shape rather than hue: available and busy are filled, away is a ring,
// offline is dimmed. So the states stay apart on a theme whose yellow and
// green sit close together, and for anyone who cannot tell those apart.
Rectangle {
  id: root

  // One of the four teams.py groups everything down to: available, busy,
  // away, offline. Anything else draws nothing.
  property string state: ""
  // The theme's named colours, as Service reads them.
  property var palette: ({})
  property real size: Style.space(9)

  readonly property string tint: Model.presenceColor(root.state, root.palette)

  width: root.size
  height: root.size
  radius: root.size / 2
  // Nothing at all until a fetch has answered: an unpainted circle reads as
  // offline, which is a different thing from not having asked yet.
  visible: root.tint !== ""
  // An unknown state is never drawn, so its empty tint must not be handed to
  // a colour property either - "" is not a colour, and Qt says so on stderr.
  color: root.tint === "" || root.state === "away" ? "transparent" : root.tint
  opacity: root.state === "offline" ? 0.75 : 1.0
  border.width: root.state === "away" ? Style.space(2) : 0
  border.color: root.tint === "" ? "transparent" : root.tint
}
