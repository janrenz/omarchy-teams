import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The plugin's settings, in the window.
//
// The manifest declares a schema, and nothing in the shell renders one for a
// third-party widget - the only reference to it anywhere in the shell is the
// line that writes it into the registry. So the plugin brings its own form,
// the way the Office 365 plugin does.
//
// Edits are collected and written on Save rather than applied as they are
// typed: every keystroke in the client id would otherwise be a write to the
// file the whole shell reads, and a half-typed account name would send the
// service off to sign in as nobody.
Column {
  id: root

  property var service: null

  // What has been changed but not yet saved.
  property var pending: ({})
  readonly property bool dirty: Object.keys(pending).length > 0

  signal closeRequested()

  spacing: Style.spacing.lg

  function current(key, fallback) {
    if (pending[key] !== undefined) return pending[key]
    if (!service) return fallback
    var value = service.settings ? service.settings[key] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function change(key, value) {
    var next = {}
    for (var k in pending) next[k] = pending[k]
    next[key] = value
    pending = next
  }

  function discard() {
    pending = ({})
    root.closeRequested()
  }

  function save() {
    if (!service || !dirty) { root.closeRequested(); return }
    service.saveSettings(pending)
  }

  Connections {
    target: root.service
    // Cleared only once the write has actually landed, so a failed save keeps
    // what was typed rather than throwing it away and saying so.
    function onSettingsSaved() {
      root.pending = ({})
      root.closeRequested()
    }
  }

  // ---------------- the mailbox ----------------

  PanelSectionHeader { width: parent.width; text: "Account" }

  LabeledField {
    width: parent.width
    label: "Account name"
    placeholder: "work"
    hint: "A short name for this sign-in. Letters, numbers, dot, dash and underscore."
    value: String(root.current("account", ""))
    onEdited: function(value) { root.change("account", value) }
  }

  LabeledField {
    width: parent.width
    label: "Azure client id"
    placeholder: "00000000-0000-0000-0000-000000000000"
    hint: "Required. Your own app registration - Teams cannot reuse one made for mail. See the plugin's README."
    value: String(root.current("clientId", ""))
    onEdited: function(value) { root.change("clientId", value) }
  }

  LabeledField {
    width: parent.width
    label: "Authority"
    placeholder: "common"
    hint: "common, organizations, or your tenant id. A single-tenant registration needs the tenant."
    value: String(root.current("authority", ""))
    onEdited: function(value) { root.change("authority", value) }
  }

  Row {
    spacing: Style.spacing.sm
    visible: !!root.service && root.service.signedIn

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "Signed in as " + (root.service ? root.service.view.username : "")
      textFormat: Text.PlainText
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Button {
      text: "Sign in again"
      tooltipText: "Asks for the permissions this version needs, which an older sign-in may not carry"
      bordered: true
      foreground: Color.foreground
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      onClicked: {
        root.closeRequested()
        if (root.service) root.service.startLogin(root.service.wantChannels)
      }
    }
  }

  PanelSeparator { width: parent.width }

  // ---------------- what it shows ----------------

  PanelSectionHeader { width: parent.width; text: "Appearance" }

  Dropdown {
    width: Math.min(Style.space(260), parent.width)
    label: "Spacing"
    options: Model.densityNames()
    value: String(root.current("density", "cosy"))
    onValueChanged: if (value !== root.current("density", "cosy")) root.change("density", value)
  }

  NumberField {
    label: "Chats to list"
    from: 1
    to: 40
    stepSize: 1
    value: parseInt(String(root.current("chats", 25)), 10) || 25
    onValueChanged: if (value !== parseInt(String(root.current("chats", 25)), 10))
      root.change("chats", value)
  }

  NumberField {
    label: "Refresh every (seconds)"
    from: 30
    to: 3600
    stepSize: 30
    value: parseInt(String(root.current("refreshIntervalSec", 120)), 10) || 120
    onValueChanged: if (value !== parseInt(String(root.current("refreshIntervalSec", 120)), 10))
      root.change("refreshIntervalSec", value)
  }

  Toggle {
    width: parent.width
    label: "Stop polling while you are away"
    description: "A poll is also a token refresh, and Graph counts every one of them. Nothing is asked of the server while the screen has been idle five minutes or the machine has no network, and a fetch goes out the moment you come back or reconnect. Anything you ask for by hand still goes out. On battery the interval is doubled, and tripled in the power-saver profile."
    checked: root.current("pausePolling", true) !== false
    onClicked: root.change("pausePolling", !(root.current("pausePolling", true) !== false))
  }

  LabeledField {
    width: Math.min(Style.space(260), parent.width)
    label: "Bar label"
    placeholder: "leave empty for the icon"
    hint: "Short text shown in the bar instead of the glyph."
    value: String(root.current("label", ""))
    onEdited: function(value) { root.change("label", value) }
  }

  Toggle {
    width: parent.width
    label: "Highlight the bar icon when a chat is unread"
    checked: root.current("tintOnUnread", true) !== false
    onClicked: root.change("tintOnUnread", !(root.current("tintOnUnread", true) !== false))
  }

  Toggle {
    width: parent.width
    label: "Notify when a new message arrives"
    description: "A desktop notification per chat with something new in it. What was already waiting when the shell started is not announced, and neither is anything you sent yourself."
    checked: root.current("notify", true) !== false
    onClicked: root.change("notify", !(root.current("notify", true) !== false))
  }

  Toggle {
    width: parent.width
    label: "Hand a conversation to your coding agent"
    description: "The a key and the Ask agent button, which open the agent you chose with `omarchy default agent` on the chat or channel you are reading. It is told which conversation to read and reads it through teams.py; no message text is put on a command line. Off also refuses a draft an agent tries to hand back."
    checked: root.current("agentHandover", true) !== false
    onClicked: root.change("agentHandover", !(root.current("agentHandover", true) !== false))
  }

  PanelSeparator { width: parent.width }

  // ---------------- what it fetches ----------------

  PanelSectionHeader { width: parent.width; text: "Teams and channels" }

  Toggle {
    width: parent.width
    label: "Include teams and channels"
    description: "Off signs in for chats alone. On also asks for channel access, which normally needs an administrator to consent for the whole tenant."
    checked: root.current("channels", true) !== false
    onClicked: root.change("channels", !(root.current("channels", true) !== false))
  }

  Toggle {
    width: parent.width
    label: "Send files"
    description: "An Attach button in a chat, and a file dropped on the window. The file goes to your own OneDrive first - into the same folder Teams itself uses - and the message points at it, which is how Teams does it. Needs Files.ReadWrite on your app registration; turn this on only once it has that permission, because a scope the registration does not declare fails the whole sign-in rather than just itself. Takes effect at the next sign-in."
    checked: root.current("sendFiles", false) === true
    onClicked: root.change("sendFiles", !(root.current("sendFiles", false) === true))
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.signedIn && root.service.wantFiles
             && !root.service.canUpload
    text: "This sign-in cannot send files yet. Sign in again to ask for Files.ReadWrite."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.signedIn && !root.service.hasChannels
    text: "This sign-in has no channel access. Turning this on takes effect at the next sign-in."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(Color.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  PanelSeparator { width: parent.width }

  // ---------------- saving ----------------

  Text {
    width: parent.width
    visible: !!root.service && root.service.saveError !== ""
    text: root.service ? root.service.saveError : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Row {
    spacing: Style.spacing.sm

    Button {
      enabled: root.dirty && !(root.service && root.service.saving)
      text: root.service && root.service.saving ? "Saving…" : "Save"
      bordered: true
      foreground: root.dirty ? Color.accent : Qt.darker(Color.foreground, 1.6)
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      onClicked: root.save()
    }

    Button {
      text: root.dirty ? "Discard" : "Close"
      bordered: true
      foreground: Color.foreground
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      onClicked: root.discard()
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.dirty
      text: Object.keys(root.pending).length + " unsaved"
      textFormat: Text.PlainText
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
