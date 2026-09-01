import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar icon. Unlike the mail widget there is no dropdown behind it: a
// conversation is a thing you read and answer, which wants a window, so the
// icon opens the window rather than a popup that would close on click-away
// half way through a reply.
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

  function openWindow() {
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "janrenz.omarchy.teams"])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
    // The bar is always here and the window is not, so new messages are
    // announced from behind the icon rather than from behind the window.
    notifies: true
    // The bar draws an unread count and nothing else, and the team tree costs
    // a Graph request per team. The window asks for it; this must not.
    includeTeams: false
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
      for (var i = 0; i < service.warnings.length; i++)
        lines.push(Model.plainText(service.warnings[i].message))
      return lines.join("\n")
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) service.refresh()
      else root.openWindow()
    }
  }
}
