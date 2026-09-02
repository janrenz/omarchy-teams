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
    canSetPresence: false, me: null,
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
                links: message.links || [],
                reactions: message.reactions || [] }]
    })
  }
  return groups
}
