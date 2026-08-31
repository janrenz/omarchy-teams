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

  // A picture being looked at full size, over everything else.
  property string viewerPath: ""

  function viewImage(path) {
    if (String(path || "") === "") return
    viewerPath = String(path)
    Qt.callLater(function() { viewerKeys.forceActiveFocus() })
  }

  function closeViewer() {
    viewerPath = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Escape unwinds one layer at a time, innermost first: the picture, then the
  // conversation, then the window. Anything else and Escape from a photograph
  // would shut the whole window.
  property bool composingNew: false

  function openNewChat() {
    if (!service.canStartChat) return
    service.clearPeople()
    composingNew = true
    Qt.callLater(function() { peopleField.forceActiveFocus() })
  }

  function closeNewChat() {
    composingNew = false
    service.clearPeople()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function dismiss() {
    if (composingNew) { closeNewChat(); return }
    if (viewerPath !== "") { closeViewer(); return }
    if (service.reading) { service.closeConversation(); return }
    requestClose()
  }

  // Only where there is something to type into. Focusing a composer that is
  // not on screen would take the keys away from the conversation list and give
  // them to nothing.
  function focusComposer() {
    if (!service.reading) return
    composer.forceActiveFocus()
  }

  // ---- scrolling by keyboard ---------------------------------------------
  //
  // Which pane the scroll keys act on: the transcript while a conversation is
  // open, otherwise the list. Whichever one the reader is looking at is the
  // one they mean, and it is the one the cursor is in.
  function scrollTarget() {
    if (service.reading && transcript.visible) return transcript
    return sidebarScroll.visible ? sidebarScroll : null
  }

  function scrollBy(view, dy) {
    var flick = view ? view.contentItem : null
    if (!flick) return
    // Any deliberate scroll means the reader has taken over, so stop dragging
    // them back to the newest message.
    if (view === transcript) transcript.followNewest = false
    var limit = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(limit, flick.contentY + dy))
  }

  function scrollToEnd(view, toBottom) {
    var flick = view ? view.contentItem : null
    if (!flick) return
    if (view === transcript) transcript.followNewest = toBottom === true
    flick.contentY = toBottom === true ? Math.max(0, flick.contentHeight - flick.height) : 0
  }

  // Keep the cursored row on screen. Without this, j walks the cursor off the
  // bottom of the list and there is no sign of where it went.
  function ensureVisible(view, itemY, itemHeight) {
    var flick = view ? view.contentItem : null
    if (!flick || itemHeight <= 0) return
    var margin = Style.spacing.lg
    if (itemY - margin < flick.contentY)
      flick.contentY = Math.max(0, itemY - margin)
    else if (itemY + itemHeight + margin > flick.contentY + flick.height)
      flick.contentY = Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height),
                                            itemY + itemHeight + margin - flick.height))
  }

  // Back to the conversation list, with the draft left exactly as it is. The
  // key catcher is stood down while the composer has focus - it claims bare
  // letters - so this is the only way back to the keyboard without the mouse.
  function leaveComposer() {
    keyCatcher.forceActiveFocus()
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

      // PanelKeyCatcher's vocabulary is Escape, Tab, the arrows, j/k/h/l and
      // Return; Page, Home and End are not in it and arrive here instead.
      // AfterItem so the catcher still gets first refusal on what it does know.
      Keys.priority: Keys.AfterItem
      Keys.onPressed: function(event) {
        // While a field has focus these belong to the text in it.
        if (composer.activeFocus || codeField.activeFocus) return
        if (root.viewerPath !== "" || root.composingNew) return
        var view = root.scrollTarget()
        if (!view) return
        var page = Math.max(Style.space(80), view.height * 0.9)
        var half = page / 2
        var control = (event.modifiers & Qt.ControlModifier) !== 0

        if (event.key === Qt.Key_PageDown) root.scrollBy(view, page)
        else if (event.key === Qt.Key_PageUp) root.scrollBy(view, -page)
        else if (event.key === Qt.Key_Home) root.scrollToEnd(view, false)
        else if (event.key === Qt.Key_End) root.scrollToEnd(view, true)
        // The vim pair, for hands already on the home row.
        else if (control && event.key === Qt.Key_D) root.scrollBy(view, half)
        else if (control && event.key === Qt.Key_U) root.scrollBy(view, -half)
        else if (control && event.key === Qt.Key_F) root.scrollBy(view, page)
        else if (control && event.key === Qt.Key_B) root.scrollBy(view, -page)
        else return
        event.accepted = true
      }

      // Starting a chat: type a name, pick a person.
      Item {
        id: newChat
        anchors.fill: parent
        visible: root.composingNew
        z: 90

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.96)

          MouseArea { anchors.fill: parent; onClicked: root.closeNewChat() }

          Column {
            anchors.centerIn: parent
            width: Math.min(Style.space(420), parent.width - Style.spacing.huge * 2)
            spacing: Style.spacing.md

            // Swallows clicks so picking inside the card does not dismiss it.
            MouseArea { anchors.fill: parent; z: -1 }

            Text {
              width: parent.width
              text: "New chat"
              textFormat: Text.PlainText
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            TextField {
              id: peopleField
              width: parent.width
              placeholderText: "Name or address"
              foreground: Color.foreground
              accent: Color.accent
              // Searched as you type, but not on every keystroke - the
              // directory is a network round trip.
              onTextChanged: peopleDebounce.restart()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.closeNewChat(); event.accepted = true }
              }
            }

            Timer {
              id: peopleDebounce
              interval: 300
              onTriggered: service.searchPeople(peopleField.text)
            }

            Row {
              spacing: Style.spacing.sm
              visible: service.peopleSearching || service.peopleError !== ""
                       || service.startingChat || service.startChatError !== ""

              Spinner {
                anchors.verticalCenter: parent.verticalCenter
                visible: service.peopleSearching || service.startingChat
                color: Color.accent
                dotSize: Style.space(4)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: newChat.width * 0.5
                visible: service.peopleError !== "" || service.startChatError !== ""
                text: service.startChatError !== "" ? service.startChatError : service.peopleError
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              width: parent.width
              visible: !service.peopleSearching && service.peopleQuery.length >= 2
                       && service.peopleResults.length === 0 && service.peopleError === ""
              text: "Nobody found"
              textFormat: Text.PlainText
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Column {
              width: parent.width
              spacing: Style.spacing.xxs

              Repeater {
                model: service.peopleResults

                delegate: Rectangle {
                  required property var modelData
                  width: parent ? parent.width : 0
                  implicitHeight: who.implicitHeight + Style.spacing.sm * 2
                  radius: Style.space(5)
                  color: pick.containsMouse
                    ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.1)
                    : "transparent"

                  Column {
                    id: who
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.xxs

                    Text {
                      width: parent.width
                      text: String(modelData.name || "")
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      color: Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      width: parent.width
                      visible: text !== ""
                      text: [String(modelData.address || ""), String(modelData.subtitle || "")]
                            .filter(function(part) { return part !== "" }).join("  ·  ")
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      color: Qt.darker(Color.foreground, 1.5)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  MouseArea {
                    id: pick
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !service.startingChat
                    onClicked: service.startChat([String(modelData.id)], "")
                  }
                }
              }
            }

            Text {
              width: parent.width
              text: "Esc to close"
              textFormat: Text.PlainText
              color: Qt.darker(Color.foreground, 1.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Over everything, and only when there is something to show. Its own key
      // handling, because the panel catcher below is covered while this is up.
      Item {
        id: viewer
        anchors.fill: parent
        visible: root.viewerPath !== ""
        z: 100

        FocusScope {
          id: viewerKeys
          anchors.fill: parent
          focus: viewer.visible

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace) {
              root.closeViewer()
              event.accepted = true
            } else if (event.key === Qt.Key_O) {
              // Still one keystroke away from a real image viewer, for
              // zooming, rotating, or saving it somewhere.
              Quickshell.execDetached(["xdg-open", root.viewerPath])
              event.accepted = true
            }
          }

          Rectangle {
            anchors.fill: parent
            // Not fully opaque: it should read as the picture being held up in
            // front of the conversation, not as a different screen.
            color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.94)

            MouseArea {
              anchors.fill: parent
              // Clicking the surround closes, the way every picture viewer
              // does. Clicking the picture itself does not.
              onClicked: root.closeViewer()
            }

            Image {
              id: fullPicture
              anchors.centerIn: parent
              source: root.viewerPath !== "" ? "file://" + root.viewerPath : ""
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              width: Math.min(implicitWidth, parent.width - Style.spacing.huge * 2)
              height: Math.min(implicitHeight, parent.height - Style.spacing.huge * 4)
              // Decoded to the size it is drawn at; these are camera photos and
              // the full thing is tens of megapixels.
              sourceSize.width: Math.round(parent.width)

              MouseArea { anchors.fill: parent }
            }

            Spinner {
              anchors.centerIn: parent
              visible: fullPicture.status === Image.Loading
              color: Color.accent
              dotSize: Style.space(5)
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.spacing.xxl
              text: "Esc to close · O to open in an image viewer"
              textFormat: Text.PlainText
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // Stands down whenever a field has focus: it consumes bare letters to
        // drive the cursor, which would eat them out of a message.
        blocked: composer.activeFocus || codeField.activeFocus
                 || peopleField.activeFocus || root.composingNew
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) conversations.moveCursor(dy)
          else if (dx > 0) root.focusComposer()
        }
        onActivateRequested: conversations.activateCursor()
        onCloseRequested: root.dismiss()
        // Tab is how most people expect to reach the box they type in; l and
        // the right arrow already do it, but only for those who knew.
        onTabRequested: root.focusComposer()
        onTextKey: function(text) {
          if (text === "r") service.reloadConversation()
        }

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
                visible: service.signedIn && service.canStartChat
                text: "New chat"
                bordered: true
                foreground: Color.accent
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: root.openNewChat()
              }

              // Said where it can be acted on: the sign-in predates
              // Chat.ReadWrite, so opening a chat leaves its dot lit.
              Button {
                visible: service.signedIn && !service.canMarkRead
                text: "Allow marking read…"
                tooltipText: "Sign in again so opening a chat clears its unread mark"
                bordered: true
                foreground: Qt.darker(Color.foreground, 1.4)
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.startLogin(service.wantChannels)
              }

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
              id: sidebarScroll
              width: columns.sidebarWidth
              height: columns.height
              visible: columns.showSidebar
                       && !(service.conversations.length === 0 && service.loading)
              clip: true

              ConversationList {
                id: conversations
                onCursorMoved: function(itemY, itemHeight) {
                  root.ensureVisible(sidebarScroll, itemY, itemHeight)
                }
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

                  // The newest message is at the bottom, so that is where a
                  // conversation should open and where it should be again
                  // after you send something - not scrolled back to whatever
                  // was said first.
                  //
                  // Following rather than scrolling once: the rows arrive
                  // before they have been laid out, so a single jump lands
                  // short of the end by however much the transcript is still
                  // about to grow. This keeps up until it settles, and lets go
                  // the moment the reader scrolls back for themselves.
                  property bool followNewest: true

                  function toNewest() {
                    var flick = transcript.contentItem
                    if (!flick) return
                    flick.contentY = Math.max(0, flick.contentHeight - flick.height)
                  }

                  Connections {
                    target: service
                    function onMessagesChanged() {
                      transcript.followNewest = true
                      Qt.callLater(transcript.toNewest)
                    }
                  }

                  Connections {
                    target: transcript.contentItem
                    // Dragged or flicked by hand, as opposed to moved by the
                    // line above.
                    function onMovementStarted() { transcript.followNewest = false }
                  }

                  Column {
                    width: transcript.width
                    spacing: Style.spacing.lg
                    onHeightChanged: if (transcript.followNewest) transcript.toNewest()

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
                          delegate: Column {
                            required property var modelData
                            width: parent ? parent.width : 0
                            spacing: Style.spacing.xs

                            SelectableText {
                              width: parent.width
                              visible: text !== ""
                              // Escaped first, then links added - so a message
                              // can never choose its own markup. Lines without
                              // a link stay plain text, which is cheaper and
                              // cannot be got wrong at all.
                              readonly property bool linked: Model.hasLink(modelData.text)
                              text: linked ? Model.linkify(modelData.text)
                                           : String(modelData.text || "")
                              onLinkActivated: function(url) { service.openUrl(url) }
                              HoverHandler {
                                enabled: parent.hoveredLink !== ""
                                cursorShape: Qt.PointingHandCursor
                              }
                              // Rendered as text, always. A Teams message is
                              // HTML written by whoever sent it, and rich text
                              // fetches what it is told to fetch. The emoji
                              // survive because teams.py turns each <emoji>
                              // tag into the character its alt already holds.
                              textFormat: linked ? TextEdit.RichText : TextEdit.PlainText
                              color: Color.foreground
                              font.family: Style.font.family
                              font.pixelSize: Style.font.bodySmall
                            }

                            Repeater {
                              model: modelData.images || []

                              delegate: MessageImage {
                                required property var modelData
                                url: String(modelData.url || "")
                                alt: String(modelData.alt || "")
                                intrinsicWidth: Number(modelData.width || 0)
                                intrinsicHeight: Number(modelData.height || 0)
                                account: service.alias
                                pluginDir: root.pluginDir
                                maxWidth: Math.min(Style.space(320), columns.readerWidth - Style.spacing.xxl)
                                onViewRequested: function(path) { root.viewImage(path) }
                              }
                            }
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
                      placeholderText: "Message — Shift+Enter to send"
                      wrapMode: TextArea.Wrap
                      color: Color.foreground
                      placeholderTextColor: Qt.darker(Color.foreground, 1.5)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      background: null
                      text: service.draft
                      onTextChanged: if (text !== service.draft) service.draft = text
                      // Enter is a newline; Shift+Enter sends, and Ctrl+Enter
                      // still does too for anyone with it in their fingers. A
                      // chat box that sends on Enter alone posts half-written
                      // thoughts.
                      //
                      // Escape and Tab hand the keyboard back to the
                      // conversation list, since the key catcher cannot hear
                      // anything while this has focus.
                      Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backtab
                            || event.key === Qt.Key_Tab) {
                          root.leaveComposer()
                          event.accepted = true
                          return
                        }
                        if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return
                        if (!(event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) return
                        service.send()
                        event.accepted = true
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
