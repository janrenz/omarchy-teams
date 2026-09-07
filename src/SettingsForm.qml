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
// Edits apply themselves, a short pause after the last one. There used to be
// a Save button, on the grounds that a write per keystroke would hammer the
// file the whole shell reads - which is true, and is what the pause is for
// rather than what a button was needed for. A settings panel where ticking a
// box does nothing until you find a button at the bottom of a scroll is a
// panel where half the ticks never take effect, and the wifi rules made that
// plain: they are ticked one network at a time, in the place you happen to be
// standing.
//
// What survives from the old rationale is that nothing is written *while*
// somebody types. A half-typed account name would send the service off to
// fetch as nobody, so the debounce waits for typing to stop - and edits made
// while a write is in flight are held rather than dropped, because the config
// helper takes one at a time.
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
    autoSave.restart()
  }

  // Anything outstanding, written now rather than in a moment.
  function flushNow() {
    autoSave.stop()
    flush()
  }

  // Closing, not discarding. Anything outstanding goes out on the way rather
  // than being thrown away: a panel that saves as you go and then loses the
  // last tick because you shut it too quickly is worse than either rule on
  // its own.
  function close() {
    flushNow()
    root.closeRequested()
  }

  // And the pane is closed by things that never touch that button - Escape
  // unwinds to it, and `,` toggles it - so the write happens on the way out
  // however "out" came about. Reading its own `visible` is safe here; it is
  // reading a *child's* that is the circular binding to avoid.
  onVisibleChanged: if (!visible) flushNow()

  // Which calendars are ticked, pending edits included.
  function pickedCalendars() {
    return Model.stringList(root.current("calendarIds", []))
  }

  function togglePickedCalendar(calendarId) {
    var picked = root.pickedCalendars()
    var at = picked.indexOf(calendarId)
    if (at === -1) picked.push(calendarId)
    else picked.splice(at, 1)
    // Nothing ticked is written as nothing at all: an empty list and an
    // absent key mean the same thing - the default calendar - and leaving the
    // key out keeps shell.json the size it was before anybody had a choice.
    root.change("calendarIds", picked.length === 0 ? "" : picked)
  }

  // The wifi-to-location rules, pending edits included.
  function wifiRules() {
    return Model.stringList(root.current("wifiLocations", []))
  }

  // What the network this machine is on is currently mapped to, as a rule's
  // right-hand side - empty for "nothing said about this one yet".
  function ruleForHere() {
    var here = root.service ? String(root.service.currentSsid || "") : ""
    if (here === "") return ""
    var rows = Model.wifiRuleRows(root.wifiRules(),
                                  root.service ? root.service.buildings : [])
    for (var i = 0; i < rows.length; i++)
      if (rows[i].ssid.toLowerCase() === here.toLowerCase()) return rows[i].target
    return ""
  }

  // Point the network this machine is on at something, or take it off the
  // list. One rule per network: a second line for the same SSID would be a
  // rule that never fires, and the first one wins in Model.autoLocationFor.
  function mapHere(target) {
    var here = root.service ? String(root.service.currentSsid || "") : ""
    if (here === "") return
    var kept = []
    var rules = root.wifiRules()
    for (var i = 0; i < rules.length; i++) {
      var at = rules[i].indexOf("=")
      var ssid = (at === -1 ? rules[i] : rules[i].slice(0, at)).trim()
      if (ssid.toLowerCase() !== here.toLowerCase()) kept.push(rules[i])
    }
    // Clicking what is already ticked takes it off, the way the calendar
    // ticks do - there has to be a way back to "say nothing here".
    if (String(target || "") !== "") kept.push(here + " = " + String(target))
    root.change("wifiLocations", kept.length === 0 ? "" : kept)
  }

  // Buildings named locally: `<place id> = what you call it`.
  // Whether the sign-in would go through a registration that is not the one
  // this plugin publishes. The id comes from the helper rather than being
  // copied into the QML - see defaultClientId in teams.py - so an empty field
  // and the shared id spelled out are both correctly "not your own".
  readonly property bool ownRegistration: {
    var typed = String(root.current("clientId", "")).trim()
    if (typed === "") return false
    var shared = root.service ? String(root.service.view.defaultClientId || "") : ""
    // Before a fetch has answered there is nothing to compare against, so the
    // account's own answer stands in - it is the same question, already asked.
    if (shared === "") return !!root.service && root.service.view.ownRegistration === true
    return typed.toLowerCase() !== shared.toLowerCase()
  }

  function nameRules() {
    return Model.stringList(root.current("buildingNames", []))
  }

  // The place id Graph reports for this user right now, when it is one nothing
  // has a name for yet. That is the answer to "where do I get a building id" on
  // a sign-in that may not list them: if any Teams client has ever put you in
  // a building, Graph hands the id straight back on your own presence.
  function unnamedPlaceHere() {
    var mine = root.service ? root.service.myLocation : null
    var place = mine ? String(mine.placeId || "") : ""
    if (place === "") return ""
    var known = Model.namedBuildings(root.nameRules())
    for (var i = 0; i < known.length; i++)
      if (String(known[i].id) === place) return ""
    var fetched = root.service ? root.service.fetchedBuildings : []
    for (var k = 0; k < fetched.length; k++)
      if (String(fetched[k].id) === place) return ""
    return place
  }

  function nameBuilding(placeId, name) {
    if (String(placeId || "") === "") return
    var kept = []
    var rules = root.nameRules()
    for (var i = 0; i < rules.length; i++) {
      var at = rules[i].indexOf("=")
      var id = (at === -1 ? rules[i] : rules[i].slice(0, at)).trim()
      if (id !== String(placeId)) kept.push(rules[i])
    }
    if (String(name || "").trim() !== "")
      kept.push(String(placeId) + " = " + String(name).trim())
    root.change("buildingNames", kept.length === 0 ? "" : kept)
  }

  function dropName(rule) {
    var kept = []
    var rules = root.nameRules()
    for (var i = 0; i < rules.length; i++)
      if (rules[i] !== rule) kept.push(rules[i])
    root.change("buildingNames", kept.length === 0 ? "" : kept)
  }

  function dropRule(rule) {
    var kept = []
    var rules = root.wifiRules()
    for (var i = 0; i < rules.length; i++)
      if (rules[i] !== rule) kept.push(rules[i])
    root.change("wifiLocations", kept.length === 0 ? "" : kept)
  }

  // A building being typed in, before it is added. Held here rather than in
  // `pending` because a half-typed place id is not a setting - it becomes one
  // when the button says so.
  property string draftPlaceId: ""
  property string draftPlaceName: ""

  // What the write in flight is carrying. Kept so that what lands can be taken
  // out of `pending` without taking anything typed since it was sent - which
  // clearing the whole thing would, and a lost edit is exactly what makes
  // saving-as-you-go feel broken.
  property var inFlight: ({})

  function flush() {
    if (!service || !dirty) return
    // The helper writes one at a time and saveSettings refuses while one is
    // running, so this waits rather than being dropped on the floor.
    if (service.saving) { autoSave.restart(); return }
    inFlight = pending
    service.saveSettings(inFlight)
  }

  Timer {
    id: autoSave
    // Long enough that typing a client id is one write rather than thirty-six,
    // short enough that nobody wonders whether a tick took.
    interval: 700
    repeat: false
    onTriggered: root.flush()
  }

  Connections {
    target: root.service
    // Only what was actually written is forgotten, and only once the write has
    // landed - so a failed save keeps what was typed, and an edit made while
    // the write was in flight survives it.
    function onSettingsSaved() {
      var left = {}
      for (var key in root.pending)
        if (JSON.stringify(root.pending[key]) !== JSON.stringify(root.inFlight[key]))
          left[key] = root.pending[key]
      root.pending = left
      root.inFlight = ({})
      // Anything typed during the write is now the next one.
      if (root.dirty) autoSave.restart()
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
    placeholder: "the plugin's own registration"
    hint: "Optional. Leave empty and the sign-in uses the plugin's own app registration. Fill it in with your own if your organisation will not consent to that one - see the plugin's README."
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

  // ---------------- the calendar ----------------

  PanelSectionHeader { width: parent.width; text: "Calendar" }

  Toggle {
    width: parent.width
    label: "Show my calendar"
    description: "A calendar beside the conversations: day, work week, week and month, what each meeting is, who is coming, and the link that joins it. Needs Calendars.Read on your app registration - ordinary user consent, no administrator involved - and takes effect at the next sign-in. Turn it on only once the registration declares it, because a scope it does not declare fails the whole sign-in rather than just itself."
    checked: root.current("calendar", false) === true
    onClicked: root.change("calendar", !(root.current("calendar", false) === true))
  }

  Toggle {
    width: parent.width
    // Meaningless without a calendar to answer for, so it is dimmed rather
    // than sitting there taking clicks that do nothing - the same shape as
    // the presence session above.
    enabled: root.current("calendar", false) === true
    opacity: enabled ? 1.0 : 0.5
    label: "Answer and create meetings"
    description: "Accept, tentative and decline, booking a meeting with people in it, and calling one off. Asks for Calendars.ReadWrite in place of Calendars.Read - also ordinary user consent, but a registration declares the two separately, so yours has to list it. Takes effect at the next sign-in."
    checked: root.current("calendarWrite", false) === true
    onClicked: root.change("calendarWrite", !(root.current("calendarWrite", false) === true))
  }

  Row {
    spacing: Style.spacing.md

    Dropdown {
      width: Style.space(180)
      label: "Opens on"
      options: Model.calendarViewNames()
      value: String(root.current("calendarView", "week"))
      onValueChanged: if (value !== root.current("calendarView", "week"))
        root.change("calendarView", value)
    }

    Dropdown {
      width: Style.space(160)
      label: "Weeks start on"
      options: ["monday", "sunday"]
      value: String(root.current("weekStart", "monday"))
      onValueChanged: if (value !== root.current("weekStart", "monday"))
        root.change("weekStart", value)
    }
  }

  Toggle {
    width: parent.width
    enabled: root.current("calendar", false) === true
    opacity: enabled ? 1.0 : 0.5
    label: "Tell me when a meeting is about to start"
    description: "A notification a few minutes before each one, which opens it where the Join button is. Nothing you have declined is announced, and neither is anything that was already under way when the shell started. Needs the notification setting above."
    checked: root.current("meetingReminders", true) !== false
    onClicked: root.change("meetingReminders", !(root.current("meetingReminders", true) !== false))
  }

  NumberField {
    label: "Say so this long before (minutes)"
    from: 1
    to: 60
    stepSize: 1
    value: parseInt(String(root.current("reminderMinutes", 5)), 10) || 5
    onValueChanged: if (value !== parseInt(String(root.current("reminderMinutes", 5)), 10))
      root.change("reminderMinutes", value)
  }

  // ---------------- which calendars ----------------
  //
  // A mailbox holds more than one: the user's own extra calendars, the
  // holiday feeds Outlook subscribes to, and every calendar somebody else
  // shared and they added. Nothing here needs a new permission - Graph serves
  // all of them out of the same mailbox - so this is a list to tick, not
  // another sign-in.
  Column {
    width: parent.width
    spacing: Style.spacing.xs
    visible: !!root.service && root.service.hasCalendar

    // Asked for when the form opens rather than held for the life of the
    // window, so a calendar shared this morning is in the list this afternoon.
    onVisibleChanged: if (visible && root.service) root.service.loadMailboxCalendars()

    Text {
      width: parent.width
      text: "Calendars to show"
      textFormat: Text.PlainText
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      width: parent.width
      text: "Everything in your mailbox, including calendars other people shared with "
            + "you. Tick none and the pane draws your calendar alone, the way it always "
            + "has. A meeting in somebody else's calendar can be read and joined but not "
            + "answered - it is their invitation, not yours."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: !!root.service && root.service.mailboxCalendarsLoading
      text: "Reading your calendars…"
      textFormat: Text.PlainText
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: !!root.service && root.service.mailboxCalendarsError !== ""
      text: root.service ? root.service.mailboxCalendarsError : ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: root.service ? root.service.mailboxCalendars : []

      Toggle {
        required property var modelData
        width: root.width
        label: String(modelData.name || "")
              + (modelData.shared === true
                 ? "  ·  " + String((modelData.owner || {}).address || "shared") : "")
              + (modelData["default"] === true ? "  ·  your calendar" : "")
        checked: root.pickedCalendars().indexOf(String(modelData.id)) !== -1
        onClicked: root.togglePickedCalendar(String(modelData.id))
      }
    }

    Text {
      width: parent.width
      visible: root.pickedCalendars().length > Model.calendarSourceCap()
      text: "Only the first " + Model.calendarSourceCap() + " are drawn - each one is a "
            + "request of its own, and a week that takes a dozen round trips to appear "
            + "is not a week anybody waits for."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.signedIn && root.service.wantCalendar
             && !root.service.hasCalendar
    text: "This sign-in cannot read your calendar yet. Sign in again to ask for Calendars.Read."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.signedIn && root.service.wantCalendarWrite
             && root.service.hasCalendar && !root.service.canWriteCalendar
    text: "This sign-in can read your calendar but not change it. Sign in again to ask for Calendars.ReadWrite."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  PanelSeparator { width: parent.width }

  // ---------------- your own presence ----------------

  PanelSectionHeader { width: parent.width; text: "Your presence" }

  Toggle {
    width: parent.width
    label: "Set your presence from this window"
    description: "The p key and the status chip in the header: Available, Busy, Do not disturb, Be right back, Appear away, Appear offline, and Automatic to hand it back to Teams. Needs Presence.ReadWrite on your app registration, which an administrator has to consent to for the tenant - reading everybody's presence does not, but writing your own does. Turn this on only once the registration has it and the consent is given, because a scope the registration does not declare fails the whole sign-in rather than just itself. Takes effect at the next sign-in."
    checked: root.current("setPresence", false) === true
    onClicked: root.change("setPresence", !(root.current("setPresence", false) === true))
  }

  Toggle {
    width: parent.width
    // Meaningless on its own - the session it holds open is what a presence
    // you set needs in order to show - so it is dimmed until the one above it
    // is on rather than sitting there taking clicks that do nothing.
    enabled: root.current("setPresence", false) === true
    opacity: enabled ? 1.0 : 0.5
    label: "Let Teams see you at this machine"
    description: "A presence you set only shows while Teams believes you are signed in somewhere - with no Teams client running anywhere you are Offline whatever you pick. This makes the plugin one of those clients: available while somebody is at the machine, away once nobody is, renewed every twenty minutes and let go when the shell stops. It says nothing else - not in a call, not presenting - because it does not know that and will not invent it."
    checked: root.current("holdPresence", false) === true
    onClicked: root.change("holdPresence", !(root.current("holdPresence", false) === true))
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.signedIn && root.service.wantPresence
             && !root.service.canSetPresence
    text: "This sign-in cannot set your presence yet. Sign in again to ask for Presence.ReadWrite - if the sign-in then fails, the tenant has not consented to it."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  PanelSeparator { width: parent.width }

  // ---------------- where you are working from ----------------
  //
  // Two things: whether the picker may name a building, and which network
  // means which one. The second is deliberately not a text field of SSIDs and
  // GUIDs - it is the network you are on now and a list of buildings to point
  // it at, because the one moment you certainly know which building a wifi
  // belongs to is while you are standing in it.

  PanelSectionHeader { width: parent.width; text: "Where you are working from" }

  Toggle {
    width: parent.width
    // Needs a registration of your own, not only the presence setting. The
    // plugin's shared registration does not ask for Place.Read.All and will
    // not: it is admin consent, and it would be put to every other
    // organisation signing in through the same app. Disabled rather than
    // allowed and then refused, because the refusal costs the whole sign-in.
    //
    // And "your own" is not "the field is filled in": the shared id typed out
    // in full is still the shared id, and a config with it written there
    // explicitly is exactly the one this used to let through.
    // Always switchable *off*, only switchable on with a registration of your
    // own. A disabled toggle that is already ticked is a setting nobody can
    // undo - and a config carrying `readPlaces` against the shared id has a
    // sign-in that will be refused until it is undone.
    enabled: root.current("setPresence", false) === true
             && (root.ownRegistration || root.current("readPlaces", false) === true)
    opacity: enabled ? 1.0 : 0.5
    label: "List your buildings"
    description: "Fetches your tenant's buildings so the picker and the rules below can name one instead of saying just \"In the office\". Needs Place.Read.All on an app registration of your own - the plugin's shared one does not ask for it, because it is admin consent and every other organisation signing in through the same app would be asked for it too. Everything else here works without this: a building's id can be used on any sign-in, and you can give it a name below. Takes effect at the next sign-in."
    checked: root.current("readPlaces", false) === true
    onClicked: root.change("readPlaces", !(root.current("readPlaces", false) === true))
  }

  Text {
    width: parent.width
    visible: root.current("setPresence", false) === true && !root.ownRegistration
    text: String(root.current("clientId", "")).trim() === ""
      ? "Listing buildings needs your own Azure client id above, with Place.Read.All added to that registration. Naming a building by hand needs neither - see below."
      : "That is this plugin's own shared app registration, which does not ask for Place.Read.All - it is admin consent, and every other organisation signing in through the same app would be asked for it too. Register one of your own and put its id above. Naming a building by hand needs no permission at all - see below."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(Color.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.signedIn && root.service.wantPlaces
             && !root.service.canReadPlaces
    text: "This sign-in cannot list your buildings yet. Sign in again to ask for Place.Read.All - if the sign-in then fails, the tenant has not consented to it."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.buildingsNote !== ""
    text: root.service ? root.service.buildingsNote : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(Color.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    visible: !!root.service && root.service.buildingsError !== ""
    text: root.service ? root.service.buildingsError : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // ---- buildings you know about, without asking Graph ----------------------

  Column {
    width: parent.width
    spacing: Style.spacing.sm
    visible: !!root.service && root.service.canSetLocation

    Text {
      width: parent.width
      text: "Which buildings you know"
      textFormat: Text.PlainText
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      width: parent.width
      text: "A building is a place id, and setting one needs no permission at all - only listing them does. So a building can be named here instead, and then used by name in the rules below and in the picker."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // The one place an id turns up on its own: your own work location. If any
    // Teams client has ever put you in a building - the Windows one does it
    // from the wifi - Graph hands the id straight back on your presence, and
    // this is that id, waiting to be given a name.
    LabeledField {
      width: parent.width
      visible: root.unnamedPlaceHere() !== ""
      label: "Graph puts you in place " + root.unnamedPlaceHere()
      placeholder: "what you call it"
      hint: "Teams has reported this building for you, so the id is right. Name it and the picker and the rules can use the name."
      value: ""
      onEdited: function(value) { root.nameBuilding(root.unnamedPlaceHere(), value) }
    }

    // And the way in when no id has turned up on its own, which was missing
    // and is the whole reason a building could not be mapped: the auto-detected
    // one only appears once some Teams client has put you in a building, and on
    // a desktop where none ever has, that is never.
    Text {
      width: parent.width
      text: "Add one by hand:"
      textFormat: Text.PlainText
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    LabeledField {
      width: parent.width
      label: "Place id"
      placeholder: "eb706f15-137e-4722-b4d1-b601481d9251"
      hint: "From whoever runs Microsoft Places (Get-Place -Type Building), or from the Places app. Nothing here is sent anywhere until a rule or the picker uses it."
      value: root.draftPlaceId
      onEdited: function(value) { root.draftPlaceId = value }
    }

    LabeledField {
      width: parent.width
      label: "What you call it"
      placeholder: "Hauptgebäude"
      hint: "Only for you - the rules and the picker read this name, and Graph never sees it."
      value: root.draftPlaceName
      onEdited: function(value) { root.draftPlaceName = value }
    }

    Text {
      width: parent.width
      // A caution rather than a refusal: the shape is what Places generates,
      // but being certain enough about somebody else's id format to block on
      // it is not something to be certain about.
      visible: root.draftPlaceId.trim() !== "" && !Model.looksLikePlaceId(root.draftPlaceId)
      text: "That does not look like a place id - they are of the form eb706f15-137e-4722-b4d1-b601481d9251. It will be sent as written, and Graph will refuse it if it is wrong."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Button {
      text: "Add this building"
      bordered: true
      enabled: root.draftPlaceId.trim() !== "" && root.draftPlaceName.trim() !== ""
      foreground: enabled ? Color.accent : Qt.darker(Color.foreground, 1.6)
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      onClicked: {
        root.nameBuilding(root.draftPlaceId.trim(), root.draftPlaceName.trim())
        root.draftPlaceId = ""
        root.draftPlaceName = ""
      }
    }

    Text {
      width: parent.width
      visible: root.unnamedPlaceHere() === "" && root.nameRules().length === 0
      text: "No building id has turned up on its own yet - one appears above the first time any Teams client reports you in a building. Until then, type one in. Or add Place.Read.All to a registration of your own and let the whole list come from Graph."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: Model.namedBuildings(root.nameRules())

      Row {
        required property var modelData
        width: root.width
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: root.width - forgetName.width - Style.spacing.sm * 2
          text: String(modelData.name) + "  ·  " + String(modelData.id)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Qt.darker(Color.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          id: forgetName
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F0156}"   // nf-md-close
          tooltipText: "Forget this name"
          foreground: Color.foreground
          onClicked: root.dropName(String(modelData.id) + " = " + String(modelData.name))
        }
      }
    }
  }

  // ---- this network, and what it means -------------------------------------

  Column {
    width: parent.width
    spacing: Style.spacing.sm
    visible: !!root.service && root.service.canSetLocation

    Text {
      width: parent.width
      text: root.service && String(root.service.currentSsid || "") !== ""
        ? "You are on " + String(root.service.currentSsid) + ". What is that?"
        : "This machine is on no wifi network, so there is nothing to point at a building. Rules already made still apply when you are back on one."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      width: parent.width
      text: "Teams on Windows reads this from the tenant's own wifi list; nothing in Graph hands that over, so this is your copy of the part that concerns you. Whatever you tick is reported as an automatic location, which a location you pick by hand still beats - and it is withdrawn when this machine goes to a network you have said nothing about."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // The thing that makes all of this look broken when it is working.
    // A location picked by hand outranks the automatic layer *until it is
    // handed back*, so somebody who tried the picker once - which is exactly
    // what anybody does first - sees their own choice for ever and concludes
    // the wifi does nothing.
    Text {
      width: parent.width
      visible: !!root.service && root.wifiRules().length > 0
               && !!root.service.myLocation
               && String(root.service.myLocation.source) === "manual"
      text: {
        if (!root.service) return ""
        var wanted = root.service.wifiLocation
        var says = wanted && String(wanted.label || "") !== ""
          ? "your wifi says " + String(wanted.label)
          : "your wifi has something to say about this network"
        return "A work location you picked by hand is showing instead - "
             + says + ", and a hand-picked one outranks it until you hand it back. "
             + "Press w then 0 in the window, or pick Automatic in the location menu."
      }
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // The buildings first, because a building is the whole point of doing
    // this from here rather than in a text field.
    Repeater {
      model: root.service && String(root.service.currentSsid || "") !== ""
             ? root.service.buildings : []

      Toggle {
        required property var modelData
        width: root.width
        label: String(modelData.name || "")
              + (String(modelData.label || "") !== ""
                 ? "  ·  " + String(modelData.label) : "")
        // Written as the building's name rather than its id: a rule anybody
        // can read is a rule anybody can fix, and Model.buildingNamed resolves
        // either. A renamed building then shows up as a rule with a problem
        // instead of one that quietly stops firing.
        checked: root.ruleForHere().toLowerCase() === String(modelData.name || "").toLowerCase()
        onClicked: root.mapHere(root.ruleForHere().toLowerCase()
                                === String(modelData.name || "").toLowerCase()
                                ? "" : String(modelData.name || ""))
      }
    }

    // And the three that need no building, including the one that says to
    // keep quiet about this network.
    Repeater {
      model: root.service && String(root.service.currentSsid || "") !== ""
        ? [{ target: "office", label: "In the office", hint: "no particular building" },
           { target: "remote", label: "Remote", hint: "working, but not in the building" },
           { target: "timeoff", label: "Time off", hint: "not working at all" },
           { target: "none", label: "Report nothing here",
             hint: "withdraw what this machine said and let your schedule show through" }]
        : []

      Toggle {
        required property var modelData
        width: root.width
        label: String(modelData.label) + "  ·  " + String(modelData.hint)
        checked: root.ruleForHere().toLowerCase() === String(modelData.target)
        onClicked: root.mapHere(root.ruleForHere().toLowerCase() === String(modelData.target)
                                ? "" : String(modelData.target))
      }
    }
  }

  // ---- every rule, including the networks you are not on -------------------

  Column {
    width: parent.width
    spacing: Style.spacing.xs
    visible: root.wifiRules().length > 0

    Text {
      width: parent.width
      text: "Networks you have mapped"
      textFormat: Text.PlainText
      color: Qt.darker(Color.foreground, 1.2)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Repeater {
      model: Model.wifiRuleRows(root.wifiRules(),
                                root.service ? root.service.buildings : [])

      // A row rather than a Toggle: these are the ones for networks this
      // machine is not on, so there is nothing to tick - only what it says
      // and a way to take it off.
      Row {
        required property var modelData
        width: root.width
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: root.width - dropButton.width - Style.spacing.sm * 2
          // The problem instead of the answer where there is one. A rule
          // pointing at a building nobody answers to does nothing at all,
          // and doing nothing quietly is the failure worth naming.
          text: (String(modelData.ssid) === "*" ? "any other network" : String(modelData.ssid))
                + "  →  "
                + (String(modelData.problem) !== ""
                   ? String(modelData.target) + " — " + String(modelData.problem)
                   : String(modelData.label))
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: String(modelData.problem) !== ""
                 ? Color.urgent : Qt.darker(Color.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          id: dropButton
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F0156}"   // nf-md-close
          tooltipText: "Forget this network"
          foreground: Color.foreground
          onClicked: root.dropRule(String(modelData.rule))
        }
      }
    }

    Text {
      width: parent.width
      text: "A network with no rule leaves your work location alone rather than clearing it - tethering to a phone should not announce anything. Add \"any other network\" by hand in shell.json as `* = remote` if you want one."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  PanelSeparator { width: parent.width }

  // ---------------- saving ----------------
  //
  // No Save button: there is nothing for one to do. What is left here is a
  // line saying where the writing got to, and a way out.

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
      text: "Close"
      bordered: true
      foreground: Color.foreground
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      onClicked: root.close()
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      // Three states worth telling apart, and the third is the reassuring
      // one: a panel that says nothing after a change looks like a panel that
      // ignored it.
      text: {
        if (root.service && root.service.saving) return "Saving…"
        if (root.dirty) return "Saving in a moment…"
        if (root.service && root.service.saveError !== "") return ""
        return "Changes apply as you make them"
      }
      textFormat: Text.PlainText
      color: Qt.darker(Color.foreground, root.dirty ? 1.2 : 1.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
