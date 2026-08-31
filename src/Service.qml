import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the Teams widget and window share: the account, the poll timer,
// the conversation the window is reading, and the one sign-in state machine.
//
// Nothing here ever holds a token. teams.py does, and this runs it and reads
// JSON back - the same split the Office 365 plugin uses, because a process
// that renders other people's messages should not also hold the credentials.
Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""

  readonly property string alias: String(setting("account", "")).trim()
  readonly property string clientId: String(setting("clientId", "")).trim()
  readonly property string authority: String(setting("authority", "")).trim()
  readonly property bool wantChannels: setting("channels", true) !== false
  // The bar only ever draws an unread count, and the team tree costs one Graph
  // request per team - 29 of them on this tenant. So the widget turns it off
  // and the window turns it on; nothing draws a channel list nobody asked for.
  property bool includeTeams: true
  readonly property int chatCount: intSetting("chats", 25, 1, 40)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 120, 30, 3600)

  // Configured enough to try. The client id is not optional the way the mail
  // plugin's is: an app registration declares which permissions it may ask
  // for, so there is no shared registration that could stand in for one set up
  // for Teams.
  readonly property bool configured: alias !== "" && clientId !== ""

  property var snapshot: null
  property bool loading: false
  property string errorCode: ""
  property string errorMessage: ""

  readonly property var view: Model.accountView(snapshot, alias)
  readonly property bool signedIn: view.ok === true
  readonly property bool needsSignIn: view.errorCode === "auth_required"
  readonly property bool hasChannels: view.channels === true
  // Marking a chat read is a write, and needs Chat.ReadWrite. A sign-in from
  // before that was asked for keeps working; it just cannot clear the dot.
  readonly property bool canMarkRead: view.canMarkRead === true
  readonly property int unreadCount: view.unreadCount || 0
  readonly property var conversations: Model.conversationRows(
    view, expandedTeams, teamChannels, loadingTeamId)
  readonly property var warnings: view.warnings || []

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var parsed = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(parsed)) parsed = fallback
    return Math.max(min, Math.min(max, parsed))
  }

  function helper() { return pluginDir + "/teams.py" }

  // ---- fetching ---------------------------------------------------------

  function refresh() {
    if (!configured || fetchProc.running || pluginDir === "") return
    loading = true
    var command = ["python3", helper(), "fetch", "--account", alias,
                   "--chats", String(chatCount)]
    // The team list is one request now that channels are fetched on demand, so
    // there is nothing left worth caching between polls - only the bar, which
    // draws an unread count and nothing else, skips it.
    if (!includeTeams || !wantChannels) command.push("--no-teams")
    if (setting("demo", false) === true) command.push("--demo")
    fetchProc.command = command
    fetchProc.running = true
  }

  // What Refresh means: re-read the chats, the team list, and any team the
  // user has open - somebody may have been added to a channel since.
  function refreshEverything() {
    teamChannels = ({})
    refresh()
    for (var id in expandedTeams) if (expandedTeams[id] === true) { loadChannels(id); break }
  }

  // ---- teams open and shut ----------------------------------------------
  //
  // Closed until opened, and a team's channels are fetched at that moment.
  // Listing every channel of every team up front is one request per team, and
  // on an account in 28 of them that was 29 requests and two hundred rows.
  property var expandedTeams: ({})
  property var teamChannels: ({})
  property string loadingTeamId: ""

  function toggleTeam(teamId) {
    var id = String(teamId || "")
    if (id === "") return
    var next = {}
    for (var k in expandedTeams) next[k] = expandedTeams[k]
    if (next[id] === true) delete next[id]
    else next[id] = true
    expandedTeams = next
    if (next[id] === true && !teamChannels[id]) loadChannels(id)
  }

  function loadChannels(teamId) {
    var id = String(teamId || "")
    if (id === "" || channelsProc.running || pluginDir === "") return
    loadingTeamId = id
    var command = ["python3", helper(), "channels", "--account", alias, "--team", id]
    if (setting("demo", false) === true) command.push("--demo")
    channelsProc.command = command
    channelsProc.running = true
  }

  Process {
    id: channelsProc
    running: false
    stdout: StdioCollector { id: channelsOut; waitForEnd: true }
    stderr: StdioCollector { id: channelsErr; waitForEnd: true }
    onExited: function(exitCode) {
      var wanted = root.loadingTeamId
      root.loadingTeamId = ""
      var parsed = Model.parseJson(channelsOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        // The team stays open showing "no channels" rather than snapping shut
        // under the pointer; the warning line says what went wrong.
        root.errorMessage = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(channelsErr.text || "Could not read that team's channels", 160)
        root.errorCode = "channels_failed"
        return
      }
      var next = {}
      for (var k in root.teamChannels) next[k] = root.teamChannels[k]
      next[String(parsed.teamId || wanted)] = parsed.channels || []
      root.teamChannels = next
    }
  }

  Process {
    id: fetchProc
    running: false
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    stderr: StdioCollector { id: fetchErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) {
        root.errorCode = "helper_failed"
        root.errorMessage = Model.oneLine(fetchErr.text || "The helper could not be run", 160)
        return
      }
      var parsed = Model.parseJson(fetchOut.text, null)
      if (!parsed) {
        root.errorCode = "bad_output"
        root.errorMessage = "Could not read the helper's response"
        return
      }
      root.errorCode = ""
      root.errorMessage = ""
      root.snapshot = parsed
      // A conversation open while the list refreshed is still the one being
      // read; reloading it here would scroll the transcript out from under
      // whoever is reading it.
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.configured
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onConfiguredChanged: if (configured) { resumeLogin(); refresh() }
  onPluginDirChanged: if (configured) { resumeLogin(); refresh() }
  onSettingsChanged: if (configured) { resumeLogin(); refresh() }

  // ---- one conversation -------------------------------------------------

  property var openConversation: null
  property var messages: []
  property bool messagesLoading: false
  property string messagesError: ""

  readonly property bool reading: openConversation !== null

  function openChat(row) {
    if (!row) return
    if (openConversation && String(openConversation.key) === String(row.key)) {
      closeConversation()
      return
    }
    openConversation = row
    messages = []
    messagesError = ""
    messagesLoading = true
    if (messageProc.running) messageProc.running = false
    var command = ["python3", helper(), "messages", "--account", alias, "--top", "30"]
    if (row.kind === "chat") command = command.concat(["--chat", String(row.id)])
    else command = command.concat(["--team", String(row.teamId), "--channel", String(row.id)])
    if (setting("demo", false) === true) command.push("--demo")
    messageProc.command = command
    messageProc.running = true

    // Opening a chat is reading it. Only for chats - a channel has no read
    // state Graph will tell us about - and only when it was actually unread,
    // so this is not a write on every click.
    if (row.kind === "chat" && row.unread === true) markRead(row.id)
  }

  // ---- starting a chat --------------------------------------------------

  readonly property bool canStartChat: view.canStartChat === true

  property string peopleQuery: ""
  property var peopleResults: []
  property bool peopleSearching: false
  property string peopleError: ""
  property bool startingChat: false
  property string startChatError: ""
  // The chat just created, so the window can open it once the list catches up.
  property string pendingChatId: ""

  function searchPeople(query) {
    var text = String(query || "").trim()
    peopleQuery = text
    peopleError = ""
    if (text.length < 2) { peopleResults = []; return }
    if (peopleProc.running || pluginDir === "") return
    peopleSearching = true
    var command = ["python3", helper(), "people", "--account", alias, "--query", text]
    if (setting("demo", false) === true) command.push("--demo")
    peopleProc.command = command
    peopleProc.running = true
  }

  function clearPeople() {
    peopleQuery = ""
    peopleResults = []
    peopleError = ""
    startChatError = ""
  }

  Process {
    id: peopleProc
    running: false
    stdout: StdioCollector { id: peopleOut; waitForEnd: true }
    stderr: StdioCollector { id: peopleErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.peopleSearching = false
      var parsed = Model.parseJson(peopleOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.peopleError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(peopleErrOut.text || "Could not search for people", 160)
        root.peopleResults = []
        return
      }
      root.peopleError = ""
      root.peopleResults = parsed.people || []
    }
  }

  function startChat(userIds, topic) {
    var ids = userIds || []
    if (ids.length === 0 || startingChat || pluginDir === "") return
    startingChat = true
    startChatError = ""
    var command = ["python3", helper(), "new-chat", "--account", alias]
    for (var i = 0; i < ids.length; i++) command = command.concat(["--user", String(ids[i])])
    if (String(topic || "").trim() !== "") command = command.concat(["--topic", String(topic).trim()])
    newChatProc.command = command
    newChatProc.running = true
  }

  Process {
    id: newChatProc
    running: false
    stdout: StdioCollector { id: newChatOut; waitForEnd: true }
    stderr: StdioCollector { id: newChatErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.startingChat = false
      var parsed = Model.parseJson(newChatOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.startChatError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(newChatErrOut.text || "Could not start that chat", 160)
        return
      }
      // Graph hands back the existing one-to-one rather than making a second,
      // so starting a chat with someone you already talk to reopens it.
      root.pendingChatId = String(parsed.id || "")
      root.clearPeople()
      root.refresh()
    }
  }

  // Once the refreshed list contains the new chat, open it.
  onConversationsChanged: {
    if (pendingChatId === "") return
    var rows = conversations
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === "chat" && String(rows[i].id) === pendingChatId) {
        var row = rows[i]
        pendingChatId = ""
        openChat(row)
        return
      }
    }
  }

  // ---- marking read -----------------------------------------------------

  property string markReadError: ""

  function markRead(chatId) {
    var id = String(chatId || "")
    if (id === "" || !canMarkRead || markReadProc.running || pluginDir === "") return
    if (setting("demo", false) === true) return
    markReadProc.command = ["python3", helper(), "mark-read", "--account", alias, "--chat", id]
    markReadProc.running = true
  }

  Process {
    id: markReadProc
    running: false
    stdout: StdioCollector { id: markReadOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(markReadOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.markReadError = parsed && parsed.error
          ? String(parsed.error.message) : "Could not mark this chat read"
        return
      }
      root.markReadError = ""
      // The dot lives in the chat list, which this has just changed on the
      // server; re-read it so the list agrees with what was done.
      root.refresh()
    }
  }

  function closeConversation() {
    openConversation = null
    messages = []
    messagesError = ""
    draft = ""
  }

  function reloadConversation() {
    var row = openConversation
    if (!row) return
    openConversation = null
    openChat(row)
  }

  Process {
    id: messageProc
    running: false
    stdout: StdioCollector { id: messageOut; waitForEnd: true }
    stderr: StdioCollector { id: messageErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.messagesLoading = false
      var parsed = Model.parseJson(messageOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.messagesError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(messageErr.text || "Could not read this conversation", 160)
        return
      }
      root.messagesError = ""
      root.messages = parsed.messages || []
    }
  }

  // ---- sending ----------------------------------------------------------

  property string draft: ""
  property bool sending: false
  property string sendError: ""

  function send() {
    if (sending || !openConversation || draft.trim() === "" || pluginDir === "") return
    sending = true
    sendError = ""
    var row = openConversation
    var command = ["python3", helper(), "send", "--account", alias, "--text", draft]
    if (row.kind === "chat") command = command.concat(["--chat", String(row.id)])
    else command = command.concat(["--team", String(row.teamId), "--channel", String(row.id)])
    sendProc.command = command
    sendProc.running = true
  }

  Process {
    id: sendProc
    running: false
    stdout: StdioCollector { id: sendOut; waitForEnd: true }
    stderr: StdioCollector { id: sendErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.sending = false
      var parsed = Model.parseJson(sendOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.sendError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(sendErrOut.text || "Could not send that message", 160)
        // The draft stays put. Losing what someone typed because the network
        // blinked is the one failure they cannot recover from.
        return
      }
      root.draft = ""
      root.reloadConversation()
      root.refresh()
    }
  }

  // ---- sign-in ----------------------------------------------------------

  property bool loggingIn: false
  property string userCode: ""
  property string verificationUri: ""
  property string loginMessage: ""

  // Pick up a sign-in somebody started and did not finish.
  //
  // Without this, the device code lives in a file for fifteen minutes while
  // nothing redeems it: close the window, or let the shell reload the plugin,
  // and the code the user is typing into their browser has no reader left. It
  // looks exactly like the sign-in silently failing, which is how this was
  // found.
  property bool resumeChecked: false

  function resumeLogin() {
    if (resumeChecked || !configured || pluginDir === "" || loggingIn) return
    resumeChecked = true
    resumeProc.command = ["python3", helper(), "login-status", "--account", alias]
    resumeProc.running = true
  }

  Process {
    id: resumeProc
    running: false
    stdout: StdioCollector { id: resumeOut; waitForEnd: true }
    onExited: function(_exitCode) {
      var parsed = Model.parseJson(resumeOut.text, null)
      if (!parsed || parsed.ok === false || parsed.pending !== true) return
      root.userCode = String(parsed.userCode || "")
      root.verificationUri = String(parsed.verificationUri || "https://microsoft.com/devicelogin")
      root.loginMessage = root.userCode !== ""
        ? "Still waiting - enter the code at " + root.verificationUri
        : "Finishing a sign-in started earlier…"
      root.loggingIn = true
      // A sign-in started before the code was recorded has no code to show, so
      // the timer has to run on the device code in the pending file alone.
      loginPollTimer.restart()
    }
  }

  function startLogin(withChannels) {
    if (!configured || loginStartProc.running) return
    loggingIn = true
    userCode = ""
    verificationUri = ""
    loginMessage = "Starting sign-in…"
    var command = ["python3", helper(), "login-start", "--account", alias, "--client-id", clientId]
    if (authority !== "") command = command.concat(["--authority", authority])
    if (withChannels === true) command.push("--channels")
    loginStartProc.command = command
    loginStartProc.running = true
  }

  function cancelLogin() {
    loggingIn = false
    userCode = ""
    loginMessage = ""
    loginPollTimer.stop()
  }

  Process {
    id: loginStartProc
    running: false
    stdout: StdioCollector { id: loginStartOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(loginStartOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.loggingIn = false
        root.loginMessage = parsed && parsed.error ? String(parsed.error.message) : "Could not start sign-in"
        return
      }
      root.userCode = String(parsed.userCode || "")
      root.verificationUri = String(parsed.verificationUri || "https://microsoft.com/devicelogin")
      root.loginMessage = "Enter the code at " + root.verificationUri
      loginPollTimer.restart()
    }
  }

  Timer {
    id: loginPollTimer
    interval: 5000
    repeat: true
    running: root.loggingIn
    onTriggered: {
      if (loginPollProc.running) return
      loginPollProc.command = ["python3", root.helper(), "login-poll", "--account", root.alias]
      loginPollProc.running = true
    }
  }

  Process {
    id: loginPollProc
    running: false
    stdout: StdioCollector { id: loginPollOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(loginPollOut.text, null)
      if (!parsed) return
      if (parsed.ok === false) {
        root.loggingIn = false
        loginPollTimer.stop()
        root.loginMessage = String((parsed.error || {}).message || "Sign-in failed")
        return
      }
      if (parsed.status === "pending") return
      root.loggingIn = false
      loginPollTimer.stop()
      root.userCode = ""
      root.loginMessage = ""
      root.refresh()
    }
  }

  function openUrl(url) {
    if (!url) return
    Quickshell.execDetached(["xdg-open", String(url)])
  }
}
