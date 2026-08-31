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
  // Teams and their channels change on the order of weeks, chats on the order
  // of seconds. Polling both at the chat cadence is what made a refresh cost
  // thirty requests instead of one.
  readonly property int teamsIntervalSec: 900
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
  readonly property int unreadCount: view.unreadCount || 0
  // The tree the sidebar draws: whatever the last fetch that asked for it
  // returned, not whatever this poll happened to carry.
  readonly property var conversations: Model.conversationRows(
    Model.withTeams(view, (view.teams && view.teams.length > 0) ? view.teams : cachedTeams))
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

  // When the team tree was last actually fetched, so it can be left alone on
  // the polls in between.
  property double teamsFetchedAt: 0
  property var cachedTeams: []
  property bool fetchingTeams: false

  function teamsAreDue() {
    return includeTeams && wantChannels
      && (cachedTeams.length === 0 || Date.now() - teamsFetchedAt > teamsIntervalSec * 1000)
  }

  function refresh() {
    if (!configured || fetchProc.running || pluginDir === "") return
    loading = true
    var withTeams = teamsAreDue()
    fetchingTeams = withTeams
    var command = ["python3", helper(), "fetch", "--account", alias,
                   "--chats", String(chatCount)]
    if (!withTeams) command.push("--no-channels")
    if (setting("demo", false) === true) command.push("--demo")
    fetchProc.command = command
    fetchProc.running = true
  }

  // Force the tree to be re-read on the next refresh - what the Refresh button
  // means when someone has just been added to a team.
  function refreshEverything() {
    teamsFetchedAt = 0
    refresh()
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
      if (root.fetchingTeams) {
        var fetched = root.view.teams || []
        // An empty list from a fetch that did ask is a real answer (no teams),
        // so it replaces the cache rather than being treated as a miss.
        root.cachedTeams = fetched
        root.teamsFetchedAt = Date.now()
        root.fetchingTeams = false
      }
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
