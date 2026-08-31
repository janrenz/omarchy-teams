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
      channels: data.channels === true,
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
    userId: "", channels: false, chats: [], teams: [], unreadCount: 0,
    errorCode: "", errorMessage: "", warnings: []
  }
}

// The same view with a different team tree on it. Lets the sidebar draw the
// tree from the last fetch that asked for one, rather than blinking empty on
// every poll that skipped it.
function withTeams(view, teams) {
  var copy = {}
  for (var key in view) copy[key] = view[key]
  copy.teams = teams || []
  return copy
}

// The sidebar: chats first, then each team with its channels indented under
// it. Chats lead because they are where someone is being spoken to directly -
// a channel is a room you visit, a chat is a tap on the shoulder.
function conversationRows(view) {
  var rows = []
  var chats = (view && view.chats) || []

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

  var teams = (view && view.teams) || []
  for (var t = 0; t < teams.length; t++) {
    var team = teams[t]
    rows.push({ kind: "heading", key: "h:" + team.id, title: String(team.name || ""), depth: 0 })
    var channels = team.channels || []
    for (var n = 0; n < channels.length; n++) {
      var channel = channels[n]
      rows.push({
        kind: "channel",
        key: "channel:" + channel.id,
        id: String(channel.id || ""),
        teamId: String(channel.teamId || team.id || ""),
        title: "# " + String(channel.name || ""),
        subtitle: String(channel.description || ""),
        when: "",
        // Graph does not say what is unread in a channel, so nothing is
        // claimed. A dot that never lit would be worse than no dot.
        unread: false,
        depth: 1
      })
    }
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
  for (var i = 0; i < (rows || []).length; i++) if (rows[i].kind !== "heading") out.push(i)
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
      last.lines.push({ id: message.id, text: message.text, when: message.when, edited: message.edited === true })
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
      lines: [{ id: message.id, text: message.text, when: message.when, edited: message.edited === true }]
    })
  }
  return groups
}
