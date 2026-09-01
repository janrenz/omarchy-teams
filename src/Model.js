.pragma library

// Shaping only: no Qt types, no network, nothing that needs a running shell.
// Kept that way so the layout maths can be tested with node, the way the
// Office 365 plugin tests its own.

function parseJson(raw, fallback) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    return parsed === null ? fallback : parsed
  } catch (e) {
    return fallback
  }
}

function oneLine(text, maxLength) {
  var flat = String(text || "").replace(/\s+/g, " ").trim()
  if (maxLength && flat.length > maxLength) return flat.substring(0, maxLength - 1) + "…"
  return flat
}

// Text handed to something the shell draws for us - a bar tooltip - where a
// Text item in the shell's own code renders it and we cannot pin it to
// PlainText from here. Qt's AutoText treats a stray `<` as the start of markup,
// and markup fetches what it is told to fetch; a chat message is exactly the
// place a crafted one would arrive. Taking the `<` away takes the decision away.
function plainText(value) {
  return String(value === undefined || value === null ? "" : value).replace(/</g, "")
}

// How much room the window gives things.
//
// One multiplier over the shell's own spacing tokens rather than a set of
// hand-picked pixel values: the theme already decides what "a gap" is, and
// this says how generous to be with it. Sizes still scale with the font that
// way, which hand-picked numbers would stop doing.
// The range is wide because the tokens it multiplies are small. The shell's
// spacing steps are 2, 4, 6, 8px; 1.4 times 4px is one pixel of difference,
// which is what the first attempt at this shipped and what nobody could see.
var DENSITY = { compact: 0.6, cosy: 1.0, roomy: 1.7, spacious: 2.4 }

function densityScale(name) {
  var found = DENSITY[String(name || "").toLowerCase()]
  return typeof found === "number" ? found : DENSITY.cosy
}

function densityNames() {
  return ["compact", "cosy", "roomy", "spacious"]
}

// A message as markup with its links clickable.
//
// The text is escaped FIRST and links added afterwards, never the other way
// round. The words come from whoever sent the message, so anything they wrote
// that looks like markup has to stop being markup before this builds any - and
// what this builds is only ever an <a>. Rich text fetches what it is told to
// fetch, so a message must never get to choose the tags.
//
// Only http, https and mailto become links. A javascript: or data: URL is left
// as the plain words it was.
var LINKABLE = /\b(?:https?:\/\/|www\.)[^\s<>"'\)\]]+|(?:\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b)/g

function escapeHtml(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function hasLink(text) {
  LINKABLE.lastIndex = 0
  return LINKABLE.test(String(text || ""))
}

function linkify(text) {
  var escaped = escapeHtml(text)
  LINKABLE.lastIndex = 0
  var html = escaped.replace(LINKABLE, function(match) {
    // Trailing punctuation is nearly always the sentence, not the address.
    var trail = ""
    while (match.length > 0 && ".,;:!?".indexOf(match.charAt(match.length - 1)) !== -1) {
      trail = match.charAt(match.length - 1) + trail
      match = match.substring(0, match.length - 1)
    }
    var href = match
    if (match.indexOf("@") !== -1 && match.indexOf("//") === -1) href = "mailto:" + match
    else if (match.toLowerCase().indexOf("www.") === 0) href = "https://" + match
    return '<a href="' + href + '">' + match + '</a>' + trail
  })
  // Newlines carry no meaning in rich text, and a transcript is full of them.
  return html.replace(/\n/g, "<br>")
}

// The one account, as a view the UI can bind to without null checks.
function accountView(snapshot, alias) {
  var accounts = (snapshot && snapshot.accounts) || []
  for (var i = 0; i < accounts.length; i++) {
    if (String(accounts[i].alias) !== String(alias)) continue
    var data = accounts[i]
    return {
      alias: String(data.alias || ""),
      ok: data.ok === true,
      loaded: true,
      username: data.username || "",
      displayName: data.displayName || "",
      userId: data.userId || "",
      // Every capability the helper reports has to be carried across here.
      // Missing one does not fail loudly: the flag reads undefined, which is
      // falsey, so the feature quietly stays switched off and the button
      // offering to enable it stays switched on for ever.
      channels: data.channels === true,
      canMarkRead: data.canMarkRead === true,
      canStartChat: data.canStartChat === true,
      chats: data.chats || [],
      teams: data.teams || [],
      unreadCount: Number(data.unreadCount || 0),
      errorCode: data.error ? String(data.error.code || "") : "",
      errorMessage: data.error ? String(data.error.message || "") : "",
      warnings: data.warnings || []
    }
  }
  return {
    alias: String(alias || ""), ok: false, loaded: false, username: "", displayName: "",
    userId: "", channels: false, canMarkRead: false, canStartChat: false,
    chats: [], teams: [], unreadCount: 0,
    errorCode: "", errorMessage: "", warnings: []
  }
}

// The sidebar: chats, then teams as closed folders you open.
//
// Chats lead because they are where someone is speaking to you directly - a
// channel is a room you visit, a chat is a tap on the shoulder.
//
// Teams are closed until opened, and their channels are fetched at that
// moment. Listing every channel of every team up front is one request per team
// and, on an account in 28 of them, two hundred rows nobody scrolls.
function conversationRows(view, expanded, channelsByTeam, loadingTeamId, unreadOnly) {
  var rows = []
  var open = expanded || {}
  var channels = channelsByTeam || {}
  var onlyUnread = unreadOnly === true
  var all = (view && view.chats) || []
  var chats = onlyUnread ? all.filter(function(chat) { return chat.unread === true }) : all

  if (chats.length > 0) rows.push({ kind: "heading", key: "h:chats", title: "Chats", depth: 0 })
  for (var c = 0; c < chats.length; c++) {
    var chat = chats[c]
    rows.push({
      kind: "chat",
      key: "chat:" + chat.id,
      id: String(chat.id || ""),
      teamId: "",
      title: String(chat.title || ""),
      subtitle: subtitleFor(chat),
      when: String(chat.when || ""),
      unread: chat.unread === true,
      depth: 0
    })
  }

  // Filtering to unread leaves the teams out rather than listing them all
  // under a filter they cannot answer: Graph exposes no read state for a
  // channel, so every one of them would be neither kept nor excluded.
  if (onlyUnread) {
    if (rows.length === 0)
      rows.push({ kind: "note", key: "note:nothing-unread", title: "Nothing unread",
                  subtitle: "", when: "", unread: false, depth: 0 })
    return rows
  }

  var teams = (view && view.teams) || []
  if (teams.length > 0) rows.push({ kind: "heading", key: "h:teams", title: "Teams", depth: 0 })
  for (var t = 0; t < teams.length; t++) {
    var team = teams[t]
    var id = String(team.id || "")
    var isOpen = open[id] === true
    var loading = String(loadingTeamId || "") === id
    rows.push({
      kind: "team",
      key: "team:" + id,
      id: id,
      teamId: id,
      title: String(team.name || ""),
      subtitle: "",
      when: "",
      unread: false,
      expanded: isOpen,
      loading: loading,
      depth: 0
    })
    if (!isOpen) continue

    var list = channels[id] || []
    for (var n = 0; n < list.length; n++) {
      var channel = list[n]
      rows.push({
        kind: "channel",
        key: "channel:" + channel.id,
        id: String(channel.id || ""),
        teamId: id,
        title: "# " + String(channel.name || ""),
        subtitle: String(channel.description || ""),
        when: "",
        // Graph does not say what is unread in a channel, so nothing is
        // claimed. A dot that never lit would be worse than no dot.
        unread: false,
        depth: 1
      })
    }
    if (list.length === 0 && !loading)
      rows.push({ kind: "note", key: "note:" + id, title: "No channels", subtitle: "",
                  when: "", unread: false, depth: 1 })
  }
  return rows
}

function subtitleFor(chat) {
  var who = String(chat.lastFrom || "").trim()
  var text = oneLine(chat.lastText || "", 120)
  if (who === "" ) return text
  if (text === "") return ""
  return who + ": " + text
}

// Rows that a cursor may land on - never a heading.
function selectableRows(rows) {
  var out = []
  var list = rows || []
  for (var i = 0; i < list.length; i++) {
    var kind = list[i].kind
    // A team is a target: opening it is an action. A heading and a "no
    // channels" note are not - a cursor that stops on them stops on nothing.
    if (kind === "chat" || kind === "channel" || kind === "team") out.push(i)
  }
  return out
}

function parseDate(value) {
  if (!value) return null
  var when = new Date(String(value))
  return isNaN(when.getTime()) ? null : when
}

function pad(value) { return value < 10 ? "0" + value : String(value) }

function timeOfDay(date) {
  return pad(date.getHours()) + ":" + pad(date.getMinutes())
}

// "14:02" today, "Tue 14:02" this week, "3 Mar" older. A transcript wants the
// clock; a chat list wants to know how stale it is.
function whenLabel(value, now) {
  var when = parseDate(value)
  if (!when) return ""
  var today = now || new Date()
  var sameDay = when.getFullYear() === today.getFullYear()
    && when.getMonth() === today.getMonth()
    && when.getDate() === today.getDate()
  if (sameDay) return timeOfDay(when)
  var days = Math.floor((today - when) / 86400000)
  var weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][when.getDay()]
  if (days < 7) return weekday + " " + timeOfDay(when)
  var month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][when.getMonth()]
  return when.getDate() + " " + month
}

// Consecutive messages from one person are one block: repeating the name on
// every line turns a conversation into a list of labels.
function groupMessages(messages, meId) {
  var groups = []
  var list = messages || []
  for (var i = 0; i < list.length; i++) {
    var message = list[i]
    var mine = String(message.fromId || "") === String(meId || "") && String(meId || "") !== ""
    var last = groups.length > 0 ? groups[groups.length - 1] : null
    if (last && !message.system && !last.system && String(last.fromId) === String(message.fromId || "")) {
      last.lines.push({ id: message.id, text: message.text, when: message.when,
                        edited: message.edited === true, images: message.images || [],
                        reactions: message.reactions || [] })
      last.when = message.when
      continue
    }
    groups.push({
      key: String(message.id || i),
      from: String(message.from || (message.system ? "" : "Someone")),
      fromId: String(message.fromId || ""),
      mine: mine,
      system: message.system === true,
      when: message.when,
      lines: [{ id: message.id, text: message.text, when: message.when,
                edited: message.edited === true, images: message.images || [],
                reactions: message.reactions || [] }]
    })
  }
  return groups
}
