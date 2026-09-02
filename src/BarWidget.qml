import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon, and the small dropdown behind it.
//
// The dropdown answers the two questions a bar is asked - how you look to
// people, and whether anything needs you - and hands everything else to the
// window: a conversation is a thing you read and answer, which wants somewhere
// that does not close on click-away half way through a reply. See BarPanel.qml
// for what that division buys and where it is drawn.
BarWidget {
  id: root
  moduleName: "janrenz.omarchy.teams"

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
    return decodeURIComponent(url.replace(/\/$/, ""))
  }

  readonly property string barLabel: String(setting("label", "")).trim()
  readonly property string barIcon: String(setting("icon", "󰊻"))
  readonly property bool tintOnUnread: setting("tintOnUnread", true) !== false

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // The window, which the shell owns because the manifest declares the "panel"
  // kind. Nothing about the dropdown changes this route: a plugin that is both
  // a bar widget and a panel is routed to its panel by the shell, so
  // `omarchy-shell shell toggle janrenz.omarchy.teams` still means the window.
  //
  // Summon rather than toggle, which is what the bar icon means by opening the
  // window: the shell's toggle knows only "open", and a window on another
  // workspace is open - so a click meant to reach it hid it instead, and the
  // second click brought it back to the workspace you were on all along. The
  // window itself is still what closes it, and the toggle above is still what
  // a keybinding gets.
  function openWindow() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon",
                             "janrenz.omarchy.teams", "{}"])
  }

  // Everything the panel needs that it cannot reach from inside a Loader. The
  // bar hands these to a panel it mounts itself; one nested in a widget has to
  // be given them.
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // The shape the bar uses to route summon/hide/toggle and to draw the
  // open-panel mark. It has to live on the widget in the bar slot, not on the
  // panel nested inside it.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
    // The bar is always here and the window is not, so new messages are
    // announced from behind the icon rather than from behind the window.
    notifies: true
    // The bar draws an unread count and a list of what is unread, and the team
    // tree costs a Graph request per team. The window asks for it; this must
    // not.
    includeTeams: false
    // The dropdown shows what is waiting and nothing else, so the filtering is
    // done once here rather than by a second copy of conversationRows in the
    // panel. Fixed rather than a toggle: the whole list is what the window is
    // for.
    unreadOnly: true
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("BarPanel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.plainText(root.barLabel !== "" ? root.barLabel : root.barIcon)
    slotSize: root.barLabel !== "" ? Style.bar.statusSlot * 2 : Style.bar.iconSlot
    active: root.tintOnUnread && service.unreadCount > 0

    tooltipText: {
      if (!service.configured)
        return "Teams: add an account name and client id in settings"
      if (service.needsSignIn) return "Teams: sign in"
      if (!service.signedIn) return "Teams: loading…"
      var lines = [Model.plainText(service.view.username || service.alias)]
      lines.push(service.unreadCount === 0
        ? "no unread chats"
        : (service.unreadCount === 1 ? "1 unread chat" : service.unreadCount + " unread chats"))
      if (!service.hasChannels) lines.push("chats only - channels not consented")
      // A bar that is not moving because nobody is at the machine looks exactly
      // like a bar that is broken. Say which.
      if (service.pollReason !== "") lines.push(service.pollReason)
      for (var i = 0; i < service.warnings.length; i++)
        lines.push(Model.plainText(service.warnings[i].message))
      return lines.join("\n")
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) service.refresh()
      // Right button goes straight to the window, which is where somebody who
      // knows they are about to write a reply wants to be - and is the route
      // that survives the dropdown being no use to them.
      else if (b === Qt.RightButton) root.openWindow()
      else root.togglePanel()
    }
  }
}
