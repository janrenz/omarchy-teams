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
  // Whether to ask for Files.ReadWrite at the next sign-in. Off by default:
  // an app registration that does not declare a permission fails the whole
  // sign-in when it is requested, so this is the user saying theirs does.
  readonly property bool wantFiles: setting("sendFiles", false) === true
  // Whether to ask for Presence.ReadWrite at the next sign-in. Off by default
  // for the same reason as files, and one more: this scope needs an
  // administrator to consent for the tenant, so asking for it uninvited turns
  // a working chats-only sign-in into a refused one.
  readonly property bool wantPresence: setting("setPresence", false) === true
  // Whether to hold a presence session open while this desktop is up. Only
  // means anything with the above on - see holdTimer.
  readonly property bool holdPresence: wantPresence && setting("holdPresence", false) === true
  // The bar only ever draws an unread count, and the team tree costs one Graph
  // request per team - 29 of them on this tenant. So the widget turns it off
  // and the window turns it on; nothing draws a channel list nobody asked for.
  property bool includeTeams: true
  readonly property int chatCount: intSetting("chats", 25, 1, 40)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 120, 30, 3600)
  readonly property bool notifyOnNew: setting("notify", true) !== false
  // Whether the coding-agent handover is on offer at all. Off takes away the a
  // key, the button, and the route an agent uses to hand a draft back - see the
  // README's "Your coding agent" section.
  readonly property bool agentHandover: setting("agentHandover", true) !== false
  // Whose job it is to announce new messages. There is a Service behind the
  // bar icon and another behind the window, both polling the same account, and
  // both announcing would say everything twice. The bar's is the one that is
  // always there, so the bar's is the one that speaks.
  property bool notifies: false

  // How much room to give things. A multiplier over the theme's spacing rather
  // than pixel values of our own, so it still follows the font size.
  readonly property string density: String(setting("density", "cosy"))
  readonly property real densityScale: Model.densityScale(density)
  // Rounded here so every caller gets the same integer, rather than each one
  // rounding a slightly different product and the columns ending up a pixel
  // out from each other.
  function pad(px) { return Math.max(1, Math.round(px * densityScale)) }

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
  readonly property bool canUpload: view.canUpload === true
  readonly property bool canSetPresence: view.canSetPresence === true
  // The user's own presence as Graph currently reports it. Null before the
  // first fetch answers; the header says nothing at all until then, because a
  // dot that means "we have not asked yet" reads as "offline".
  readonly property var myPresence: view.me || null
  readonly property int unreadCount: view.unreadCount || 0
  // Show only what is waiting. A view of the list rather than a setting, so it
  // is not remembered between sessions: it answers "what needs me now", and
  // that question is asked fresh each time.
  property bool unreadOnly: false

  readonly property var conversations: Model.conversationRows(
    view, expandedTeams, teamChannels, loadingTeamId, unreadOnly)
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

  // A fetch that was asked for while one was already in flight. Dropping it is
  // fine when the two would have asked the same question - and they might not:
  // the settings arriving is itself a reason to refresh, and the fetch already
  // running was started before them. So it is remembered and run after.
  property bool refreshQueued: false

  function refresh() {
    if (!configured || pluginDir === "") return
    if (fetchProc.running) { refreshQueued = true; return }
    refreshQueued = false
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
    // And the conversation being read, which is the whole point of pressing
    // Refresh while reading one. The list and the transcript come from
    // different requests, so refreshing only the list left the new message
    // showing in the sidebar and missing from the conversation it belonged to.
    //
    // The background poll still leaves the transcript alone: re-reading it
    // every couple of minutes unasked is not the same as being asked for it.
    reloadConversation()
    if (calendarActive) reloadCalendar()
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
        if (root.refreshQueued) Qt.callLater(root.refresh)
        return
      }
      var parsed = Model.parseJson(fetchOut.text, null)
      if (!parsed) {
        root.errorCode = "bad_output"
        root.errorMessage = "Could not read the helper's response"
        if (root.refreshQueued) Qt.callLater(root.refresh)
        return
      }
      root.errorCode = ""
      root.errorMessage = ""
      root.snapshot = parsed
      root.announceNewChats()
      // A conversation open while the list refreshed is still the one being
      // read; reloading it here would scroll the transcript out from under
      // whoever is reading it.
      if (root.refreshQueued) Qt.callLater(root.refresh)
    }
  }

  // ---- when it is worth asking at all -------------------------------------
  //
  // See PollGate.qml. It gates the timer only: a refresh anybody asked for by
  // hand still goes out, because a failure the user can see beats a silence
  // they cannot.
  // A poll is also a token refresh, and Graph counts every one.
  readonly property bool pausePolling: setting("pausePolling", true) !== false

  PollGate {
    id: poll
    pauseWhenAway: root.pausePolling
    pauseWhenOffline: root.pausePolling
    slowOnBattery: root.pausePolling
    // The presence session follows the desktop, so it needs to know about
    // idleness even when polling is not being paused for it.
    needIdle: root.holdPresence
  }

  // For a host that wants to explain a sidebar that is not moving.
  readonly property string pollReason: poll.reason

  // triggeredOnStart is what makes waking up and coming back online immediate:
  // the gate opening restarts this timer, and a restarted timer fires at once
  // rather than an interval later.
  Timer {
    interval: root.refreshIntervalSec * 1000 * poll.intervalScale
    repeat: true
    running: root.configured && !poll.paused
    triggeredOnStart: true
    onTriggered: {
      root.refresh()
      // A poll is the calendar's tick as well: somebody else moving a meeting
      // should reach the grid without anybody pressing anything, and the
      // reminder for the next one is decided from what came back.
      if (root.calendarActive || root.wantsMeetingAlerts) root.reloadCalendar()
    }
  }

  // Each of these is a way the account can have just become known, and a
  // conversation opened before it was is waiting on exactly that.
  function flushQueuedMessages() {
    if (messagesQueued && openConversation) fetchMessages(openConversation)
  }

  onConfiguredChanged: if (configured) {
    loadPalette(); loadReactionChoices(); loadPresenceChoices(); refresh()
    flushQueuedMessages()
  }
  onPluginDirChanged: if (configured) { loadPalette(); refresh(); flushQueuedMessages() }
  onSettingsChanged: {
    // The view the calendar opens on comes from the settings once, and after
    // that from whoever last pressed a view button.
    if (!calendarModeChosen) calendarMode = validCalendarMode(setting("calendarView", "week"))
    if (configured) { refresh(); flushQueuedMessages() }
  }

  // ---- telling you something arrived --------------------------------------

  // The argv omarchy's notification service runs when a toast is clicked. It
  // goes through the shell rather than the window, because the click may
  // arrive when no window is loaded - summon() mounts it and hands the payload
  // to open(), and delivers it straight away when it is already up.
  readonly property string pluginId: "janrenz.omarchy.teams"

  function summonArgv(payloadJson) {
    return ["omarchy-shell", "shell", "summon", pluginId, String(payloadJson || "{}")]
  }

  // A chat, or a channel inside a team - the window needs to be told which,
  // because Graph addresses them differently. JSON.stringify rather than a
  // hand-built string: these ids come from the server.
  // messageId is accepted for the day a row carries one; today it is always
  // empty, and the window opens the chat on its newest message.
  function openChatArgv(id, messageId) {
    return summonArgv(JSON.stringify({
      chat: String(id || ""),
      message: String(messageId || "")
    }))
  }

  Notifier {
    id: notifier
    appName: "Teams"
    plural: "new messages"
    // The same glyph the bar widget defaults to, so the toast is recognisably
    // this plugin's at a glance.
    glyph: "󰊻"
    // Clicking a digest opens the window on whatever it was showing: a digest
    // is about several chats, so there is no one chat to open.
    defaultExec: root.summonArgv("{}")
    // Not while the demo fixtures are on: dev/showcase.sh turns them on to
    // take the README's pictures, and a screenshot run should not push six
    // notifications about invented people onto a real desktop.
    enabled: root.notifies && root.notifyOnNew && root.setting("demo", false) !== true
  }

  // Another account's chats are not this one's, and a sign-out means the next
  // sign-in starts over: prime again rather than announce the backlog.
  onAliasChanged: { notifier.forget(); meetingNotifier.forget() }
  onSignedInChanged: if (!signedIn) { notifier.forget(); meetingNotifier.forget() }

  function announceNewChats() {
    var chats = view.chats || []
    var me = String(view.displayName || "")
    var fresh = []
    var present = []
    for (var i = 0; i < chats.length; i++) {
      var chat = chats[i]
      // The chat and when it last spoke. The next message in the same chat is
      // a new thing to be told about; the same message polled again is not.
      var id = String(chat.id || "") + "@" + String(chat.when || "")
      present.push(id)
      if (chat.unread !== true) continue
      // Your own last word is not news. Graph leaves a chat you just spoke in
      // unread until the read mark catches up, which is long enough to be
      // told about what you just said yourself.
      var from = String(chat.lastFrom || "")
      if (me !== "" && from === me) continue
      var title = String(chat.title || "")
      fresh.push({
        id: id,
        summary: title,
        // A one-to-one chat is titled with the person's name, so repeating it
        // in front of every line only takes room from what they said.
        body: (from !== "" && from !== title ? from + ": " : "") + String(chat.lastText || ""),
        // Clicking it opens that chat. No message id: a chat row carries the
        // preview's text and time but not its id, and the chat opened on its
        // newest message is where that preview came from anyway.
        exec: root.openChatArgv(chat.id, ""),
        // Three messages in one chat are one chat with something to say, so the
        // newest updates the toast the last one left rather than stacking a
        // third under it. Keyed by the chat, which is exactly what the
        // announced id is not: that one carries the timestamp, so that a *new*
        // message counts as news.
        replaceKey: String(chat.id || "")
      })
    }
    notifier.observe("", fresh, present)
  }

  // After the first fetch has said so, not before it: whether a sign-in is
  // worth resuming depends on whether we are signed in, and only the fetch
  // knows that.
  onNeedsSignInChanged: if (needsSignIn) resumeLogin()

  // ---- one conversation -------------------------------------------------

  property var openConversation: null
  property var messages: []
  property bool messagesLoading: false
  property string messagesError: ""
  // An open waiting on an account - see fetchMessages.
  property bool messagesQueued: false

  readonly property bool reading: openConversation !== null

  // Ask for one conversation's messages. Opening and re-reading both come
  // through here, so there is one place that knows how a chat and a channel
  // are addressed differently.
  function fetchMessages(row) {
    if (!row) return
    messagesError = ""
    messagesLoading = true
    // A conversation asked for before the settings arrived. The window summons
    // on a clicked toast and applies the payload straight away, while the
    // account name is still a subprocess away - and the helper answers a
    // nameless account with "An account needs a name", which then sat in the
    // transcript for good because nothing re-asked. So the open is remembered
    // and run once there is an account to run it for. Left loading rather than
    // erroring: the rows are on their way, only not yet.
    if (!configured || pluginDir === "") { messagesQueued = true; return }
    messagesQueued = false
    if (messageProc.running) messageProc.running = false
    var command = ["python3", helper(), "messages", "--account", alias, "--top", "30"]
    if (row.kind === "chat") command = command.concat(["--chat", String(row.id)])
    else command = command.concat(["--team", String(row.teamId), "--channel", String(row.id)])
    if (setting("demo", false) === true) command.push("--demo")
    messageProc.command = command
    messageProc.running = true
  }

  function openChat(row) {
    if (!row) return
    if (openConversation && String(openConversation.key) === String(row.key)) {
      closeConversation()
      return
    }
    openConversation = row
    // A different conversation, so what is on screen belongs to the last one.
    messages = []
    fetchMessages(row)

    // Opening a chat is reading it. Only for chats - a channel has no read
    // state Graph will tell us about - and only when it was actually unread,
    // so this is not a write on every click.
    if (row.kind === "chat" && row.unread === true) markRead(row.id)
  }

  // A conversation opened by ids alone - a clicked toast - is a row this file
  // made up, because the fetch that knows the chat's name may not have landed
  // yet. The name is the one thing the ids cannot supply, so the window came up
  // called "Teams - " with a blank header and stayed that way until the chat
  // was clicked again in the sidebar. When the real row turns up, adopt it: the
  // title, and the subtitle and presence that travel with it.
  //
  // Only while the title is still missing. A row the payload named, and one
  // that came from the sidebar to begin with, is already the right answer -
  // re-pointing those at every fetch would fight whatever they are doing.
  function adoptRealRow() {
    if (!openConversation || String(openConversation.title || "") !== "") return
    var row = rowFor(String(openConversation.key))
    if (row && String(row.title || "") !== "") openConversation = row
  }

  // The sidebar row for a key, when there is one. A team that has never been
  // expanded has no channel rows at all, so this often finds nothing - which is
  // what the synthetic row below is for.
  function rowFor(key) {
    var rows = conversations
    for (var i = 0; i < rows.length; i++)
      if (String(rows[i].key) === String(key)) return rows[i]
    return null
  }

  // A conversation named by ids alone: a clicked notification, or a draft
  // coming back from a coding agent. Given the same shape a sidebar row has, so
  // the header, the composer and marking read carry on without knowing the
  // difference. A chat is its own id; a channel needs the team as well.
  function openByIds(chatId, teamId, channelId, title) {
    var chat = String(chatId || "")
    var channel = String(channelId || "")
    if (chat === "" && channel === "") return
    var key = chat !== "" ? "chat:" + chat : "channel:" + channel
    // Already reading it. openChat would take this for the sidebar's toggle and
    // close the conversation, which is the opposite of what was asked.
    if (openConversation && String(openConversation.key) === key) return
    var known = rowFor(key)
    if (known) {
      if (String(title || "") !== "") known.title = String(title)
      openChat(known)
      return
    }
    openChat(chat !== ""
      ? { kind: "chat", key: key, id: chat, teamId: "", title: String(title || ""),
          subtitle: "", when: "", unread: false, presence: "", presenceActivity: "",
          depth: 0 }
      : { kind: "channel", key: key, id: channel, teamId: String(teamId || ""),
          title: String(title || ""), subtitle: "", when: "", unread: false, depth: 1 })
  }

  // ---- saving settings --------------------------------------------------

  property bool saving: false
  property string saveError: ""
  signal settingsSaved()

  function saveSettings(patch) {
    if (saving || pluginDir === "") return false
    saving = true
    saveError = ""
    saveProc.command = ["python3", pluginDir + "/config.py",
                        "--plugin-id", "janrenz.omarchy.teams",
                        "--set", JSON.stringify(patch || {})]
    saveProc.running = true
    return true
  }

  Process {
    id: saveProc
    running: false
    stdout: StdioCollector { id: saveOut; waitForEnd: true }
    stderr: StdioCollector { id: saveErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.saving = false
      var parsed = Model.parseJson(saveOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.saveError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(saveErrOut.text || "Could not save these settings", 160)
        return
      }
      root.saveError = ""
      // The shell watches shell.json and hands the new values back through
      // `settings`; this only says the write landed.
      root.settingsSaved()
    }
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
    if (setting("demo", false) === true) command.push("--demo")
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

  // ---- demo auto-open -----------------------------------------------------
  //
  // Screenshots have to be reproducible, and there is no key that opens a
  // conversation - only a click, which an automated run cannot aim at a row
  // whose position depends on the theme's font size. So demo mode can be told
  // which conversation to open and does it itself, as soon as the list is
  // there. Ignored unless "demo" is on, so it can never touch a real account.
  readonly property string demoOpen: setting("demo", false) === true
    ? String(setting("demoOpen", "")).trim() : ""
  property bool demoOpened: false

  // Once the refreshed list contains the new chat, open it.
  onConversationsChanged: {
    // First, and before anything below can return: a list that has just
    // arrived is the list an id-only open has been waiting to be named by.
    adoptRealRow()
    if (demoOpen !== "" && !demoOpened) {
      var demoRows = conversations
      for (var d = 0; d < demoRows.length; d++) {
        if (String(demoRows[d].id) === demoOpen) {
          demoOpened = true
          openChat(demoRows[d])
          return
        }
      }
    }
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

  // ---- the theme's colours ----------------------------------------------
  //
  // Read from the theme rather than hardcoded, so a presence dot and a link
  // are tinted in hues that belong to whatever theme is running.
  property var themeColors: ({})
  readonly property bool canSeePresence: view.presence === true

  function loadPalette() {
    if (paletteProc.running || pluginDir === "") return
    paletteProc.command = ["python3", helper(), "palette"]
    paletteProc.running = true
  }

  Process {
    id: paletteProc
    running: false
    stdout: StdioCollector { id: paletteOut; waitForEnd: true }
    onExited: function(_exitCode) {
      var parsed = Model.parseJson(paletteOut.text, null)
      if (parsed && parsed.colors) root.themeColors = parsed.colors
    }
  }

  // ---- reactions --------------------------------------------------------

  // What may be sent, asked of the helper rather than listed here: Graph
  // refuses anything outside its set, so the picker and the sender have to
  // agree, and one of them should not be a copy of the other.
  property var reactionChoices: []
  property bool reacting: false
  property string reactError: ""

  function loadReactionChoices() {
    if (reactionChoicesProc.running || pluginDir === "" || reactionChoices.length > 0) return
    reactionChoicesProc.command = ["python3", helper(), "reactions"]
    reactionChoicesProc.running = true
  }

  Process {
    id: reactionChoicesProc
    running: false
    stdout: StdioCollector { id: reactionChoicesOut; waitForEnd: true }
    onExited: function(_exitCode) {
      var parsed = Model.parseJson(reactionChoicesOut.text, null)
      if (parsed && parsed.ok !== false) root.reactionChoices = parsed.reactions || []
    }
  }

  // ---- your own presence --------------------------------------------------

  // What may be set, from the helper for the same reason the reactions are:
  // Graph refuses an availability paired with the wrong activity, so the
  // picker offers its table rather than a second copy of it.
  property var presenceChoices: []
  property bool settingPresence: false
  property string presenceError: ""

  function loadPresenceChoices() {
    if (presenceChoicesProc.running || pluginDir === "" || presenceChoices.length > 0) return
    presenceChoicesProc.command = ["python3", helper(), "presence-states"]
    presenceChoicesProc.running = true
  }

  Process {
    id: presenceChoicesProc
    running: false
    stdout: StdioCollector { id: presenceChoicesOut; waitForEnd: true }
    onExited: function(_exitCode) {
      var parsed = Model.parseJson(presenceChoicesOut.text, null)
      if (parsed && parsed.ok !== false) root.presenceChoices = parsed.states || []
    }
  }

  // `auto` hands presence back to Teams, which is the "Reset status" of the
  // client's own menu rather than a state of its own.
  function setPresence(state) {
    var wanted = String(state || "")
    if (wanted === "" || !canSetPresence || settingPresence || pluginDir === "") return
    settingPresence = true
    presenceError = ""
    var command = ["python3", helper(), "presence", "--account", alias, "--state", wanted]
    if (setting("demo", false) === true) command.push("--demo")
    presenceProc.command = command
    presenceProc.running = true
  }

  Process {
    id: presenceProc
    running: false
    stdout: StdioCollector { id: presenceOut; waitForEnd: true }
    stderr: StdioCollector { id: presenceErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.settingPresence = false
      var parsed = Model.parseJson(presenceOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.presenceError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(presenceErrOut.text || "Could not set your presence", 160)
        return
      }
      root.presenceError = ""
      // Read it back rather than draw what was asked for. Graph aggregates a
      // preferred presence with whatever sessions exist, and if none do the
      // answer is Offline however cheerful the request was - which the user
      // should see, not be told the opposite of.
      root.refresh()
    }
  }

  // ---- holding a session open --------------------------------------------
  //
  // A preferred presence only shows while the user has at least one presence
  // session; with no Teams client signed in anywhere they are Offline whatever
  // they picked. So the plugin can be that client - one setPresence renewed
  // before it expires, following the desktop rather than claiming anything:
  // available while somebody is at the machine, away once nobody is.
  //
  // Behind the announcer flag, because there is a Service behind the bar on
  // every monitor and another behind the window, and one of them is enough.
  // Duplicates would be harmless - Graph names the session after the
  // application, so they all renew the same one - but they would be requests
  // nobody asked for.
  property string heldPresence: ""

  readonly property string wantedSessionPresence: poll.idleNow ? "away" : "available"

  function holdSession(state) {
    if (!holdPresence || !canSetPresence || !notifies) return
    if (holdProc.running || pluginDir === "") return
    if (setting("demo", false) === true) return
    holdProc.command = ["python3", helper(), "hold-presence", "--account", alias,
                        "--state", String(state)]
    holdProc.running = true
  }

  Process {
    id: holdProc
    running: false
    stdout: StdioCollector { id: holdOut; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(holdOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        // Not surfaced in the window. This is a background heartbeat nobody
        // asked for by hand, and a line of red over the conversation list is
        // not the way to report that a status dot is stale. The picker's own
        // errors are the ones worth showing.
        root.heldPresence = ""
        return
      }
      root.heldPresence = String(parsed.state || "")
    }
  }

  // Renewed at a third of the hour the session is asked for, so a poll that
  // fails or a laptop that slept through one still leaves two more tries
  // before Graph drops the session and the dot goes grey.
  Timer {
    id: holdTimer
    interval: 20 * 60 * 1000
    repeat: true
    running: root.holdPresence && root.canSetPresence && root.notifies && root.signedIn
    triggeredOnStart: true
    onTriggered: root.holdSession(root.wantedSessionPresence)
  }

  // Coming back to the machine should move the dot now rather than at the next
  // renewal, and the same for walking away from it.
  onWantedSessionPresenceChanged: if (holdTimer.running) holdSession(wantedSessionPresence)

  // Letting go on the way out, so a shell that is shut down does not leave the
  // user looking available for the rest of the hour.
  Component.onDestruction: if (holdPresence && canSetPresence && notifies && heldPresence !== "") {
    Quickshell.execDetached(["python3", helper(), "hold-presence", "--account", alias,
                             "--state", "none"])
  }

  function react(messageId, emoji, remove) {
    var id = String(messageId || "")
    if (id === "" || !openConversation || reacting || pluginDir === "") return
    if (setting("demo", false) === true) return
    reacting = true
    reactError = ""
    var row = openConversation
    var command = ["python3", helper(), "react", "--account", alias,
                   "--message", id, "--emoji", String(emoji)]
    if (row.kind === "chat") command = command.concat(["--chat", String(row.id)])
    else command = command.concat(["--team", String(row.teamId), "--channel", String(row.id)])
    if (remove === true) command.push("--remove")
    reactProc.command = command
    reactProc.running = true
  }

  Process {
    id: reactProc
    running: false
    stdout: StdioCollector { id: reactOut; waitForEnd: true }
    stderr: StdioCollector { id: reactErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.reacting = false
      var parsed = Model.parseJson(reactOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.reactError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(reactErrOut.text || "Could not change that reaction", 160)
        return
      }
      root.reactError = ""
      // Re-read rather than guess at the new count: somebody else may have
      // reacted in the meantime, and the transcript should show what is there.
      root.reloadConversation()
    }
  }

  // ---- marking read -----------------------------------------------------

  property string markReadError: ""

  // ---- sending a file ------------------------------------------------------
  //
  // Three requests inside teams.py - OneDrive, a sharing link, the message -
  // and the path goes in over stdin rather than on the command line, because
  // where a file is can be as telling as what is in it.

  property bool uploading: false
  property string uploadError: ""
  property string uploadNotice: ""
  property string uploadPath: ""

  function uploadFile(path) {
    var file = String(path || "").trim()
    if (!openConversation || file === "" || pluginDir === "") return
    // A silent return here is what a file dropped on the window looked like
    // from the outside: nothing happened, and nothing said why.
    if (uploading) {
      uploadError = "One file at a time - the last one is still going up"
      return
    }
    if (!canUpload) {
      uploadError = "This sign-in cannot send files. Add Files.ReadWrite to your app "
                  + "registration, turn on Send files in settings, and sign in again."
      return
    }
    if (String(openConversation.kind || "") !== "chat") {
      uploadError = "Files can go into a chat, not into a channel - a channel's files live "
                  + "in the team's SharePoint library."
      return
    }
    uploading = true
    uploadError = ""
    uploadNotice = ""
    uploadPath = file
    var command = ["python3", helper(), "upload", "--account", alias,
                   "--chat", String(openConversation.id), "--stdin"]
    if (setting("demo", false) === true) command.push("--demo")
    uploadProc.command = command
    uploadProc.running = true
  }

  Process {
    id: uploadProc
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: uploadOut; waitForEnd: true }
    stderr: StdioCollector { id: uploadErrOut; waitForEnd: true }
    // Whatever is in the message box goes with the file as its comment, which
    // is what Teams itself does when you drop one on a conversation.
    onStarted: uploadProc.write(JSON.stringify({
      file: root.uploadPath, comment: root.draft
    }) + "\n")
    onExited: function(exitCode) {
      root.uploading = false
      var parsed = Model.parseJson(uploadOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.uploadError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(uploadErrOut.text || "Could not send that file", 160)
        return
      }
      root.uploadNotice = "Sent " + String(parsed.name || "that file")
      root.draft = ""
      root.reloadConversation()
      root.refresh()
    }
  }

  // Chats still waiting to be marked. Graph wants a request per chat and one
  // Process cannot run two commands, so they go one at a time - and the
  // refresh that has to follow is spent once, at the end, rather than after
  // every one of them.
  //
  // Queued rather than dropped, which is what a second mark used to be while
  // the first was still in flight: opening two unread chats quickly meant only
  // one of them was read.
  property var markQueue: []
  // Something is being marked - one chat being opened, or all of them at once.
  readonly property bool marking: markQueue.length > 0

  function markRead(chatId) {
    var id = String(chatId || "")
    if (id === "" || !canMarkRead || pluginDir === "") return
    if (setting("demo", false) === true) return
    if (markQueue.indexOf(id) !== -1) return
    markQueue = markQueue.concat([id])
    pumpMarkRead()
  }

  // Every chat with something waiting in it, read in one go. Chats only,
  // because a channel has no unread mark to clear - Graph exposes nothing
  // equivalent, which is why the list never draws one.
  function markAllRead() {
    if (!canMarkRead || pluginDir === "") return
    if (setting("demo", false) === true) return
    var chats = view.chats || []
    var next = markQueue.slice()
    for (var i = 0; i < chats.length; i++) {
      if (chats[i].unread !== true) continue
      var id = String(chats[i].id || "")
      if (id !== "" && next.indexOf(id) === -1) next.push(id)
    }
    markQueue = next
    pumpMarkRead()
  }

  function pumpMarkRead() {
    if (markReadProc.running || markQueue.length === 0) return
    markReadProc.command = ["python3", helper(), "mark-read",
                            "--account", alias, "--chat", String(markQueue[0])]
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
        // The rest go with it. Whatever refused this one - a sign-in that
        // cannot mark, or Graph saying no - will refuse the next twenty the
        // same way, and twenty requests to be told so is not worth the one
        // message it produces.
        root.markQueue = []
        return
      }
      root.markReadError = ""
      root.markQueue = root.markQueue.slice(1)
      if (root.markQueue.length > 0) {
        root.pumpMarkRead()
        return
      }
      // The dot lives in the chat list, which this has just changed on the
      // server; re-read it so the list agrees with what was done.
      root.refresh()
    }
  }

  function closeConversation() {
    openConversation = null
    messages = []
    messagesError = ""
    messagesQueued = false
    draft = ""
  }

  // Re-read the conversation already open. Deliberately not by closing and
  // reopening it: that emptied the transcript before the new rows arrived, so
  // it flashed blank, and it counted as opening the chat again - marking read
  // a second time. The same conversation's rows stay on screen until better
  // ones land.
  function reloadConversation() {
    fetchMessages(openConversation)
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
    var command = ["python3", helper(), "send", "--account", alias, "--stdin"]
    if (row.kind === "chat") command = command.concat(["--chat", String(row.id)])
    else command = command.concat(["--team", String(row.teamId), "--channel", String(row.id)])
    if (setting("demo", false) === true) command.push("--demo")
    sendProc.command = command
    sendProc.running = true
  }

  Process {
    id: sendProc
    running: false
    // The message goes in over stdin rather than as an argument. Anyone on this
    // machine can read /proc/<pid>/cmdline; nobody can read another process's
    // stdin - and a message is somebody's words.
    stdinEnabled: true
    onStarted: sendProc.write(JSON.stringify({ text: root.draft }) + "\n")
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

  // ---- the calendar --------------------------------------------------------
  //
  // A range of days is asked for and a range comes back, occurrences already
  // expanded - so the view is only ever a question of which days to ask about.
  // Which is what `calendarMode` and `calendarAnchor` are between them, and
  // why changing either is a fetch rather than a filter: a month of a busy
  // calendar is two hundred events, and keeping every month anybody scrolled
  // past would be a cache with no way of knowing it had gone stale.

  // Whether to ask for the calendar scopes at the next sign-in. Off by
  // default, for the reason every opt-in tier here is: a registration that
  // does not declare a permission fails the whole sign-in when it is asked
  // for, not just that scope.
  readonly property bool wantCalendar: setting("calendar", false) === true
  // And whether to ask for the wider of the two. Reading a calendar and
  // writing to it are both ordinary user consent - no administrator - but
  // they are separately declared, so this is the user saying their
  // registration has the second one.
  readonly property bool wantCalendarWrite: wantCalendar && setting("calendarWrite", false) === true
  readonly property bool hasCalendar: view.calendar === true
  readonly property bool canWriteCalendar: view.canWriteCalendar === true
  // Which day a week starts on is a local convention and Graph has no opinion
  // about it, so it is a setting rather than a guess.
  readonly property bool sundayFirst: String(setting("weekStart", "monday")) === "sunday"

  // A minute hand, for the line across today and for "starts in four
  // minutes". Deliberately not what the day columns are built from - a date
  // that changes every minute would rebuild every delegate in the grid once a
  // minute - so the layout binds to `todayKey`, which changes at midnight and
  // not before.
  property var clock: new Date()
  readonly property string todayKey: Model.keyOf(clock)

  Timer {
    interval: 60 * 1000
    repeat: true
    running: root.calendarActive || root.wantsMeetingAlerts
    onTriggered: root.clock = new Date()
  }

  // The view the calendar opens on. A setting for the first paint and a plain
  // property afterwards: flipping to Month for one look is not a preference,
  // and writing shell.json every time somebody did would be.
  property string calendarMode: "week"
  property bool calendarModeChosen: false
  // Which day the view is about. Empty until something asks, so that a window
  // opened at half past eleven at night and looked at again after midnight
  // opens on the new day rather than on the old one.
  property string calendarAnchor: ""
  // Whether anybody is looking. The window sets it; the bar never does, which
  // is what keeps a bar icon from fetching a month of meetings to draw a
  // number it does not draw.
  property bool calendarActive: false

  property var calendarEvents: []
  property bool calendarLoading: false
  property string calendarError: ""
  property bool calendarCapped: false

  function validCalendarMode(name) {
    var wanted = String(name || "").toLowerCase()
    return Model.calendarViewNames().indexOf(wanted) === -1 ? "week" : wanted
  }

  function setCalendarMode(name) {
    calendarModeChosen = true
    calendarMode = validCalendarMode(name)
  }

  function cycleCalendarMode(step) {
    var names = Model.calendarViewNames()
    var at = names.indexOf(calendarMode)
    setCalendarMode(names[(at + names.length + Number(step || 1)) % names.length])
  }

  function calendarToday() {
    calendarAnchor = Model.keyOf(new Date())
  }

  function moveCalendar(step) {
    calendarAnchor = Model.shiftAnchor(calendarMode, calendarAnchor || todayKey,
                                       Number(step || 0), sundayFirst)
  }

  // The days on screen, and the days worth asking about. They are the same
  // range while the window is open; with only the reminders running there is
  // nothing on screen and today is all that is needed.
  readonly property var calendarSpan: calendarActive
    ? Model.calendarRange(calendarMode, calendarAnchor || todayKey, sundayFirst)
    : { from: todayKey, days: 1, keys: [todayKey], view: "day" }
  readonly property var calendarDays: Model.calendarDays(
    calendarEvents, calendarSpan.keys, calendarAnchor || todayKey, todayKey)

  // A range nobody has fetched yet, as one string, so that changing the view
  // or stepping a week is one comparison rather than two properties racing.
  readonly property string calendarWanted: (configured && hasCalendar)
    ? (calendarSpan.from + "+" + calendarSpan.days) : ""
  property string calendarLoaded: ""

  onCalendarWantedChanged: if (calendarWanted !== "") loadCalendar()

  function loadCalendar(force) {
    if (!configured || pluginDir === "" || !hasCalendar) return
    if (calendarProc.running) return
    if (force !== true && calendarLoaded === calendarWanted && calendarEvents.length > 0
        && calendarError === "") return
    calendarLoading = true
    var command = ["python3", helper(), "calendar", "--account", alias,
                   "--from", String(calendarSpan.from), "--days", String(calendarSpan.days)]
    if (setting("demo", false) === true) command.push("--demo")
    calendarProc.command = command
    calendarProc.running = true
  }

  // What Refresh means for the calendar: ask again for the range on screen,
  // whether or not it is the one already loaded.
  function reloadCalendar() {
    calendarLoaded = ""
    loadCalendar(true)
  }

  Process {
    id: calendarProc
    running: false
    stdout: StdioCollector { id: calendarOut; waitForEnd: true }
    stderr: StdioCollector { id: calendarErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.calendarLoading = false
      var parsed = Model.parseJson(calendarOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.calendarError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(calendarErrOut.text || "Could not read your calendar", 160)
        return
      }
      root.calendarError = ""
      root.calendarEvents = parsed.events || []
      root.calendarCapped = parsed.capped === true
      root.calendarLoaded = String(parsed.from || "") + "+" + String(parsed.days || 0)
      root.announceMeetings()
      // The range moved while the last fetch was in flight - somebody holding
      // the next-week key down - so the answer that just landed is about a
      // week nobody is looking at any more.
      if (root.calendarLoaded !== root.calendarWanted) Qt.callLater(root.loadCalendar)
    }
  }

  // ---- one meeting -------------------------------------------------------

  property string openEventId: ""
  property var openEvent: null
  property bool eventLoading: false
  property string eventError: ""

  readonly property bool readingEvent: openEventId !== ""

  function showEvent(eventId) {
    var id = String(eventId || "")
    if (id === "") return
    if (openEventId === id) { closeEvent(); return }
    openEventId = id
    openEvent = null
    eventError = ""
    rsvpError = ""
    cancelError = ""
    fetchEvent()
  }

  function fetchEvent() {
    if (openEventId === "" || pluginDir === "" || !configured) return
    if (eventProc.running) eventProc.running = false
    eventLoading = true
    var command = ["python3", helper(), "event", "--account", alias, "--event", openEventId]
    if (setting("demo", false) === true) command.push("--demo")
    eventProc.command = command
    eventProc.running = true
  }

  function closeEvent() {
    openEventId = ""
    openEvent = null
    eventError = ""
    eventLoading = false
    rsvpComment = ""
  }

  Process {
    id: eventProc
    running: false
    stdout: StdioCollector { id: eventOut; waitForEnd: true }
    stderr: StdioCollector { id: eventErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.eventLoading = false
      var parsed = Model.parseJson(eventOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.eventError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(eventErrOut.text || "Could not read that meeting", 160)
        return
      }
      root.eventError = ""
      root.openEvent = parsed.event || null
    }
  }

  // ---- answering an invitation -------------------------------------------

  // What to say to the organiser, if anything. Held here rather than in the
  // detail pane so that it survives the pane being rebuilt under it, the way
  // a message draft does.
  property string rsvpComment: ""
  property bool rsvpSending: false
  property string rsvpError: ""
  // Whether the organiser hears about it. Teams offers the same three ways of
  // answering, and this is its "Don't send a response".
  property bool rsvpReplies: true

  function rsvp(eventId, response, comment, silent) {
    var id = String(eventId || "")
    if (id === "" || rsvpSending || pluginDir === "") return
    if (!canWriteCalendar) {
      rsvpError = "This sign-in can read your calendar but not answer invitations. "
                + "Turn on \"Answer and create meetings\" in settings and sign in again."
      return
    }
    rsvpSending = true
    rsvpError = ""
    rsvpPayload = JSON.stringify({ comment: String(comment || "") })
    var command = ["python3", helper(), "rsvp", "--account", alias,
                   "--event", id, "--response", String(response), "--stdin"]
    if (silent === true) command.push("--silent")
    if (setting("demo", false) === true) command.push("--demo")
    rsvpProc.command = command
    rsvpProc.running = true
  }

  // On stdin, not in argv, for the reason a message is: "I cannot make this
  // one, I am at the hospital" is somebody's words, and anyone on this
  // machine can read another process's command line.
  property string rsvpPayload: "{}"

  Process {
    id: rsvpProc
    running: false
    stdinEnabled: true
    onStarted: rsvpProc.write(root.rsvpPayload + "\n")
    stdout: StdioCollector { id: rsvpOut; waitForEnd: true }
    stderr: StdioCollector { id: rsvpErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.rsvpSending = false
      var parsed = Model.parseJson(rsvpOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.rsvpError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(rsvpErrOut.text || "Could not send that answer", 160)
        return
      }
      root.rsvpError = ""
      root.rsvpComment = ""
      // Read back rather than assume: an accepted invitation changes how it
      // is drawn in the grid, and the grid is what says the answer went.
      root.reloadCalendar()
      if (root.readingEvent) root.fetchEvent()
    }
  }

  // ---- booking one -------------------------------------------------------

  property bool creatingEvent: false
  property string createEventError: ""
  // The meeting just made, so the calendar can be moved to the day it is on
  // and the detail opened on it.
  property string createdEventId: ""
  property string newEventPayload: "{}"

  function createEvent(draft) {
    if (creatingEvent || pluginDir === "") return
    if (!canWriteCalendar) {
      createEventError = "This sign-in can read your calendar but not add to it. "
                       + "Turn on \"Answer and create meetings\" in settings and sign in again."
      return
    }
    var problem = Model.newMeetingProblem(draft)
    if (problem !== "") { createEventError = problem; return }
    creatingEvent = true
    createEventError = ""
    createdEventId = ""
    newEventPayload = JSON.stringify(Model.newMeetingPayload(draft))
    var command = ["python3", helper(), "new-event", "--account", alias, "--stdin"]
    if (setting("demo", false) === true) command.push("--demo")
    newEventProc.command = command
    newEventProc.running = true
  }

  Process {
    id: newEventProc
    running: false
    stdinEnabled: true
    // Everything about the meeting goes this way: a subject, an agenda and a
    // guest list are somebody's words and other people's addresses.
    onStarted: newEventProc.write(root.newEventPayload + "\n")
    stdout: StdioCollector { id: newEventOut; waitForEnd: true }
    stderr: StdioCollector { id: newEventErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.creatingEvent = false
      var parsed = Model.parseJson(newEventOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.createEventError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(newEventErrOut.text || "Could not create that meeting", 160)
        return
      }
      root.createEventError = ""
      var made = parsed.event || {}
      root.createdEventId = String(made.id || "")
      // Onto the day it was booked for, which is not necessarily the day that
      // was on screen when the form was opened.
      if (String(made.startDate || "") !== "") root.calendarAnchor = String(made.startDate)
      root.reloadCalendar()
    }
  }

  // ---- calling one off ---------------------------------------------------

  property bool cancelling: false
  property string cancelError: ""
  property string cancelNotice: ""
  property string cancelPayload: "{}"

  function cancelEvent(eventId, comment) {
    var id = String(eventId || "")
    if (id === "" || cancelling || pluginDir === "") return
    if (!canWriteCalendar) {
      cancelError = "This sign-in can read your calendar but not change it."
      return
    }
    cancelling = true
    cancelError = ""
    cancelNotice = ""
    cancelPayload = JSON.stringify({ comment: String(comment || "") })
    var command = ["python3", helper(), "cancel-event", "--account", alias,
                   "--event", id, "--stdin"]
    if (setting("demo", false) === true) command.push("--demo")
    cancelProc.command = command
    cancelProc.running = true
  }

  Process {
    id: cancelProc
    running: false
    stdinEnabled: true
    onStarted: cancelProc.write(root.cancelPayload + "\n")
    stdout: StdioCollector { id: cancelOut; waitForEnd: true }
    stderr: StdioCollector { id: cancelErrOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.cancelling = false
      var parsed = Model.parseJson(cancelOut.text, null)
      if (exitCode !== 0 || !parsed || parsed.ok === false) {
        root.cancelError = parsed && parsed.error
          ? String(parsed.error.message)
          : Model.oneLine(cancelErrOut.text || "Could not call that meeting off", 160)
        return
      }
      root.cancelError = ""
      // Which of the two happened is worth saying: an organiser's cancellation
      // reaches everybody who was invited, and an attendee's removal reaches
      // nobody at all.
      root.cancelNotice = String(parsed.action || "") === "cancelled"
        ? "Cancelled, and everybody invited has been told"
        : "Taken off your calendar"
      root.closeEvent()
      root.reloadCalendar()
    }
  }

  // Joining is the one thing this window cannot do itself: a meeting is audio
  // and video, and this is a QML panel. The link goes to whatever handles
  // Teams meetings on this machine - the desktop client, or a browser - which
  // is the honest answer rather than a button that pretends.
  function joinMeeting(url) {
    openUrl(url)
  }

  // ---- the meeting about to start ------------------------------------------
  //
  // The other half of what a calendar is for. Behind the same announcer flag
  // the message notifications use - there is a Service per monitor behind the
  // bar and another behind the window - and behind the same setting, plus one
  // of its own, because somebody who wants message toasts does not
  // necessarily want to be told about a meeting they are already in a room
  // for.
  readonly property bool meetingReminders: setting("meetingReminders", true) !== false
  readonly property int reminderMinutes: intSetting("reminderMinutes", 5, 1, 60)
  readonly property bool wantsMeetingAlerts:
    notifies && notifyOnNew && meetingReminders && hasCalendar && configured

  Notifier {
    id: meetingNotifier
    appName: "Teams"
    plural: "meetings starting"
    glyph: "󰃭"
    defaultExec: root.summonArgv(JSON.stringify({ pane: "calendar" }))
    enabled: root.wantsMeetingAlerts && root.setting("demo", false) !== true
  }

  function announceMeetings() {
    if (!wantsMeetingAlerts) return
    var soon = Model.startingSoon(calendarEvents, clock, reminderMinutes)
    var fresh = []
    var present = []
    var all = calendarEvents || []
    // Everything in the range is present, so an event that has been announced
    // is not announced again when the next poll finds it still there - and an
    // occurrence of a daily meeting is a different id tomorrow, which is what
    // makes tomorrow's standup news again.
    for (var i = 0; i < all.length; i++)
      present.push(String(all[i].id || "") + "@" + String(all[i].when || ""))
    for (var s = 0; s < soon.length; s++) {
      var event = soon[s]
      var minutes = Model.minutesUntil(event, clock)
      fresh.push({
        id: String(event.id || "") + "@" + String(event.when || ""),
        summary: String(event.subject || "A meeting"),
        body: (minutes <= 0 ? "Starting now" : "Starting in " + minutes + " min")
              + " · " + Model.eventTimeLabel(event)
              + (String(event.where || "") !== "" ? " · " + String(event.where) : ""),
        // Clicking opens the window on the calendar with that meeting open,
        // which is where the Join button is.
        exec: root.summonArgv(JSON.stringify({ pane: "calendar", event: String(event.id || "") })),
        replaceKey: "meeting:" + String(event.id || "")
      })
    }
    meetingNotifier.observe("meetings", fresh, present)
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
    // Only when there is nothing to resume into. A pending file outlives a
    // sign-in that succeeded by another route - a second window, a re-consent
    // finished elsewhere - and picking that up put a "still waiting, enter
    // this code" prompt over a mailbox that was already signed in.
    if (signedIn) return
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
    // Asked for only when the setting says so, because a scope the app
    // registration does not declare fails the whole sign-in rather than just
    // itself - see the comment on SCOPES_FILES in teams.py.
    if (wantFiles) command.push("--files")
    if (wantPresence) command.push("--presence")
    if (wantCalendar) command.push("--calendar")
    if (wantCalendarWrite) command.push("--calendar-write")
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

  // The last gate before xdg-open, which opens whatever it is handed - a
  // file:// path, a handler registered for some scheme nobody remembers
  // installing. Both sides that build a link already keep to these three, so
  // this changes nothing that works; it is here so that a link arriving by
  // some route added later cannot reach the opener without passing it.
  function openUrl(url) {
    var target = String(url || "").trim()
    var lowered = target.toLowerCase()
    if (lowered.indexOf("http://") !== 0 && lowered.indexOf("https://") !== 0
        && lowered.indexOf("mailto:") !== 0) return
    Quickshell.execDetached(["xdg-open", target])
  }
}
