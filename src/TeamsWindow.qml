import QtQuick
import QtCore
import QtQuick.Controls
import QtQuick.Dialogs
import Quickshell
import Quickshell.Hyprland
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
  // The toplevel itself, so a harness can photograph what this draws without
  // the shell in the way. Nothing in the plugin uses it.
  readonly property alias floatingWindow: window

  function open(payloadJson) {
    closingFromHost = false
    loadSettings()
    // Remembered before the payload is applied, because applying one opens a
    // conversation and the conversation is in the window's title - a moment
    // later Hyprland still knows this window by the name it had here.
    var knownAs = window.visible ? String(window.title) : ""
    var payload = Model.parseJson(payloadJson, null)
    if (payload) applyPayload(payload)
    window.visible = true
    focusToplevel(knownAs)
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Bring an already-open window to the front, on the workspace somebody is
  // actually looking at.
  //
  // `window.visible = true` on a window that is already visible does nothing
  // at all - no raise, no workspace switch, no keyboard focus - so opening
  // Teams while its window sat on another workspace looked exactly like the
  // click had been swallowed. Qt's forceActiveFocus below only moves focus
  // around *inside* the window; the compositor has to be asked separately.
  //
  // An empty name means the window was not mapped a moment ago, and a window
  // Hyprland is about to see for the first time is focused by Hyprland itself.
  function focusToplevel(knownAs) {
    if (String(knownAs) === "") return
    var all = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < all.length; i++) {
      // Matched on the title because a client cannot ask which toplevel is its
      // own. It is this file's own string rather than a guess at the shape of
      // somebody else's window, so the match is exact and stays exact.
      if (all[i] && String(all[i].title) === String(knownAs)) {
        dispatchFocus(all[i])
        return
      }
    }
  }

  function dispatchFocus(toplevel) {
    var matcher = "address:0x" + toplevel.address
    // Two syntaxes, because this plugin is not installed on one machine only.
    // Hyprland takes a Lua expression now and rejects the classic string form
    // outright - `focuswindow address:0x...` comes back "')' expected near
    // 'address'" - while the releases before it take only the string.
    Hyprland.dispatch(Hyprland.usingLua === true
                      ? "hl.dsp.focus({ window = '" + matcher + "' })"
                      : "focuswindow " + matcher)
  }

  // What the shell may deliver with a summon: a conversation to show - a
  // clicked notification, `chat` for a chat or `team` plus `channel` for a
  // channel - and a draft a coding agent wrote. Both have to survive being
  // applied twice, because the payload queue is drained in a loop and a toast
  // clicked while the window is already open arrives here too; and neither may
  // throw away a draft being written into the conversation already on screen.
  function applyPayload(payload) {
    var chat = String(payload.chat || "")
    var channel = String(payload.channel || "")
    if (chat !== "" || channel !== "") {
      service.openByIds(chat, String(payload.team || ""), channel,
                        String(payload.title || ""))
      var message = String(payload.message || "")
      if (message !== "") {
        cursorMessageId = message
        focusPane = "conversation"
      }
    }
    if (payload.draft) {
      agentDraftPending = payload.draft
      flushAgentDraft()
    }
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
  // A draft that came in before the settings did has been waiting for them.
  onSettingsChanged: flushAgentDraft()
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
  //
  // Omarchy is keyboard-first, so this is a focus ladder rather than a handful
  // of shortcuts: list -> conversation -> message box, with h and l moving
  // between them and Escape walking back out one rung at a time. j and k
  // always mean "down and up in whatever has focus", which is the thing that
  // was missing - they used to drive the list even while you were reading.
  //
  // "list" or "conversation". The message box is a real focus, so it is asked
  // rather than tracked.
  property string focusPane: "list"
  property bool showHelp: false

  // The status menu, open only while somebody is choosing. Not a pane in the
  // focus ladder: it is over the window, takes the digits while it is up, and
  // Escape closes it before anything else.
  property bool pickingPresence: false

  function togglePresencePicker() {
    if (!service.canSetPresence) return
    // Asked for lazily as well as at start-up: the window may have been built
    // before the account was configured, and a picker with no rows in it is
    // not worth opening.
    service.loadPresenceChoices()
    pickingPresence = !pickingPresence
  }

  // The digits, routed to the picker itself - which is where the row order
  // lives, and knows that row 0 is Automatic. The bar's dropdown routes its
  // digits to its own copy the same way.
  function presenceAt(index) {
    menu.pickAt(index)
  }

  readonly property bool typing: composer.activeFocus

  // The list that is actually on screen: narrow, that is the drawer's copy.
  function activeList() {
    return listDrawerOpen ? drawerList : conversations
  }

  function focusList() {
    focusPane = "list"
    // Narrow, the list is not on screen at all - bringing it out is what
    // "go back to the list" has to mean there.
    if (!columns.roomForBoth && service.reading) listDrawerOpen = true
    keyCatcher.forceActiveFocus()
  }

  function focusConversation() {
    if (!service.reading) return
    focusPane = "conversation"
    listDrawerOpen = false
    keyCatcher.forceActiveFocus()
  }

  // How much of the transcript's right edge its scrollbar covers. The bar is
  // drawn over the content, not beside it, so anything anchored right has to
  // step in by this much or it sits under a bar that takes the pointer first.
  readonly property real scrollGutter: {
    var bar = transcript.ScrollBar.vertical
    return bar ? bar.width : 0
  }

  // One line of the transcript, near enough, for the scroll keys.
  readonly property int lineStep: Math.max(Style.space(18), Style.font.bodySmall * 2)

  // ---- the message the keyboard is on -------------------------------------
  //
  // Reacting had no keyboard at all: the transcript was scrolled rather than
  // walked, so there was never a message the keys were "on" and nothing for a
  // reaction key to act upon. In a keyboard-first shell that is backwards -
  // the mouse could react and the keyboard could not.
  //
  // Held by id, not by index. The transcript is re-read underneath this - a
  // refresh, a message sent, somebody else's arriving - and an index would
  // quietly come to mean a different message than the one it was put on.
  property string cursorMessageId: ""
  // Whose picker is open, at most one at a time. Owned here rather than by
  // each row so that opening one closes the last, and so the keyboard and the
  // mouse are opening the same thing.
  property string pickingMessageId: ""

  // A file:// URL from either route - the chooser or a drop - as the path the
  // helper wants. decodeURIComponent because a space arrives as %20.
  function sendFile(fileUrl) {
    var url = String(fileUrl || "").trim()
    if (url === "") return
    // A drag carries whatever had a URL. A link dragged out of a browser is
    // still text/uri-list, and a path that was never a path is a confusing way
    // for the helper to fail - so it is turned away here, by name.
    if (url.indexOf("file://") !== 0 && url.charAt(0) !== "/") {
      service.uploadError = "Only a file on this machine can be sent, not a link"
      return
    }
    var path = decodeURIComponent(url.replace(/^file:\/\//, ""))
    if (path === "") return
    service.uploadFile(path)
  }

  // ---- the picture being looked at ----------------------------------------
  //
  // A layer of the window rather than a handoff. Empty when nothing is open.
  property string viewingImagePath: ""
  property string viewingImageAlt: ""
  readonly property bool viewingImage: viewingImagePath !== ""

  function viewImage(path, alt) {
    if (!path) return
    viewingImagePath = String(path)
    viewingImageAlt = String(alt || "")
  }

  function closeImage() {
    viewingImagePath = ""
    viewingImageAlt = ""
  }

  function messageById(id) {
    var list = service.messages
    for (var i = 0; i < list.length; i++)
      if (String(list[i].id) === String(id)) return list[i]
    return null
  }

  function messageIndex(id) {
    var list = service.messages
    for (var i = 0; i < list.length; i++)
      if (String(list[i].id) === String(id)) return i
    return -1
  }

  // j and k walk the transcript a message at a time. The first press starts at
  // the newest, which is what is on screen and what a conversation opens on.
  function moveMessageCursor(step) {
    var list = service.messages
    if (list.length === 0) { cursorMessageId = ""; return }
    // Walking away from the bottom is taking over from the follow-the-newest
    // behaviour, the same as scrolling by hand is.
    transcript.followNewest = false
    var at = messageIndex(cursorMessageId)
    var next = at < 0 ? list.length - 1 : Math.max(0, Math.min(list.length - 1, at + step))
    cursorMessageId = String(list[next].id || "")
    // Moving the cursor is not the moment to keep a half-open picker from the
    // message being left behind.
    pickingMessageId = ""
  }

  // Open the picker on the message under the cursor, putting the cursor on the
  // newest first if it is not anywhere yet - pressing e straight after opening
  // a conversation should react to the message you are looking at.
  function startPicking() {
    if (!service.reading) return
    if (cursorMessageId === "" || messageIndex(cursorMessageId) < 0) {
      var list = service.messages
      if (list.length === 0) return
      cursorMessageId = String(list[list.length - 1].id || "")
    }
    focusPane = "conversation"
    pickingMessageId = pickingMessageId === cursorMessageId ? "" : cursorMessageId
  }

  // The nth choice, by number, because six of them numbered is faster than six
  // of them arrowed through.
  function reactWith(index) {
    var choices = service.reactionChoices
    if (index < 0 || index >= choices.length) return
    var row = messageById(pickingMessageId)
    if (!row) return
    var emoji = String(choices[index].emoji || "")
    if (emoji === "") return
    pickingMessageId = ""
    // Pressing the one you already gave takes it back, the same as clicking
    // the chip does.
    service.react(row.id, emoji, Model.reactionIsMine(row.reactions, emoji))
  }

  // Spacing, as properties rather than service.pad() calls inside each
  // binding: a binding that reaches its dependency through a function call
  // does not reliably re-run when that dependency changes.
  readonly property real densityScale: service.densityScale
  // Vertical only. Spacing is about how much air there is between things you
  // read down a list; widening the left and right margins just takes width
  // away from the words, which is the opposite of roomy.
  readonly property int padPanel: Math.max(1, Math.round(Style.spacing.panelPadding * densityScale))
  readonly property int padGap: Math.max(1, Math.round(Style.spacing.panelGap * densityScale))
  readonly property int padMessages: Math.max(1, Math.round(Style.spacing.lg * densityScale))
  readonly property int padLines: Math.max(1, Math.round(Style.spacing.xs * densityScale))
  readonly property int padReading: Math.max(1, Math.round(Style.spacing.md * densityScale))

  // The corner mark. This window and the Slack one are the same shape, the
  // same kit and usually the same size, so nothing on screen said which of
  // the two you had just summoned. The app's own glyph, in the app's own
  // colour, where a title bar would carry its icon, says it at a glance.
  readonly property color brandColor: "#5B5FC7"
  readonly property int markSize: Math.round(Style.font.heading + Style.spacing.md * 2)

  // The list's marker column - the unread dot and the team chevron. It comes
  // out of the panel's left padding rather than out of the rows, so CHATS,
  // every chat name and the window title all begin on the same line. Taken
  // out of the rows, as it was, it pushed the whole list a clear step right
  // of the title with nothing but a 6px dot to show for it. Unscaled, for the
  // reason rowIndent is unscaled: this is a column, not breathing room.
  readonly property int listGutter: Style.spacing.md + Style.space(10)

  property bool showSettings: false
  property bool composingNew: false

  // ---- the coding agent ---------------------------------------------------
  //
  // Omarchy's own handover, pointed at a conversation: omarchy-agent starts
  // whichever agent was chosen with `omarchy default agent`, and handover.sh
  // writes the prompt. Nothing anybody said goes into that prompt - the agent
  // is told which conversation to read and reads it through teams.py, the same
  // helper this window uses. src/handover.sh says why.
  //
  // Split in two so the fixtures can be checked without an agent starting.
  // Empty means there is nothing to hand over, or the setting says not to.
  function agentArgv() {
    if (!service.agentHandover || !service.reading) return []
    var conversation = service.openConversation
    if (!conversation) return []
    var argv = [pluginDir + "/handover.sh",
                "--account", service.alias,
                "--title", String(conversation.title || "")]
    if (String(conversation.kind) === "chat")
      argv = argv.concat(["--chat", String(conversation.id)])
    else
      argv = argv.concat(["--team", String(conversation.teamId),
                          "--channel", String(conversation.id)])
    // The message under the cursor, or the newest when the cursor is not
    // anywhere yet - the same fallback the reaction picker makes.
    var id = String(cursorMessageId)
    if (id === "" || messageIndex(id) < 0) {
      var list = service.messages
      id = list.length > 0 ? String(list[list.length - 1].id || "") : ""
    }
    if (id !== "") argv = argv.concat(["--message", id])
    return argv
  }

  function askAgent() {
    var argv = agentArgv()
    if (argv.length === 0) return
    Quickshell.execDetached(argv)
  }

  // A draft an agent wrote, arriving from outside:
  //   omarchy-shell shell summon janrenz.omarchy.teams '{"draft":{...}}'
  //   omarchy-shell shell call   janrenz.omarchy.teams agentDraft '{...}'
  // It lands in the message box, focused and unsent. Sending stays a keypress
  // a person makes, which is the whole reason this is a draft and not a send.
  property var agentDraftPending: null

  function agentDraft(argJson) {
    var payload = Model.parseJson(argJson, null)
    if (!payload) return "bad-json"
    agentDraftPending = payload.draft ? payload.draft : payload
    return flushAgentDraft()
  }

  // Held rather than applied when it arrives before the settings do: the
  // setting is what says whether a draft may be taken at all, and on the first
  // open it is still being read out of shell.json.
  function flushAgentDraft() {
    if (!agentDraftPending) return "ok"
    if (!settingsLoaded) return "waiting"
    if (!service.agentHandover) { agentDraftPending = null; return "off" }
    var draft = agentDraftPending
    agentDraftPending = null
    var text = String(draft.text || "")
    if (text === "") return "empty"
    service.openByIds(String(draft.chat || ""), String(draft.team || ""),
                      String(draft.channel || ""), String(draft.title || ""))
    // Nowhere to put it. Better to say so to whoever called than to drop the
    // text into a window that is not reading anything.
    if (!service.reading) return "no-conversation"
    service.draft = text
    focusPane = "conversation"
    Qt.callLater(function() { root.focusComposer() })
    return "ok"
  }

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

  // The conversation list, over the transcript, for when the window is too
  // narrow to show both at once.
  property bool listDrawerOpen: false

  function toggleListDrawer() {
    listDrawerOpen = !listDrawerOpen
    if (listDrawerOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Escape unwinds one layer at a time, innermost first. A picture is not in
  // this list: it opens in its own window, so closing that closes the picture
  // and leaves Teams alone.
  // Escape walks back out one rung at a time, and never further than one.
  function dismiss() {
    // Outermost layer on screen, so the first thing Escape takes back.
    if (viewingImage) { closeImage(); return }
    if (showHelp) { showHelp = false; return }
    if (pickingPresence) { pickingPresence = false; return }
    if (composingNew) { closeNewChat(); return }
    if (showSettings) { showSettings = false; return }
    if (pickingMessageId !== "") { pickingMessageId = ""; return }
    if (composer.activeFocus) { leaveComposer(); return }
    if (listDrawerOpen) { listDrawerOpen = false; focusPane = "list"; return }
    // Back to the list with the conversation still open, which is the step
    // that was missing: Escape used to close the conversation outright.
    if (focusPane === "conversation") { focusPane = "list"; return }
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
    if (listDrawerOpen) return drawerScroll
    if (focusPane === "conversation" && service.reading && transcript.visible) return transcript
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
    focusPane = "conversation"
    keyCatcher.forceActiveFocus()
  }

  // The toplevel list is only as fresh as the last event Hyprland sent, and a
  // shell that has just started has had none. Ask once, so the first summon at
  // an already-open window has something to match against.
  Component.onCompleted: Hyprland.refreshToplevels()

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

    // Sending a file. QtQuick.Dialogs is already how ImageViewer.qml saves one
    // out, and this is its opposite number - a real file chooser, because what
    // people send in a chat is as often a log or a PDF as a screenshot.
    FileDialog {
      id: attachDialog
      title: "Send a file to " + (service.openConversation
        ? String(service.openConversation.title || "this chat") : "this chat")
      fileMode: FileDialog.OpenFile
      currentFolder: StandardPaths.writableLocation(StandardPaths.DownloadLocation)
      onAccepted: root.sendFile(selectedFile)
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      // Drop a file anywhere in the window and it goes to the chat on screen.
      // Anywhere, rather than on the transcript alone: aiming at a scrolling
      // list is a worse target than a window, and there is only ever one
      // conversation open to mean. Channels are not offered - see uploadFile.
      // Deliberately not switched off when the sign-in cannot send files, when
      // nothing is open, or when what is open is a channel. A window that
      // ignores a drop looks broken: this way the overlay says which of those
      // it is while the file is still in the air, and uploadFile() says it
      // again on the line under the composer.
      DropArea {
        id: fileDrop
        anchors.fill: parent
        keys: ["text/uri-list"]

        // Empty when a drop would go through. Otherwise why it would not.
        readonly property string refusal: {
          if (!service.openConversation) return "Open a chat to send a file into"
          if (String(service.openConversation.kind || "") !== "chat")
            return "Files can go into a chat, not into a channel"
          if (!service.canUpload) return "This sign-in cannot send files - see Settings"
          if (service.uploading) return "Still sending the last file"
          return ""
        }

        onDropped: function(drop) {
          if (!drop.hasUrls || drop.urls.length === 0) return
          // One at a time: each is three requests, and a folder of forty
          // dropped by accident is not something to find out about halfway
          // through.
          root.sendFile(drop.urls[0])
          drop.acceptProposedAction()
        }

        Rectangle {
          readonly property color tint: fileDrop.refusal === "" ? Color.accent : Color.urgent

          anchors.fill: parent
          visible: parent.containsDrag
          color: Util.alpha(tint, 0.08)
          border.color: tint
          border.width: Math.max(1, Style.space(2))
          radius: Style.cornerRadius
          z: 500

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.spacing.xl * 2
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: fileDrop.refusal !== "" ? fileDrop.refusal
                  : ("Drop to send to " + (service.openConversation
                     ? String(service.openConversation.title || "") : ""))
            textFormat: Text.PlainText
            color: parent.tint
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
      }

      // PanelKeyCatcher's vocabulary is Escape, Tab, the arrows, j/k/h/l and
      // Return; Page, Home and End are not in it and arrive here instead.
      // AfterItem so the catcher still gets first refusal on what it does know.
      Keys.priority: Keys.AfterItem
      Keys.onPressed: function(event) {
        // While a field has focus these belong to the text in it.
        if (composer.activeFocus || codeField.activeFocus) return
        if (root.composingNew) return
        var view = root.listDrawerOpen ? drawerScroll : root.scrollTarget()
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

      // The conversation list as a layer over the transcript.
      //
      // Qt's own answer to this is Controls' Drawer, and it is the right shape
      // - edge-anchored, modal, dismissed by the scrim. It does not work here:
      // inside a Quickshell FloatingWindow it reports visible with position
      // stuck at 0, so it never actually slides in. The shell's own components
      // reach for Popup rather than Drawer for the same reason, and the panels
      // hand-roll their overlays. This follows the panels.
      Item {
        id: listDrawer
        anchors.fill: parent
        visible: drawerSlide.x > -drawerPanel.width
        z: 80

        // Dimmed, not blacked out: the conversation underneath is the thing
        // being navigated away from, and it should still be legible.
        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.6)
          opacity: root.listDrawerOpen ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }

          MouseArea {
            anchors.fill: parent
            enabled: root.listDrawerOpen
            // Clicking away is how every drawer closes.
            onClicked: root.listDrawerOpen = false
          }
        }

        Item {
          id: drawerSlide
          width: drawerPanel.width
          height: parent.height
          x: root.listDrawerOpen ? 0 : -drawerPanel.width
          Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

          Rectangle {
            id: drawerPanel
            width: Math.min(Style.space(320), listDrawer.width * 0.85)
            height: parent.height
            color: Color.background
            border.width: Style.space(1)
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

            // Swallows clicks so the list does not dismiss itself.
            MouseArea { anchors.fill: parent }

            ScrollView {
              id: drawerScroll
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              clip: true

              ConversationList {
                id: drawerList
                width: drawerPanel.width - Style.spacing.md * 2
                density: service.densityScale
                palette: service.themeColors
                rows: service.conversations
                selectedKey: service.openConversation ? String(service.openConversation.key) : ""
                fg: Color.foreground
                accent: Color.accent
                fontFamily: Style.font.family
                onPicked: function(row) {
                  if (row.kind === "team") { service.toggleTeam(row.id); return }
                  service.openChat(row)
                  root.listDrawerOpen = false
                  if (service.reading) root.focusPane = "conversation"
                }
              }
            }
          }
        }
      }

      // A picture, opened from the transcript. Built when it is wanted rather
      // than kept hidden, so a conversation full of photographs is not a stack
      // of decoded full-size images sitting behind the window.
      Loader {
        id: imageLayer
        anchors.fill: parent
        active: root.viewingImage
        z: 105

        sourceComponent: ImageViewer {
          path: root.viewingImagePath
          alt: root.viewingImageAlt
          fg: Color.foreground
          accent: Color.accent
          fontFamily: Style.font.family
          onCloseRequested: root.closeImage()
        }
      }

      // The keyboard, listed. Over everything, because ? works from anywhere.
      Item {
        anchors.fill: parent
        visible: root.showHelp
        z: 110

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.97)

          MouseArea { anchors.fill: parent; onClicked: root.showHelp = false }

          KeyHelp {
            anchors.centerIn: parent
            fg: Color.foreground
            fontFamily: Style.font.family
            agentHandover: service.agentHandover
            canSetPresence: service.canSetPresence
          }
        }
      }

      // Your own presence, as Teams' own status menu: pick one and it holds
      // until it is handed back. Dropped from the top right rather than
      // centred like the other overlays, because it belongs to the chip in the
      // header that opens it.
      Item {
        id: presenceMenu
        anchors.fill: parent
        visible: root.pickingPresence
        z: 95

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.6)

          MouseArea { anchors.fill: parent; onClicked: root.pickingPresence = false }
        }

        Rectangle {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.topMargin: root.padPanel
          anchors.rightMargin: root.padPanel
          width: Math.min(Style.space(300), presenceMenu.width - root.padPanel * 2)
          height: menu.implicitHeight + Style.spacing.md * 2
          radius: Style.cornerRadius
          color: Color.background
          border.width: Style.space(1)
          border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)

          // Swallows the clicks that would otherwise reach the scrim and shut
          // the menu on the way to a row.
          MouseArea { anchors.fill: parent }

          PresenceMenu {
            id: menu
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.spacing.md
            service: service
            fg: Color.foreground
            fontFamily: Style.font.family
            onChose: root.pickingPresence = false
          }
        }
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

          // A backing item rather than a bare Column: it swallows the clicks
          // that would otherwise reach the scrim and dismiss the card, and a
          // MouseArea cannot be anchored inside a Column without breaking it.
          Item {
            anchors.centerIn: parent
            width: card.width
            height: card.height

            MouseArea { anchors.fill: parent }

          Column {
            id: card
            width: Math.min(Style.space(420), newChat.width - Style.spacing.huge * 2)
            spacing: Style.spacing.md

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
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        // Stands down whenever a field has focus: it consumes bare letters to
        // drive the cursor, which would eat them out of a message.
        blocked: composer.activeFocus || codeField.activeFocus
                 || peopleField.activeFocus || root.composingNew
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) {
            // Down and up in whatever has focus: the list's cursor, or the
            // transcript's. The transcript used to be scrolled rather than
            // walked, which is why nothing there could be acted on.
            if (root.focusPane === "list" || root.listDrawerOpen) root.activeList().moveCursor(dy)
            else root.moveMessageCursor(dy)
            return
          }
          // Left steps back towards the list, right steps in towards the
          // message box, one rung per press.
          if (dx < 0) {
            if (root.focusPane === "conversation") root.focusList()
          } else if (dx > 0) {
            if (root.focusPane === "list") root.focusConversation()
            else root.focusComposer()
          }
        }
        onActivateRequested: root.activeList().activateCursor()
        onCloseRequested: root.dismiss()
        // Tab is how most people expect to reach the box they type in; l and
        // the right arrow already do it, but only for those who knew.
        onTabRequested: root.focusComposer()
        onTextKey: function(text) {
          var view = root.scrollTarget()
          // A picture is over everything, so it takes the keys while it is up.
          if (root.viewingImage) {
            if (!imageLayer.item) return
            if (text === "s") imageLayer.item.save()
            else if (text === "o") imageLayer.item.openExternally()
            return
          }
          // The status menu is over the window, so it takes the digits while
          // it is up - the same rule the reaction picker follows below.
          if (root.pickingPresence) {
            if (text >= "0" && text <= "9") root.presenceAt(Number(text))
            else if (text === "p") root.pickingPresence = false
            return
          }
          // While the picker is open the digits are the choices, and nothing
          // else should be acting on the conversation behind it.
          if (root.pickingMessageId !== "") {
            if (text >= "1" && text <= "9") root.reactWith(Number(text) - 1)
            else if (text === "e" || text === "+") root.pickingMessageId = ""
            return
          }
          if (text === "e" || text === "+") root.startPicking()
          else if (text === "a") root.askAgent()
          else if (text === "r") service.reloadConversation()
          else if (text === "u") service.unreadOnly = !service.unreadOnly
          // The comma is what most applications use for preferences.
          else if (text === ",") root.showSettings = !root.showSettings
          else if (text === "?") root.showHelp = !root.showHelp
          // Where the hands already are, for the box you type in.
          else if (text === "i") root.focusComposer()
          else if (text === "n" && service.canStartChat) root.openNewChat()
          else if (text === "p") root.togglePresencePicker()
          else if (text === "g") root.scrollToEnd(view, false)
          else if (text === "G") root.scrollToEnd(view, true)
        }

        Column {
          anchors.fill: parent
          anchors.leftMargin: Style.spacing.panelPadding
          anchors.rightMargin: Style.spacing.panelPadding
          anchors.topMargin: root.padPanel
          anchors.bottomMargin: root.padPanel
          spacing: root.padGap

          // ---------------- header ----------------
          Item {
            width: parent.width
            height: Math.max(heading.implicitHeight, appMark.height)

            // Which of the two this is - see brandColor above. A tinted tile
            // rather than a bare glyph, so it reads as the window's mark and
            // not as the first character of the title.
            Rectangle {
              id: appMark
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: root.markSize
              height: root.markSize
              radius: Style.cornerRadius
              color: Util.alpha(root.brandColor, 0.16)

              // Nerd Font logos are not centred in their own advance width;
              // OpticalGlyph puts the painted shape in the middle of the tile
              // rather than the box Qt reserves for it.
              OpticalGlyph {
                anchors.fill: parent
                text: "\u{F02BB}"   // nf-md-microsoft-teams
                color: root.brandColor
                fontFamily: Style.font.family
                fontSize: Style.font.iconLarge
              }
            }

            Row {
              id: heading
              anchors.left: appMark.right
              anchors.leftMargin: Style.spacing.md
              // Bounded by where the buttons start, so a long chat title runs
              // out of room before it reaches them. elide does nothing on a
              // Text that is free to be as wide as it likes, which is what let
              // "Presidential & Head's Council" sit on top of Refresh.
              anchors.right: headerActions.left
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.md

              Text {
                anchors.verticalCenter: parent.verticalCenter
                // Whatever the status bits beside it do not need. They are
                // short and they come and go; the title is the part that has
                // to give way.
                width: Math.max(0, heading.width - status.width
                                   - (status.width > 0 ? heading.spacing : 0))
                text: service.openConversation ? String(service.openConversation.title || "") : "Teams"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }

              // Grouped so their combined width can be measured and taken off
              // the title's, rather than each one pushing it along.
              Row {
                id: status
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md

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

                // Your own presence, and the handle the status menu drops
                // from. Only where it can be acted on: a dot that says how
                // you look to other people, on a sign-in that cannot change
                // it, is a fact with nothing to do about it.
                PresenceChip {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: service.signedIn && service.canSetPresence && !root.showSettings
                  presence: service.myPresence
                  palette: service.themeColors
                  busy: service.settingPresence
                  fg: Color.foreground
                  fontFamily: Style.font.family
                  onClicked: root.togglePresencePicker()
                }
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              // Only when the list has nowhere else to be: wide enough and it
              // is already on screen, and a button that shows what is already
              // shown is a button that teaches people to ignore buttons.
              Button {
                visible: service.signedIn && !columns.roomForBoth && service.reading
                          && !root.showSettings
                text: "Conversations"
                bordered: true
                foreground: Color.foreground
                fontFamily: Style.font.family
                // The same size as its neighbours. A glyph at icon size made
                // this button taller than the two beside it, which is what a
                // row of buttons must never be.
                fontSize: Style.font.caption
                onClicked: root.toggleListDrawer()
              }

              // Last in the row and glyph-only, the way the mail plugin's is:
              // it is the way out of the window's normal business rather than
              // part of it.
              Button {
                visible: service.signedIn && !root.showSettings
                text: "?"
                tooltipText: "What the keyboard does"
                bordered: true
                foreground: Qt.darker(Color.foreground, 1.4)
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: root.showHelp = !root.showHelp
              }

              PanelActionButton {
                // Braces matter: \u takes exactly four hex digits, so "\uF0493"
                // is U+F049 followed by a literal "3" - which drew the wrong
                // glyph with a stray digit on top of it.
                iconText: root.showSettings ? "\u{F0156}" : "\u{F0493}"
                tooltipText: root.showSettings ? "Close settings" : "Settings"
                foreground: Color.foreground
                // Boxed, and the height of the outlined buttons on either
                // side of it. A bare glyph between two boxes reads as a stray
                // character rather than as the next control along.
                bordered: true
                size: unreadButton.height
                onClicked: root.showSettings = !root.showSettings
              }

              Button {
                // Named because the icon buttons measure themselves against
                // it; height is computed even while this one is hidden.
                id: unreadButton
                visible: service.signedIn && !root.showSettings
                // The count belongs on the button that filters by it: "Unread"
                // alone made you turn the filter on to find out whether it was
                // worth turning on.
                text: service.unreadCount > 0 ? "Unread " + service.unreadCount : "Unread"
                tooltipText: service.unreadOnly
                  ? "Showing only unread chats" : "Show only unread chats"
                selected: service.unreadOnly
                bordered: true
                foreground: service.unreadOnly ? Color.accent : Color.foreground
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.unreadOnly = !service.unreadOnly
              }

              Button {
                visible: service.signedIn && service.canStartChat && !root.showSettings
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
                visible: service.signedIn && !service.canMarkRead && !root.showSettings
                text: "Allow marking read…"
                tooltipText: "Sign in again so opening a chat clears its unread mark"
                bordered: true
                foreground: Qt.darker(Color.foreground, 1.4)
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.startLogin(service.wantChannels)
              }

              Button {
                visible: service.signedIn && !service.hasChannels && !root.showSettings
                text: "Add channels…"
                tooltipText: "Sign in again asking for team and channel access. Needs an administrator to consent."
                bordered: true
                foreground: Qt.darker(Color.foreground, 1.4)
                fontFamily: Style.font.family
                fontSize: Style.font.caption
                onClicked: service.startLogin(true)
              }

              // A glyph rather than the word: one idea with a picture
              // everybody already knows, and a tiled window's header runs out
              // of room long before it runs out of buttons.
              PanelActionButton {
                visible: service.configured && !root.showSettings
                enabled: !service.loading
                iconText: "\u{F0450}"   // nf-md-refresh
                tooltipText: "Read the account again"
                foreground: Color.foreground
                bordered: true
                size: unreadButton.height
                onClicked: service.refreshEverything()
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---------------- not ready yet ----------------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: !root.showSettings
                     && (root.settingsError !== "" || !service.configured
                         || service.needsSignIn || service.loggingIn)

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

          // ---------------- settings ----------------
          ScrollView {
            width: parent.width
            height: parent.height - y
            visible: root.showSettings
            clip: true

            SettingsForm {
              width: parent.width - Style.spacing.xxl
              service: service
              onCloseRequested: root.showSettings = false
            }
          }

          // ---------------- the two columns ----------------
          Row {
            id: columns
            // Out into the panel's left padding by exactly the list's marker
            // gutter, so what is written in the rows lands on the panel's left
            // edge. Every other child of this Column keeps the full padding.
            x: -root.listGutter
            width: parent.width + root.listGutter
            height: parent.height - y
            spacing: Style.spacing.xxl
            // Drawn during the first fetch too, so the placeholder rows below
            // stand where the real ones will be. Before this the window was
            // simply blank for the length of the fetch, which read as broken.
            visible: (service.signedIn || service.loading) && !service.loggingIn
                     && root.settingsError === "" && service.configured
                     && !service.needsSignIn && !root.showSettings

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
            // The gutter is width the sidebar takes back, so the divider and
            // the reader beside it stay exactly where they were and it is only
            // the names that move.
            readonly property real sidebarWidth: !showSidebar ? 0
              : (roomForBoth ? Math.max(Style.space(200), Math.min(Style.space(320), width * 0.28))
                               + root.listGutter
                             : width)
            readonly property real readerWidth: !showReader ? 0
              : (roomForBoth ? width - sidebarWidth - spacing * 2 - Style.space(1) : width)

            // Nothing fetched yet. Rows rather than a spinner: they hold the
            // sidebar at the size it is about to have, so the list does not
            // shove the layout around when it lands.
            // Wrapped, so the placeholder bars stand where the real names are
            // about to be rather than out in the marker gutter.
            Item {
              width: columns.sidebarWidth
              height: skeleton.implicitHeight
              visible: columns.showSidebar && service.conversations.length === 0 && service.loading

              LoadingRows {
                id: skeleton
                anchors.left: parent.left
                anchors.leftMargin: root.listGutter
                width: parent.width - root.listGutter
                rows: 7
                fg: Color.foreground
              }
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
                density: service.densityScale
                palette: service.themeColors
                markerGutter: root.listGutter
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
                  if (row.kind === "team") { service.toggleTeam(row.id); return }
                  service.openChat(row)
                  // Opening something is a step inwards: the keys should now be
                  // driving what was opened, not the list behind it.
                  root.listDrawerOpen = false
                  if (service.reading) root.focusPane = "conversation"
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
                // Narrow, this column stands where the sidebar would and has
                // to give the marker gutter back itself; wide, the sidebar has
                // already taken it.
                anchors.leftMargin: columns.roomForBoth ? 0 : root.listGutter
                spacing: root.padReading
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
                    id: transcriptColumn
                    width: transcript.width
                    spacing: root.padMessages
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
                            spacing: root.padLines

                            // Hover for the whole line, read by the add
                            // button below. It cannot live on the reaction row:
                            // that row has no height on a message nobody has
                            // reacted to, and an item with no height receives
                            // no hover at all.
                            HoverHandler { id: lineHover }

                            // The line, with the add-a-reaction button drawn
                            // over its right-hand end rather than in a row of
                            // its own. Nothing here changes size when the
                            // pointer arrives, so pointing at a message cannot
                            // move the messages under it.
                            Item {
                              id: lineBox
                              width: parent.width
                              implicitHeight: lineText.visible ? lineText.implicitHeight : 0

                              readonly property bool cursored:
                                root.focusPane === "conversation"
                                && String(root.cursorMessageId) === String(modelData.id)

                              // Walk the cursor off the edge and there is no
                              // sign of where it went, so bring it back on.
                              onCursoredChanged: if (cursored) Qt.callLater(function() {
                                var pos = lineBox.mapToItem(transcriptColumn, 0, 0)
                                root.ensureVisible(transcript, pos.y, lineBox.height)
                              })

                              // Which message the keys are on. Behind the text
                              // rather than around it, so nothing shifts.
                              Rectangle {
                                anchors.fill: parent
                                anchors.leftMargin: -Style.spacing.xs
                                anchors.rightMargin: -Style.spacing.xs
                                radius: Style.space(4)
                                visible: lineBox.cursored
                                color: Qt.rgba(Color.foreground.r, Color.foreground.g,
                                               Color.foreground.b, 0.08)
                              }

                              SelectableText {
                                id: lineText
                                width: parent.width
                                visible: text !== ""
                                // Escaped first, then links added - so a message
                                // can never choose its own markup. Lines without
                                // a link stay plain text, which is cheaper and
                                // cannot be got wrong at all.
                                readonly property bool linked: Model.hasLink(modelData.text, modelData.links)
                                // Tinted from the theme: a TextEdit has no
                                // linkColor, so an untinted anchor comes out in
                                // Qt's default blue, which belongs to no theme.
                                text: linked ? Model.linkify(modelData.text,
                                                             service.themeColors.blue
                                                             || service.themeColors.accent || "",
                                                             modelData.links)
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

                              // A plus rather than a face, so it does not read
                              // as one more reaction among the ones already
                              // there. Quiet until the message is pointed at,
                              // and never a column of plus signs down a
                              // transcript nobody is touching.
                              Rectangle {
                                id: addReaction
                                anchors.right: parent.right
                                // Clear of the scrollbar. The transcript's bar
                                // is drawn over the content rather than beside
                                // it - availableWidth is the full width - so
                                // anything on the right edge lands underneath
                                // it and the bar takes the pointer first.
                                anchors.rightMargin: root.scrollGutter
                                anchors.top: parent.top
                                width: plusGlyph.implicitWidth + Style.spacing.md
                                // Never taller than the line it floats over.
                                // It is anchored to the line and takes no part
                                // in the layout, so anything taller than the
                                // line would hang into the message below it.
                                height: Math.min(plusGlyph.implicitHeight + Style.spacing.xs * 2,
                                                 Math.max(plusGlyph.implicitHeight,
                                                          lineText.implicitHeight))
                                radius: height / 2
                                visible: lineText.visible && !reactions.picking
                                // Under the pointer, or on the message the
                                // keyboard is on - otherwise nothing, so a
                                // transcript at rest is not a column of plus
                                // signs.
                                opacity: addPointer.containsMouse ? 1.0
                                       : (lineHover.hovered || lineBox.cursored) ? 0.55 : 0.0
                                Behavior on opacity { NumberAnimation { duration: 120 } }
                                color: addPointer.containsMouse
                                  ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
                                  : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)

                                Text {
                                  id: plusGlyph
                                  anchors.centerIn: parent
                                  text: "+"
                                  textFormat: Text.PlainText
                                  color: Qt.darker(Color.foreground, 1.4)
                                  font.family: Style.font.family
                                  font.pixelSize: Style.font.caption
                                }

                                MouseArea {
                                  id: addPointer
                                  anchors.fill: parent
                                  hoverEnabled: true
                                  enabled: !service.reacting
                                  cursorShape: Qt.PointingHandCursor
                                  onClicked: {
                                    root.cursorMessageId = String(modelData.id)
                                    root.pickingMessageId = String(modelData.id)
                                  }
                                }
                              }
                            }

                            ReactionBar {
                              id: reactions
                              width: parent.width
                              // Opened from here rather than by the row itself,
                              // so the keyboard and the mouse open the same one
                              // and a second one closes the first.
                              picking: String(root.pickingMessageId) === String(modelData.id)
                              // Numbered, because the keyboard picks by number.
                              numbered: true
                              reactions: modelData.reactions || []
                              choices: service.reactionChoices
                              busy: service.reacting
                              fg: Color.foreground
                              accent: Color.accent
                              fontFamily: Style.font.family
                              // A chip is a toggle: clicking one you are already
                              // part of takes yours off, clicking one you are
                              // not adds it. Same for a fresh pick, which is
                              // never one of yours yet.
                              onToggled: function(emoji) {
                                root.pickingMessageId = ""
                                service.react(modelData.id, emoji,
                                              Model.reactionIsMine(modelData.reactions, emoji))
                              }
                            }

                            Repeater {
                              model: modelData.images || []

                              delegate: MessageImage {
                                required property var modelData
                                onOpenRequested: function(path, alt) { root.viewImage(path, alt) }
                                url: String(modelData.url || "")
                                alt: String(modelData.alt || "")
                                intrinsicWidth: Number(modelData.width || 0)
                                intrinsicHeight: Number(modelData.height || 0)
                                account: service.alias
                                pluginDir: root.pluginDir
                                maxWidth: Math.min(Style.space(320), columns.readerWidth - Style.spacing.xxl)
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

                  // Only when the sign-in may, and only in a chat: a button
                  // that always explains why it cannot work is worse than no
                  // button.
                  Button {
                    visible: service.canUpload && !!service.openConversation
                             && String(service.openConversation.kind || "") === "chat"
                    enabled: !service.uploading
                    text: service.uploading ? "Sending…" : "Attach"
                    tooltipText: "Send a file into this chat. It goes to your OneDrive first, the way Teams does it, and anything typed in the box goes with it as its comment."
                    bordered: true
                    foreground: Color.foreground
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    onClicked: attachDialog.open()
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

                  // The same handover the a key does. Gone entirely when the
                  // setting is off, rather than disabled: a button that cannot
                  // ever do anything is worse than no button.
                  Button {
                    visible: service.agentHandover
                    text: "Ask agent"
                    tooltipText: "Open your coding agent on this conversation"
                    bordered: true
                    foreground: Color.foreground
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    onClicked: root.askAgent()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== ""
                    text: service.sendError !== "" ? service.sendError
                          : (service.uploadError !== "" ? service.uploadError
                             : service.uploadNotice)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    // The only one of these that is not a failure.
                    color: (service.sendError === "" && service.uploadError === "")
                           ? Qt.darker(Color.foreground, 1.4) : Color.urgent
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
