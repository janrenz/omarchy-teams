import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Teams window: conversations on the left, the transcript on the right,
// and a box to answer in at the bottom of it.
//
// A real Hyprland toplevel, hosted by the shell because the manifest declares
// the "panel" kind. Summon it with:
//   omarchy-shell shell toggle janrenz.omarchy.teams
Item {
  id: root

  readonly property string pluginId: "janrenz.omarchy.teams"

  // ---- host injections ----------------------------------------------------
  property var shell: null
  property var manifest: null

  property bool closingFromHost: false

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
    return decodeURIComponent(url.replace(/\/$/, ""))
  }

  // Deliberately not called `service`: the shell assigns that name on every
  // panel it loads and would overwrite it with null for a plugin that declares
  // no service kind.
  readonly property alias teamsService: service

  function open(_payloadJson) {
    closingFromHost = false
    loadSettings()
    window.visible = true
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  // ---- the widget's settings ----------------------------------------------
  // The window is one per plugin and the widget owns the configuration, so the
  // window reads it out of shell.json rather than having any of its own.
  property var settings: ({})
  property bool settingsLoaded: false
  property string settingsError: ""

  function loadSettings() {
    if (configProc.running || pluginDir === "") return
    configProc.command = ["python3", pluginDir + "/config.py", "--plugin-id", root.pluginId, "--list"]
    configProc.running = true
  }

  Process {
    id: configProc
    running: false
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.settingsLoaded = true
      if (exitCode !== 0) {
        root.settingsError = Model.oneLine(configErr.text || "Could not read the bar layout", 160)
        return
      }
      var parsed = Model.parseJson(configOut.text, null)
      if (!parsed || parsed.ok === false) {
        root.settingsError = "Could not read the bar layout"
        return
      }
      var widgets = parsed.widgets || []
      if (widgets.length === 0) {
        root.settingsError = "No Teams widget in the bar. Add one and give it an account name and client id."
        return
      }
      root.settingsError = ""
      root.settings = widgets[0].settings || {}
    }
  }

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
  }

  // ---- keyboard -----------------------------------------------------------
  property string pane: "list"
  readonly property bool typing: service.reading

  function dismiss() {
    if (service.reading) { service.closeConversation(); return }
    requestClose()
  }

  FloatingWindow {
    id: window
    title: service.openConversation
      ? ("Teams — " + String(service.openConversation.title || ""))
      : "Teams"
    color: Color.background
    implicitWidth: 1080
    implicitHeight: 720
    minimumSize: Qt.size(640, 420)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // Stands down whenever a field has focus: it consumes bare letters to
        // drive the cursor, which would eat them out of a message.
        blocked: composer.activeFocus || codeField.activeFocus
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) conversations.moveCursor(dy)
          else if (dx > 0) composer.forceActiveFocus()
        }
        onActivateRequested: conversations.activateCursor()
        onCloseRequested: root.dismiss()

        Column {
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.spacing.panelGap

          // ---------------- header ----------------
          Item {
            width: parent.width
            height: heading.implicitHeight

            Row {
              id: heading
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.md

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: service.openConversation ? String(service.openConversation.title || "") : "Teams"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }

              Spinner {
                anchors.verticalCenter: parent.verticalCenter
                visible: service.loading || service.messagesLoading
                color: Color.accent
                dotSize: Style.space(4)
              }

              // Only for the first fetch, which is the slow one: it reads the
              // whole team tree. Later refreshes are a second and need no
              // explaining, and a line of text appearing every couple of
              // minutes would push the header around.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: service.loading && !service.signedIn
                text: "loading chats and teams…"
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // Said once, plainly, rather than on every channel that is not
              // there: without the admin grant there are no channels to show.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: service.signedIn && !service.hasChannels
                text: "chats only"
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              Button {
                visible: service.signedIn && !service.hasChannels
                text: "Add channels…"
                tooltipText: "Sign in again asking for team and channel access. Needs an administrator to consent."
                bordered: true
                foreground: Qt.darker(Color.foreground, 1.4)
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.startLogin(true)
              }

              Button {
                visible: service.configured
                enabled: !service.loading
                text: "Refresh"
                bordered: true
                foreground: Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.refreshEverything()
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---------------- not ready yet ----------------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.settingsError !== "" || !service.configured
                     || service.needsSignIn || service.loggingIn

            Text {
              width: parent.width
              visible: root.settingsError !== ""
              text: root.settingsError
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            // The client id is the one thing nobody can do for the user: an
            // Azure app registration declares which permissions it may request,
            // so a registration made for mail cannot ask for Chat.Read.
            Text {
              width: parent.width
              visible: root.settingsError === "" && !service.configured && root.settingsLoaded
              text: "Teams needs its own Azure app registration. Create a public-client "
                    + "registration with device-code flow enabled, add the Microsoft Graph "
                    + "delegated permissions listed in the plugin's README, then put its "
                    + "client id and an account name into this widget's settings."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Row {
              spacing: Style.spacing.sm
              visible: service.configured && service.needsSignIn && !service.loggingIn

              Button {
                text: "Sign in"
                bordered: true
                foreground: Color.accent
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.startLogin(service.wantChannels)
              }

              Button {
                visible: service.wantChannels
                text: "Sign in for chats only"
                tooltipText: "Skips the team and channel permissions, which need an administrator"
                bordered: true
                foreground: Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.startLogin(false)
              }
            }

            // The device code. Selectable, because it has to be typed into a
            // browser and retyping from memory is how it expires.
            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: service.loggingIn

              Text {
                width: parent.width
                text: service.loginMessage
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              TextField {
                id: codeField
                width: Style.space(220)
                visible: service.userCode !== ""
                text: service.userCode
                readOnly: true
                foreground: Color.accent
                accent: Color.accent
              }

              Row {
                spacing: Style.spacing.sm

                Button {
                  visible: service.verificationUri !== ""
                  text: "Open the sign-in page"
                  bordered: true
                  foreground: Color.accent
                  fontFamily: Style.font.family
                  fontSize: Style.font.caption
                  onClicked: service.openUrl(service.verificationUri)
                }

                Button {
                  text: "Cancel"
                  bordered: true
                  foreground: Qt.darker(Color.foreground, 1.4)
                  fontFamily: Style.font.family
                  fontSize: Style.font.caption
                  onClicked: service.cancelLogin()
                }
              }
            }
          }

          // ---------------- the two columns ----------------
          Row {
            id: columns
            width: parent.width
            height: parent.height - y
            spacing: Style.spacing.xxl
            // Drawn during the first fetch too, so the placeholder rows below
            // stand where the real ones will be. Before this the window was
            // simply blank for the length of the fetch, which read as broken.
            visible: (service.signedIn || service.loading) && !service.loggingIn
                     && root.settingsError === "" && service.configured && !service.needsSignIn

            // A tiling compositor hands this window whatever the layout has
            // left - 672px here - and Style.space() scales with the font, so a
            // fixed "is there room for two columns" threshold is easily missed.
            // When there is not room for both, show the one that is any use:
            // the list until a conversation is picked, the transcript after.
            // Escape goes back. Hiding the list and leaving an empty reader,
            // which is what this did, left nothing to click at all.
            readonly property bool roomForBoth: width >= Style.space(560)
            readonly property bool showSidebar: roomForBoth || !service.reading
            readonly property bool showReader: roomForBoth || service.reading
            readonly property real sidebarWidth: !showSidebar ? 0
              : (roomForBoth ? Math.max(Style.space(200), Math.min(Style.space(320), width * 0.28))
                             : width)
            readonly property real readerWidth: !showReader ? 0
              : (roomForBoth ? width - sidebarWidth - spacing * 2 - Style.space(1) : width)

            // Nothing fetched yet. Rows rather than a spinner: they hold the
            // sidebar at the size it is about to have, so the list does not
            // shove the layout around when it lands.
            LoadingRows {
              width: columns.sidebarWidth
              visible: columns.showSidebar && service.conversations.length === 0 && service.loading
              rows: 7
              fg: Color.foreground
            }

            ScrollView {
              width: columns.sidebarWidth
              height: columns.height
              visible: columns.showSidebar
                       && !(service.conversations.length === 0 && service.loading)
              clip: true

              ConversationList {
                id: conversations
                width: columns.sidebarWidth
                rows: service.conversations
                selectedKey: service.openConversation ? String(service.openConversation.key) : ""
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onPicked: function(row) {
                  if (row.kind === "team") service.toggleTeam(row.id)
                  else service.openChat(row)
                }
              }
            }

            Rectangle {
              width: Style.space(1)
              height: columns.height
              visible: columns.roomForBoth
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
            }

            Item {
              width: columns.readerWidth
              height: columns.height
              visible: columns.showReader

              Text {
                anchors.centerIn: parent
                width: parent.width - Style.spacing.xxl
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                visible: columns.roomForBoth && !service.reading
                text: service.conversations.length === 0
                  ? "Nothing here yet" : "Pick a conversation"
                textFormat: Text.PlainText
                color: Qt.darker(Color.foreground, 1.8)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Column {
                anchors.fill: parent
                spacing: Style.spacing.md
                visible: service.reading

                Text {
                  width: parent.width
                  visible: service.messagesError !== ""
                  text: service.messagesError
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                LoadingRows {
                  width: parent.width
                  visible: service.messagesLoading && service.messages.length === 0
                  rows: 5
                  fg: Color.foreground
                }

                ScrollView {
                  id: transcript
                  width: parent.width
                  visible: !(service.messagesLoading && service.messages.length === 0)
                  height: parent.height - composerBox.height - answer.height - parent.spacing * 2
                          - (service.messagesError !== "" ? Style.space(20) : 0)
                  clip: true

                  Column {
                    width: transcript.width
                    spacing: Style.spacing.lg

                    Repeater {
                      model: Model.groupMessages(service.messages, service.view.userId)

                      delegate: Column {
                        required property var modelData
                        width: parent ? parent.width : 0
                        spacing: Style.spacing.xxs

                        Text {
                          width: parent.width
                          visible: !modelData.system
                          text: String(modelData.from || "") + "  "
                                + Model.whenLabel(modelData.when, new Date())
                          textFormat: Text.PlainText
                          elide: Text.ElideRight
                          color: modelData.mine ? Color.accent : Qt.darker(Color.foreground, 1.4)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }

                        Repeater {
                          model: modelData.lines

                          // Selectable: the whole point of a transcript is
                          // that you can take a line out of it. A plain Text
                          // item cannot be selected at all.
                          delegate: SelectableText {
                            required property var modelData
                            width: parent ? parent.width : 0
                            text: String(modelData.text || "")
                            // Rendered as text, always. A Teams message is
                            // HTML written by whoever sent it, and rich text
                            // fetches what it is told to fetch.
                            textFormat: TextEdit.PlainText
                            color: Color.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                          }
                        }
                      }
                    }
                  }
                }

                // ---------------- answering ----------------
                Rectangle {
                  id: composerBox
                  width: parent.width
                  height: Style.space(84)
                  radius: Style.space(5)
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                  border.width: Style.space(1)
                  border.color: composer.activeFocus
                    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
                    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

                  ScrollView {
                    anchors.fill: parent
                    anchors.margins: Style.spacing.sm
                    clip: true

                    TextArea {
                      id: composer
                      placeholderText: "Message — Ctrl+Enter to send"
                      wrapMode: TextArea.Wrap
                      color: Color.foreground
                      placeholderTextColor: Qt.darker(Color.foreground, 1.5)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      background: null
                      text: service.draft
                      onTextChanged: if (text !== service.draft) service.draft = text
                      // Enter is a newline; Ctrl+Enter sends. A chat box that
                      // sends on Enter posts half-written thoughts.
                      Keys.onPressed: function(event) {
                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            && (event.modifiers & Qt.ControlModifier)) {
                          service.send()
                          event.accepted = true
                        }
                      }
                    }
                  }
                }

                Row {
                  id: answer
                  spacing: Style.spacing.sm

                  Button {
                    enabled: !service.sending && service.draft.trim() !== ""
                    text: service.sending ? "Sending…" : "Send"
                    bordered: true
                    foreground: Color.accent
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    onClicked: service.send()
                  }

                  Button {
                    enabled: !service.messagesLoading
                    text: "Reload"
                    bordered: true
                    foreground: Color.foreground
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    onClicked: service.reloadConversation()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: service.sendError !== ""
                    text: service.sendError
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Color.urgent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
