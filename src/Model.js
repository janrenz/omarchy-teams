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

// Whether you are already one of the people who reacted with this emoji.
//
// It decides which way a chip toggles: clicking one you are part of takes
// yours off, clicking one you are not adds it. Kept here rather than inline in
// the delegate so the decision can be tested - getting it backwards would look
// like reactions that refuse to go away.
function reactionIsMine(reactions, emoji) {
  var rows = reactions || []
  var want = String(emoji || "")
  for (var i = 0; i < rows.length; i++)
    if (String(rows[i].emoji) === want) return rows[i].mine === true
  return false
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

function hasLink(text, links) {
  if (links && links.length > 0) return true
  LINKABLE.lastIndex = 0
  return LINKABLE.test(String(text || ""))
}

// Only somewhere to go, never something to run - the same three schemes the
// Python side allows, checked again here because this is what builds the tag.
function safeHref(href) {
  var url = String(href || "").trim()
  var lowered = url.toLowerCase()
  if (lowered.indexOf("http://") === 0 || lowered.indexOf("https://") === 0
      || lowered.indexOf("mailto:") === 0) return url
  return ""
}

// One anchor, out of text that has not been escaped yet.
function anchor(href, label, tint) {
  var url = escapeHtml(href)
  var words = escapeHtml(label)
  if (tint === "") return '<a href="' + url + '">' + words + '</a>'
  // Both the style and the font tag: Qt honours one or the other depending
  // on the rich-text path, and an uncoloured link is the thing being fixed.
  return '<a href="' + url + '" style="color:' + tint + '">'
    + '<font color="' + tint + '">' + words + '</font></a>'
}

// `links` are the spans teams.py found in the message's own markup - the ones
// where the address is in the href and nowhere in the words, which is what the
// composer's link button writes. Text outside those spans still gets the
// addresses somebody typed out in full.
//
// `color` is a hex string from the theme's own palette. A TextEdit has no
// linkColor - that is a Text property - so an anchor rendered in one comes out
// in Qt's default blue, which belongs to no theme. Since this builds the
// anchor, it can say what colour it should be.
function linkify(text, color, links) {
  var tint = String(color || "")
  var plain = String(text === undefined || text === null ? "" : text)
  var spans = usableSpans(plain, links)
  var html = ""
  var at = 0
  for (var i = 0; i < spans.length; i++) {
    html += autoLinked(plain.substring(at, spans[i].start), tint)
    html += anchor(spans[i].href, plain.substring(spans[i].start, spans[i].end), tint)
    at = spans[i].end
  }
  html += autoLinked(plain.substring(at), tint)
  // Newlines carry no meaning in rich text, and a transcript is full of them.
  return html.replace(/\n/g, "<br>")
}

// The spans worth drawing: in order, inside the text, not overlapping, and
// pointing somewhere it is safe to go. Offsets come from a message somebody
// else wrote, so none of that is assumed.
function usableSpans(plain, links) {
  var list = []
  var all = links || []
  for (var i = 0; i < all.length; i++) {
    var href = safeHref(all[i] && all[i].href)
    var start = Number(all[i] && all[i].start)
    var end = Number(all[i] && all[i].end)
    if (href === "" || !isFinite(start) || !isFinite(end)) continue
    if (start < 0 || end > plain.length || end <= start) continue
    list.push({ start: start, end: end, href: href })
  }
  list.sort(function(a, b) { return a.start - b.start })
  var kept = []
  var reached = 0
  for (var j = 0; j < list.length; j++) {
    if (list[j].start < reached) continue
    kept.push(list[j])
    reached = list[j].end
  }
  return kept
}

// The prose between the links: escaped, with the addresses somebody typed out
// in full turned into links of their own. Teams marks up a pasted URL, but not
// one that arrives in a message the API hands over as plain text.
function autoLinked(plain, tint) {
  var escaped = escapeHtml(plain)
  LINKABLE.lastIndex = 0
  return escaped.replace(LINKABLE, function(match) {
    // Trailing punctuation is nearly always the sentence, not the address.
    var trail = ""
    while (match.length > 0 && ".,;:!?".indexOf(match.charAt(match.length - 1)) !== -1) {
      trail = match.charAt(match.length - 1) + trail
      match = match.substring(0, match.length - 1)
    }
    var href = match
    if (match.indexOf("@") !== -1 && match.indexOf("//") === -1) href = "mailto:" + match
    else if (match.toLowerCase().indexOf("www.") === 0) href = "https://" + match
    if (tint === "") return '<a href="' + href + '">' + match + '</a>' + trail
    return '<a href="' + href + '" style="color:' + tint + '">'
      + '<font color="' + tint + '">' + match + '</font></a>' + trail
  })
}

// Presence, in the theme's own colours rather than hardcoded traffic lights.
//
// The four states are Microsoft's nine availabilities grouped down to what is
// worth drawing: "Available" and "AvailableIdle" are the same dot to a reader.
// The grouping happens in teams.py; this only says what colour it wears.
function presenceColor(state, palette) {
  var colors = palette || {}
  switch (String(state || "")) {
    case "available": return colors.green || ""
    case "busy":      return colors.red || ""
    case "away":      return colors.yellow || colors.orange || ""
    case "offline":   return colors.muted || ""
    default:          return ""
  }
}

function presenceLabel(state, activity) {
  // Graph sends activities as one camel-case word: InAMeeting, OnThePhone,
  // OutOfOffice. Two passes, because a run of capitals needs breaking too -
  // one pass alone turns InAMeeting into "In AMeeting".
  var said = String(activity || "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
  switch (String(state || "")) {
    case "available": return said || "Available"
    case "busy":      return said || "Busy"
    case "away":      return said || "Away"
    case "offline":   return "Offline"
    default:          return ""
  }
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
      canUpload: data.canUpload === true,
      canStartChat: data.canStartChat === true,
      presence: data.presence === true,
      canSetPresence: data.canSetPresence === true,
      calendar: data.calendar === true,
      canWriteCalendar: data.canWriteCalendar === true,
      // The user's own presence, from the same batched request the sidebar's
      // dots come out of. Null until a fetch has answered, which is not the
      // same as being offline - so the chip says nothing rather than guessing.
      me: data.me || null,
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
    userId: "", channels: false, canMarkRead: false, canUpload: false, canStartChat: false, presence: false,
    canSetPresence: false, calendar: false, canWriteCalendar: false, me: null,
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
      presence: (chat.presence && chat.presence.state) ? String(chat.presence.state) : "",
      presenceActivity: (chat.presence && chat.presence.activity) ? String(chat.presence.activity) : "",
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
  if (days < 7) return WEEKDAYS_SHORT[when.getDay()] + " " + timeOfDay(when)
  return when.getDate() + " " + MONTHS_SHORT[when.getMonth()]
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
                        attachments: message.attachments || [],
                        quotes: message.quotes || [],
                        links: message.links || [],
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
                attachments: message.attachments || [],
                quotes: message.quotes || [],
                links: message.links || [],
                reactions: message.reactions || [] }]
    })
  }
  return groups
}

// ---------------------------------------------------------------- calendar
//
// A day is a string, "2026-09-04", and every event arrives from teams.py
// already carrying the one it belongs to. That is deliberate: the helper has
// the machine's timezone and the whole timezone database, and it has already
// decided which local day a UTC instant falls in. Nothing here re-derives
// that - the grouping is a string comparison, and the only dates built here
// are the ones for walking a week forward or naming a month.
//
// Everything below is pure: no Qt, no clock of its own. `now` is passed in
// wherever today matters, so the tests can be about a Tuesday in September
// rather than about the day they happen to run on.

var WEEKDAYS_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var WEEKDAYS_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                     "Friday", "Saturday"]
var MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var MONTHS_LONG = ["January", "February", "March", "April", "May", "June", "July",
                   "August", "September", "October", "November", "December"]

// The four the real client offers, in its order.
function calendarViewNames() {
  return ["day", "work week", "week", "month"]
}

// A Date at local midnight, from a day key. Built out of the three numbers
// rather than by parsing the string: `new Date("2026-09-04")` is midnight
// *UTC*, which is the previous evening for everybody west of Greenwich and
// would shift every date by a day for half the world.
function dateOf(key) {
  var parts = String(key || "").split("-")
  var when = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  return isNaN(when.getTime()) ? null : when
}

function keyOf(date) {
  if (!date) return ""
  return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate())
}

function todayKey(now) {
  return keyOf(now || new Date())
}

// Today, however the caller happens to hold it. The window passes a key
// rather than a Date on purpose: a Date that ticks every minute would rebuild
// every delegate in the grid once a minute, and a key changes at midnight.
function asDayKey(value) {
  return typeof value === "string" ? value : keyOf(value || new Date())
}

// Days added to a key, through a Date so that month ends and daylight saving
// are the calendar's problem rather than ours.
function addDays(key, count) {
  var when = dateOf(key)
  if (!when) return ""
  when.setDate(when.getDate() + Number(count || 0))
  return keyOf(when)
}

function addMonths(key, count) {
  var when = dateOf(key)
  if (!when) return ""
  var wanted = when.getDate()
  when.setDate(1)
  when.setMonth(when.getMonth() + Number(count || 0))
  // The 31st of a month before a 30-day one: keep it inside the month rather
  // than letting it roll over into the next, which is what setDate would do
  // and what makes "next month" skip October when you start on 31 August.
  var lastDay = new Date(when.getFullYear(), when.getMonth() + 1, 0).getDate()
  when.setDate(Math.min(wanted, lastDay))
  return keyOf(when)
}

// The first day of the week a key is in. Monday unless the setting says
// otherwise: which day a week starts on is a local convention, and Graph has
// no opinion about it.
function weekStart(key, sundayFirst) {
  var when = dateOf(key)
  if (!when) return ""
  var offset = sundayFirst === true ? when.getDay() : (when.getDay() + 6) % 7
  when.setDate(when.getDate() - offset)
  return keyOf(when)
}

// The days a view covers, and where a fetch has to start and stop to fill it.
// The month view deliberately runs from the Monday before the 1st to the
// Sunday after the last: the leading and trailing cells are real days with
// real meetings in them, and a grid that left them empty would say the first
// of the month is free when it is not.
function calendarRange(viewName, anchorKey, sundayFirst) {
  var view = String(viewName || "week")
  var anchor = String(anchorKey || "")
  var from = anchor
  var days = 1
  if (view === "day") {
    from = anchor
    days = 1
  } else if (view === "work week") {
    from = addDays(weekStart(anchor, sundayFirst), sundayFirst === true ? 1 : 0)
    days = 5
  } else if (view === "month") {
    var first = dateOf(anchor)
    if (!first) return { from: anchor, days: 1, keys: [anchor], view: view }
    var firstOfMonth = keyOf(new Date(first.getFullYear(), first.getMonth(), 1))
    var lastOfMonth = keyOf(new Date(first.getFullYear(), first.getMonth() + 1, 0))
    from = weekStart(firstOfMonth, sundayFirst)
    var lastCell = addDays(weekStart(lastOfMonth, sundayFirst), 6)
    days = Math.round((dateOf(lastCell) - dateOf(from)) / 86400000) + 1
  } else {
    from = weekStart(anchor, sundayFirst)
    days = 7
  }
  var keys = []
  for (var i = 0; i < days; i++) keys.push(addDays(from, i))
  return { from: from, days: days, keys: keys, view: view }
}

// One step forward or back, in whatever unit the view is made of.
function shiftAnchor(viewName, anchorKey, step, sundayFirst) {
  var view = String(viewName || "week")
  var by = Number(step || 0)
  if (view === "day") return addDays(anchorKey, by)
  if (view === "month") return addMonths(anchorKey, by)
  // A work week steps a whole week, not five days: stepping five would walk
  // the anchor onto a Saturday and the week after that would be the wrong one.
  return addDays(weekStart(anchorKey, sundayFirst), by * 7)
}

// What the toolbar says it is showing. The year is left off when it is this
// one, the way a calendar does - it is the least interesting number there
// and it is on screen at all times.
function rangeLabel(viewName, keys, now) {
  var list = keys || []
  if (list.length === 0) return ""
  var first = dateOf(list[0])
  var last = dateOf(list[list.length - 1])
  if (!first || !last) return ""
  var thisYear = (now || new Date()).getFullYear()
  var year = function (date) {
    return date.getFullYear() === thisYear ? "" : " " + date.getFullYear()
  }
  if (String(viewName) === "day")
    return WEEKDAYS_LONG[first.getDay()] + " " + first.getDate() + " "
           + MONTHS_LONG[first.getMonth()] + year(first)
  if (String(viewName) === "month") {
    // Named for the month it is about, not for the six weeks it draws: the
    // grid starts in August and the user asked for September.
    var middle = dateOf(list[Math.floor(list.length / 2)])
    return MONTHS_LONG[middle.getMonth()] + " " + middle.getFullYear()
  }
  if (first.getMonth() === last.getMonth())
    return first.getDate() + " – " + last.getDate() + " " + MONTHS_LONG[last.getMonth()]
           + year(last)
  return first.getDate() + " " + MONTHS_SHORT[first.getMonth()] + " – "
         + last.getDate() + " " + MONTHS_SHORT[last.getMonth()] + year(last)
}

// Every day an event touches, so a meeting that runs past midnight and a
// three-day absence are both drawn on every day they cover rather than only
// on the one they began.
function eventCoversDay(event, key) {
  var day = String(key || "")
  var from = String((event && event.startDate) || "")
  var to = String((event && event.endDate) || from)
  return from !== "" && from <= day && day <= to
}

function eventsOn(events, key) {
  var found = []
  var list = events || []
  for (var i = 0; i < list.length; i++)
    if (eventCoversDay(list[i], key)) found.push(list[i])
  return found
}

// Where an event sits in a day, in minutes from that day's midnight, clipped
// to the day. A meeting from 23:00 to 01:00 is two blocks - the tail of one
// day and the head of the next - which is what every calendar draws and what
// clipping is for.
function daySpan(event, key) {
  var midnight = dateOf(key)
  if (!midnight) return { start: 0, end: 0 }
  var begins = parseDate(event && event.when)
  var ends = parseDate(event && event.until) || begins
  if (!begins) return { start: 0, end: 0 }
  var start = Math.max(0, Math.round((begins - midnight) / 60000))
  var end = Math.min(1440, Math.round((ends - midnight) / 60000))
  // A zero-length meeting still has to be visible, and a block with no
  // height cannot be clicked.
  if (end <= start) end = Math.min(1440, start + 15)
  return { start: start, end: end }
}

// Side-by-side columns for meetings that overlap, the way a day view has to
// draw them. Events are clustered by overlap - transitively, so three
// meetings chained across an hour share one cluster and the same width - and
// then each is given the leftmost column that is free at its start.
//
// Returns one row per event: the event, and which of how many columns it is
// in. Off by one here is the difference between a readable morning and two
// meetings drawn on top of each other.
function layoutColumns(events, key) {
  var rows = []
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    var span = daySpan(list[i], key)
    rows.push({ event: list[i], start: span.start, end: span.end, column: 0, columns: 1 })
  }
  rows.sort(function (a, b) { return a.start - b.start || a.end - b.end })

  var cluster = []
  var clusterEnd = -1
  var columnCount = 0
  var ends = []
  var settle = function () {
    for (var c = 0; c < cluster.length; c++) cluster[c].columns = Math.max(1, columnCount)
    cluster = []
    columnCount = 0
  }
  for (var r = 0; r < rows.length; r++) {
    var row = rows[r]
    if (cluster.length > 0 && row.start >= clusterEnd) {
      settle()
      ends = []
      clusterEnd = -1
    }
    var placed = -1
    for (var col = 0; col < ends.length; col++) {
      if (ends[col] <= row.start) { placed = col; break }
    }
    if (placed === -1) { placed = ends.length; ends.push(row.end) }
    else ends[placed] = row.end
    row.column = placed
    columnCount = Math.max(columnCount, ends.length)
    cluster.push(row)
    clusterEnd = Math.max(clusterEnd, row.end)
  }
  settle()
  return rows
}

// The days a view is made of, each with what is on it. All-day events go in
// their own strip because they have no place on a clock: an absence that
// covers Tuesday is not a meeting from midnight to midnight.
function calendarDays(events, keys, anchorKey, today) {
  var list = keys || []
  var when_today = asDayKey(today)
  var anchor = dateOf(anchorKey || (list.length > 0 ? list[0] : ""))
  var out = []
  for (var i = 0; i < list.length; i++) {
    var key = list[i]
    var when = dateOf(key)
    if (!when) continue
    var onThisDay = eventsOn(events, key)
    var allDay = []
    var timed = []
    for (var e = 0; e < onThisDay.length; e++) {
      if (onThisDay[e].allDay === true) allDay.push(onThisDay[e])
      else timed.push(onThisDay[e])
    }
    timed.sort(function (a, b) { return String(a.when).localeCompare(String(b.when)) })
    out.push({
      key: key,
      weekday: WEEKDAYS_SHORT[when.getDay()],
      weekdayLong: WEEKDAYS_LONG[when.getDay()],
      day: when.getDate(),
      month: MONTHS_SHORT[when.getMonth()],
      // The first of the month says which month it is, in the one place a
      // month grid needs telling: its own leading and trailing cells.
      firstOfMonth: when.getDate() === 1,
      isToday: key === when_today,
      isPast: key < when_today,
      isWeekend: when.getDay() === 0 || when.getDay() === 6,
      // Only meaningful in the month view, where the grid runs into the
      // months either side and those days are drawn quieter.
      otherMonth: anchor ? when.getMonth() !== anchor.getMonth() : false,
      allDay: allDay,
      timed: timed,
      count: allDay.length + timed.length
    })
  }
  return out
}

// The whole range as one list, which is what a window too narrow for columns
// shows and what the month view's day gets when it is opened. Days with
// nothing on them are kept only when they are the range: an agenda for a
// month should not be thirty "nothing" rows.
function agendaRows(days) {
  var rows = []
  var list = days || []
  var busy = 0
  for (var i = 0; i < list.length; i++) if (list[i].count > 0) busy++
  for (var d = 0; d < list.length; d++) {
    var day = list[d]
    if (day.count === 0 && busy > 0 && list.length > 1) continue
    rows.push({ kind: "day", key: "day:" + day.key, day: day })
    for (var a = 0; a < day.allDay.length; a++)
      rows.push({ kind: "event", key: "event:" + day.key + ":" + day.allDay[a].id,
                  day: day, event: day.allDay[a] })
    for (var t = 0; t < day.timed.length; t++)
      rows.push({ kind: "event", key: "event:" + day.key + ":" + day.timed[t].id,
                  day: day, event: day.timed[t] })
    if (day.count === 0)
      rows.push({ kind: "note", key: "note:" + day.key, day: day })
  }
  return rows
}

// Everything the keyboard can land on, in the order it is drawn - so j and k
// walk a week left to right and top to bottom rather than in whatever order
// the fetch came back in.
function eventCursorKeys(days) {
  var keys = []
  var list = days || []
  for (var d = 0; d < list.length; d++) {
    for (var a = 0; a < list[d].allDay.length; a++)
      keys.push(list[d].key + ":" + list[d].allDay[a].id)
    for (var t = 0; t < list[d].timed.length; t++)
      keys.push(list[d].key + ":" + list[d].timed[t].id)
  }
  return keys
}

function eventCursorKey(dayKey, eventId) {
  return String(dayKey || "") + ":" + String(eventId || "")
}

function clockLabel(value) {
  var when = parseDate(value)
  return when ? timeOfDay(when) : ""
}

// "09:00 – 09:15", or what an event with no clock face is instead.
function eventTimeLabel(event) {
  if (!event) return ""
  if (event.allDay === true) return "All day"
  var from = clockLabel(event.when)
  var to = clockLabel(event.until)
  if (from === "") return ""
  return to === "" || to === from ? from : from + " – " + to
}

// How long, in the words a person would use.
function durationLabel(event) {
  var minutes = Number((event && event.minutes) || 0)
  if (!isFinite(minutes) || minutes <= 0) return ""
  if (event.allDay === true) {
    var days = Math.round(minutes / 1440)
    return days <= 1 ? "All day" : days + " days"
  }
  if (minutes < 60) return minutes + " min"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  return rest === 0 ? hours + " h" : hours + " h " + rest + " min"
}

// What was said to an invitation, in the words the client uses.
function responseLabel(response) {
  switch (String(response || "")) {
    case "accepted":  return "Accepted"
    case "tentative": return "Tentative"
    case "declined":  return "Declined"
    case "pending":   return "No reply yet"
    case "organizer": return "You organised this"
    default:          return ""
  }
}

function showAsLabel(showAs) {
  switch (String(showAs || "")) {
    case "free":            return "Free"
    case "tentative":       return "Tentative"
    case "busy":            return "Busy"
    case "oof":             return "Out of office"
    case "workingelsewhere": return "Working elsewhere"
    default:                return ""
  }
}

// Whether there is a question here for the user to answer. An organiser has
// nothing to accept, an appointment nobody was invited to has nobody to
// answer, and a cancelled meeting has nothing left to say - but an invitation
// already accepted still offers all three, because changing your mind is the
// commonest reason to open one.
function answerable(event) {
  if (!event) return false
  if (event.cancelled === true) return false
  if (event.isOrganizer === true) return false
  return String(event.response || "none") !== "none"
}

// The colour an event wears: what it does to your availability, which is what
// a calendar is read for. Declined and cancelled are drawn as neither - they
// are on the calendar as a record, not as a claim on the time.
function eventTint(event, palette) {
  var colors = palette || {}
  if (!event) return colors.accent || ""
  if (event.cancelled === true || String(event.response) === "declined")
    return colors.muted || ""
  switch (String(event.showAs || "busy")) {
    case "free":             return colors.green || colors.muted || ""
    case "tentative":        return colors.yellow || colors.orange || ""
    case "oof":              return colors.magenta || colors.red || ""
    case "workingelsewhere": return colors.cyan || colors.blue || ""
    default:                 return colors.blue || colors.accent || ""
  }
}

// Who has answered what, counted rather than listed: an invitation to forty
// people is a line of numbers, not forty rows above the agenda.
function attendeeTally(attendees) {
  var tally = { accepted: 0, tentative: 0, declined: 0, pending: 0, total: 0 }
  var list = attendees || []
  for (var i = 0; i < list.length; i++) {
    var response = String(list[i].response || "none")
    tally.total++
    if (tally[response] !== undefined) tally[response]++
    else if (response === "none") tally.pending++
  }
  return tally
}

function attendeeSummary(attendees) {
  var tally = attendeeTally(attendees)
  if (tally.total === 0) return ""
  var parts = []
  if (tally.accepted > 0) parts.push(tally.accepted + " accepted")
  if (tally.tentative > 0) parts.push(tally.tentative + " tentative")
  if (tally.declined > 0) parts.push(tally.declined + " declined")
  if (tally.pending > 0) parts.push(tally.pending + " no reply")
  return parts.join(", ")
}

// Minutes until an event starts. Negative once it has, which is what tells a
// row it is happening now rather than soon.
function minutesUntil(event, now) {
  var begins = parseDate(event && event.when)
  if (!begins) return null
  return Math.round((begins - (now || new Date())) / 60000)
}

function isNow(event, now) {
  var begins = parseDate(event && event.when)
  var ends = parseDate(event && event.until)
  if (!begins || !ends) return false
  var at = now || new Date()
  return begins <= at && at < ends
}

// The one to put in front of somebody: whatever is happening now, or the next
// thing that is not an all-day row and has not been declined. All-day events
// are excluded because "Dana on leave" is not what "next up" means.
function nextUp(events, now) {
  var at = now || new Date()
  var list = events || []
  var best = null
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (event.allDay === true || event.cancelled === true) continue
    if (String(event.response) === "declined") continue
    var ends = parseDate(event.until)
    if (!ends || ends <= at) continue
    if (!best || String(event.when) < String(best.when)) best = event
  }
  return best
}

// What is worth a toast: starting inside the next few minutes, not already
// under way, and not something that was declined. The window checks this on
// every poll, so it has to be a decision and not a timer.
function startingSoon(events, now, withinMinutes) {
  var limit = Number(withinMinutes || 5)
  var soon = []
  var list = events || []
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (event.allDay === true || event.cancelled === true) continue
    if (String(event.response) === "declined") continue
    var minutes = minutesUntil(event, now)
    if (minutes === null || minutes < 0 || minutes > limit) continue
    soon.push(event)
  }
  soon.sort(function (a, b) { return String(a.when).localeCompare(String(b.when)) })
  return soon
}

// Where to scroll a day or week grid so it opens on the working day rather
// than on midnight. The earliest meeting, an hour of air above it, and never
// so late that today's next meeting is off the top.
function firstBusyHour(days, now) {
  var earliest = 24
  var list = days || []
  for (var d = 0; d < list.length; d++) {
    for (var t = 0; t < list[d].timed.length; t++) {
      var begins = parseDate(list[d].timed[t].when)
      if (begins) earliest = Math.min(earliest, begins.getHours())
    }
  }
  if (earliest === 24) earliest = (now || new Date()).getHours()
  return Math.max(0, Math.min(23, earliest - 1))
}

// How far down a grid "now" is, as minutes from midnight - the line every
// calendar draws across today. Null on a day that is not today, because a
// line saying "now" on next Tuesday is a line that is lying.
function nowMinutes(dayKey, now) {
  var at = now || new Date()
  if (keyOf(at) !== String(dayKey || "")) return null
  return at.getHours() * 60 + at.getMinutes()
}

// A meeting proposed by the form, checked before anything is sent. The window
// asks this on every keystroke to know whether Create can be pressed, so it
// says what is wrong rather than only that something is.
function newMeetingProblem(draft) {
  var wanted = draft || {}
  if (String(wanted.subject || "").trim() === "") return "A meeting needs a subject"
  var date = String(wanted.date || "")
  if (!dateOf(date)) return "The date has to be YYYY-MM-DD"
  if (wanted.allDay === true) return ""
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(String(wanted.from || "")))
    return "The start time has to be HH:MM"
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(String(wanted.to || "")))
    return "The end time has to be HH:MM"
  if (String(wanted.to) <= String(wanted.from)) return "A meeting has to end after it starts"
  return ""
}

// The draft as teams.py takes it: wall-clock time with no zone on it, because
// the helper is the side that knows this machine's, and an all-day event
// spans whole days rather than a time of day.
function newMeetingPayload(draft) {
  var wanted = draft || {}
  var date = String(wanted.date || "")
  var allDay = wanted.allDay === true
  var guests = []
  var people = wanted.attendees || []
  for (var i = 0; i < people.length; i++) {
    var address = String(people[i].address || "").trim()
    if (address === "") continue
    guests.push({ address: address, name: String(people[i].name || ""),
                  kind: people[i].kind === "optional" ? "optional" : "required" })
  }
  return {
    subject: String(wanted.subject || "").trim(),
    // The end is exclusive, which for a whole day means the next midnight -
    // the same rule the reading side undoes when it works out which day an
    // all-day event is on.
    start: allDay ? date + "T00:00:00" : date + "T" + String(wanted.from) + ":00",
    end: allDay ? addDays(date, Math.max(1, Number(wanted.days || 1))) + "T00:00:00"
                : date + "T" + String(wanted.to) + ":00",
    allDay: allDay,
    online: wanted.online !== false,
    where: String(wanted.where || "").trim(),
    text: String(wanted.text || ""),
    showAs: allDay ? "free" : "busy",
    attendees: guests
  }
}
