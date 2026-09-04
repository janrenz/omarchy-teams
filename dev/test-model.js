#!/usr/bin/env node
// Tests for Model.js - the shaping the window binds to.
//
//   node dev/test-model.js
//
// Model.js is deliberately free of Qt types so it can be run here: the sidebar
// ordering, the message grouping and the time labels are all decisions worth
// checking without a compositor in the way.

const fs = require("fs")
const path = require("path")

const source = fs
  .readFileSync(path.join(__dirname, "..", "src", "Model.js"), "utf8")
  .replace(".pragma library", "")

const Model = new Function(
  source +
    "; return { accountView, conversationRows, selectableRows, groupMessages, whenLabel, " +
    "subtitleFor, oneLine, plainText, parseJson, linkify, hasLink, escapeHtml, " +
    "densityScale, densityNames, reactionIsMine, presenceColor, presenceLabel, " +
    "calendarViewNames, calendarRange, calendarDays, shiftAnchor, rangeLabel, " +
    "agendaRows, eventCursorKeys, eventCursorKey, daySpan, layoutColumns, " +
    "eventTimeLabel, durationLabel, responseLabel, showAsLabel, answerable, " +
    "eventTint, attendeeSummary, attendeeTally, minutesUntil, isNow, nextUp, " +
    "startingSoon, firstBusyHour, nowMinutes, newMeetingProblem, newMeetingPayload, " +
    "keyOf, dateOf, addDays, addMonths, weekStart, todayKey, clockLabel }"
)()

let passed = 0
const failures = []

function test(name, body) {
  try {
    body()
    passed++
  } catch (error) {
    failures.push(name + ": " + error.message)
  }
}

function eq(actual, expected, what) {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a !== b) throw new Error((what || "") + " expected " + b + " got " + a)
}

function ok(value, what) {
  if (!value) throw new Error(what || "expected truthy")
}

const snapshot = (accounts) => ({ accounts })

// ---------------------------------------------------------------- accountView

test("an account that answered is a loaded view", () => {
  const view = Model.accountView(
    snapshot([{ alias: "work", ok: true, username: "a@b.c", unreadCount: 2, chats: [], teams: [] }]),
    "work"
  )
  ok(view.ok && view.loaded, "should be loaded")
  eq(view.unreadCount, 2)
})

test("an account that has not answered is not loaded, and claims nothing", () => {
  const view = Model.accountView(snapshot([]), "work")
  ok(!view.ok && !view.loaded, "should not be loaded")
  eq(view.unreadCount, 0)
  eq(view.chats, [])
})

test("a failed account carries its reason", () => {
  const view = Model.accountView(
    snapshot([{ alias: "work", ok: false, error: { code: "auth_required", message: "Sign in" } }]),
    "work"
  )
  eq(view.errorCode, "auth_required")
})

test("every field the helper reports survives into the view", () => {
  // This is a cross-check against teams.py rather than a list kept by hand,
  // because the failure it guards is silent: a capability the helper reports
  // and the view drops reads as undefined, which is falsey, so the feature
  // switches itself off and the button offering to turn it on never goes away.
  // That shipped once - canMarkRead and canStartChat were both dropped here.
  const helper = fs.readFileSync(path.join(__dirname, "..", "src", "teams.py"), "utf8")
  const block = helper.slice(helper.indexOf("    result = {"), helper.indexOf('        "warnings": [],'))
  const keys = [...block.matchAll(/^\s*"([a-zA-Z]+)":/gm)].map((m) => m[1])
  ok(keys.length > 5, "did not find the result keys in teams.py: " + keys)

  const rich = {}
  for (const key of keys) rich[key] = true
  rich.alias = "work"
  const view = Model.accountView(snapshot([rich]), "work")

  // "ok" is the request's outcome, not a field of the account.
  const carried = keys.filter((k) => k !== "ok")
  const missing = carried.filter((k) => view[k] === undefined)
  eq(missing, [], "teams.py reports these but accountView drops them")
})

test("the capability flags default to false, never undefined", () => {
  const view = Model.accountView(snapshot([]), "work")
  for (const key of ["channels", "canMarkRead", "canStartChat"])
    eq(view[key], false, key + " should be false when nothing has been fetched")
})

test("another account's data is not this one's", () => {
  const view = Model.accountView(snapshot([{ alias: "other", ok: true, unreadCount: 9 }]), "work")
  eq(view.unreadCount, 0)
})

// ---------------------------------------------------------- conversationRows

const chatty = {
  chats: [
    { id: "c1", title: "Priya", lastFrom: "Priya", lastText: "hi", when: "", unread: true },
    { id: "c2", title: "Team", lastFrom: "Jan", lastText: "ok", when: "", unread: false },
  ],
  teams: [{ id: "t1", name: "Engineering" }, { id: "t2", name: "Platform" }],
}

test("teams are closed, so no channel is listed until one is opened", () => {
  // The whole point of the on-demand fetch: 28 teams must not become 200 rows.
  const rows = Model.conversationRows(chatty, {}, {}, "")
  eq(rows.filter((r) => r.kind === "channel").length, 0)
  eq(rows.filter((r) => r.kind === "team").length, 2)
})

test("chats come before teams", () => {
  const rows = Model.conversationRows(chatty, {}, {}, "")
  const firstChat = rows.findIndex((r) => r.kind === "chat")
  const firstTeam = rows.findIndex((r) => r.kind === "team")
  ok(firstChat < firstTeam, "chats should lead")
})

test("an opened team shows its channels, indented", () => {
  const rows = Model.conversationRows(
    chatty, { t1: true }, { t1: [{ id: "ch1", name: "General", teamId: "t1" }] }, ""
  )
  const channel = rows.find((r) => r.kind === "channel")
  eq(channel.title, "# General")
  eq(channel.depth, 1)
  eq(channel.teamId, "t1")
})

test("only the opened team expands", () => {
  const rows = Model.conversationRows(
    chatty, { t1: true }, { t1: [{ id: "ch1", name: "General", teamId: "t1" }] }, ""
  )
  eq(rows.filter((r) => r.kind === "channel").length, 1)
})

test("a team whose channels are still coming shows no empty note", () => {
  // "No channels" while it is still loading would be a lie that then corrects
  // itself, which reads worse than nothing.
  const rows = Model.conversationRows(chatty, { t2: true }, {}, "t2")
  eq(rows.filter((r) => r.kind === "note").length, 0)
  ok(rows.find((r) => r.kind === "team" && r.id === "t2").loading, "t2 should be loading")
})

test("a team that really has no channels says so", () => {
  const rows = Model.conversationRows(chatty, { t2: true }, { t2: [] }, "")
  eq(rows.filter((r) => r.kind === "note").length, 1)
})

test("headings appear only when there is something under them", () => {
  const rows = Model.conversationRows({ chats: [], teams: [] }, {}, {}, "")
  eq(rows, [])
})

test("an unread chat is marked and a read one is not", () => {
  const rows = Model.conversationRows(chatty, {}, {}, "")
  const chats = rows.filter((r) => r.kind === "chat")
  eq([chats[0].unread, chats[1].unread], [true, false])
})

test("a channel never claims to be unread", () => {
  // Graph exposes no read state for channels; a dot that never lights would
  // be worse than no dot.
  const rows = Model.conversationRows(
    chatty, { t1: true }, { t1: [{ id: "ch1", name: "General", teamId: "t1" }] }, ""
  )
  eq(rows.find((r) => r.kind === "channel").unread, false)
})

test("every row has a key, and they are all distinct", () => {
  const rows = Model.conversationRows(
    chatty, { t1: true }, { t1: [{ id: "ch1", name: "General", teamId: "t1" }] }, ""
  )
  const keys = rows.map((r) => r.key)
  ok(keys.every((k) => typeof k === "string" && k.length > 0), "all rows need a key")
  eq(new Set(keys).size, keys.length, "keys should be unique")
})

// ------------------------------------------------------------ unread filter

test("filtering to unread keeps only the unread chats", () => {
  const rows = Model.conversationRows(chatty, {}, {}, "", true)
  const chats = rows.filter((r) => r.kind === "chat")
  eq(chats.length, 1)
  eq(chats[0].title, "Priya")
})

test("filtering leaves the teams out", () => {
  // Graph exposes no read state for a channel, so every team would be neither
  // kept nor excluded. Listing them all under an unread filter would be a lie.
  const rows = Model.conversationRows(chatty, {}, {}, "", true)
  eq(rows.filter((r) => r.kind === "team").length, 0)
  eq(rows.filter((r) => r.kind === "channel").length, 0)
})

test("an opened team stays opened for when the filter comes off again", () => {
  const expanded = { t1: true }
  const channels = { t1: [{ id: "ch1", name: "General", teamId: "t1" }] }
  eq(Model.conversationRows(chatty, expanded, channels, "", true)
       .filter((r) => r.kind === "channel").length, 0)
  // The filter is a view, not a state change: turning it off restores exactly
  // what was there.
  eq(Model.conversationRows(chatty, expanded, channels, "", false)
       .filter((r) => r.kind === "channel").length, 1)
})

test("nothing unread says so rather than showing an empty pane", () => {
  const allRead = { chats: [{ id: "c2", title: "Team", unread: false }], teams: chatty.teams }
  const rows = Model.conversationRows(allRead, {}, {}, "", true)
  eq(rows.length, 1)
  eq(rows[0].kind, "note")
  eq(rows[0].title, "Nothing unread")
})

test("the empty note is not something the cursor can land on", () => {
  const allRead = { chats: [{ id: "c2", title: "Team", unread: false }], teams: [] }
  const rows = Model.conversationRows(allRead, {}, {}, "", true)
  eq(Model.selectableRows(rows), [])
})

test("not filtering is the same as before the filter existed", () => {
  eq(Model.conversationRows(chatty, {}, {}, "", false),
     Model.conversationRows(chatty, {}, {}, ""))
})

// ---------------------------------------------------------- selectableRows

test("the cursor may land on chats, channels and teams", () => {
  const rows = Model.conversationRows(
    chatty, { t1: true }, { t1: [{ id: "ch1", name: "General", teamId: "t1" }] }, ""
  )
  const pickable = Model.selectableRows(rows).map((i) => rows[i].kind)
  eq(new Set(pickable).size <= 3, true)
  ok(!pickable.includes("heading"), "a cursor must not stop on a heading")
  ok(!pickable.includes("note"), "a cursor must not stop on a note")
  ok(pickable.includes("team"), "opening a team is an action")
})

// ------------------------------------------------------------ groupMessages

const at = (iso) => iso

test("consecutive messages from one person are one block", () => {
  const groups = Model.groupMessages(
    [
      { id: "1", from: "Priya", fromId: "p", text: "one", when: at("2026-08-31T10:00:00Z") },
      { id: "2", from: "Priya", fromId: "p", text: "two", when: at("2026-08-31T10:01:00Z") },
      { id: "3", from: "Jan", fromId: "me", text: "three", when: at("2026-08-31T10:02:00Z") },
    ],
    "me"
  )
  eq(groups.length, 2)
  eq(groups[0].lines.length, 2)
  eq(groups[1].mine, true)
})

test("a file on a message survives being grouped", () => {
  // The line is what the transcript draws, and a message that is only a file
  // has nothing but this to draw.
  const file = { id: "a", name: "memo.pdf", url: "https://x.y/memo.pdf" }
  const groups = Model.groupMessages(
    [
      { id: "1", from: "Jan", fromId: "me", text: "", attachments: [file] },
      { id: "2", from: "Jan", fromId: "me", text: "and this" },
    ],
    "me"
  )
  eq(groups[0].lines[0].attachments.length, 1)
  eq(groups[0].lines[0].attachments[0].name, "memo.pdf")
  eq(groups[0].lines[1].attachments.length, 0)
})

test("a quote on a message survives being grouped", () => {
  // Both the first line of a block and a line pushed onto one: a quote-reply
  // sent in the middle of somebody talking is the ordinary case, not the odd
  // one, and only the second path was ever going to be forgotten.
  const quote = { id: "q", from: "Priya", text: "the thing being answered",
                  when: "", forwarded: false }
  const groups = Model.groupMessages(
    [
      { id: "1", from: "Jan", fromId: "me", text: "first", quotes: [quote] },
      { id: "2", from: "Jan", fromId: "me", text: "second", quotes: [quote] },
      { id: "3", from: "Jan", fromId: "me", text: "no quote here" },
    ],
    "me"
  )
  eq(groups[0].lines[0].quotes.length, 1)
  eq(groups[0].lines[0].quotes[0].text, "the thing being answered")
  eq(groups[0].lines[1].quotes.length, 1)
  eq(groups[0].lines[2].quotes.length, 0)
})

test("a message with no quotes has an empty list rather than nothing", () => {
  // The transcript's Repeater reads this directly, and a model of undefined
  // is a binding error per message rather than an empty block.
  const groups = Model.groupMessages([{ id: "1", from: "P", fromId: "p", text: "x" }], "me")
  eq(Array.isArray(groups[0].lines[0].quotes), true)
  eq(groups[0].lines[0].quotes.length, 0)
})

test("a block knows which of them is yours", () => {
  const groups = Model.groupMessages([{ id: "1", from: "Jan", fromId: "me", text: "x" }], "me")
  eq(groups[0].mine, true)
  const others = Model.groupMessages([{ id: "1", from: "P", fromId: "p", text: "x" }], "me")
  eq(others[0].mine, false)
})

test("with no known user id nothing is claimed as yours", () => {
  const groups = Model.groupMessages([{ id: "1", from: "P", fromId: "", text: "x" }], "")
  eq(groups[0].mine, false)
})

test("a system message never joins the block above it", () => {
  const groups = Model.groupMessages(
    [
      { id: "1", from: "P", fromId: "p", text: "hi" },
      { id: "2", from: "", fromId: "", text: "P added Q", system: true },
      { id: "3", from: "P", fromId: "p", text: "still here" },
    ],
    "me"
  )
  eq(groups.length, 3)
  eq(groups[1].system, true)
})

test("images travel with the line they belong to", () => {
  const groups = Model.groupMessages(
    [{ id: "1", from: "P", fromId: "p", text: "look", images: [{ url: "u", width: 10, height: 20 }] }],
    "me"
  )
  eq(groups[0].lines[0].images.length, 1)
})

test("a line with no images has an empty list, not undefined", () => {
  const groups = Model.groupMessages([{ id: "1", from: "P", fromId: "p", text: "x" }], "me")
  eq(groups[0].lines[0].images, [])
})

test("no messages, no groups", () => {
  eq(Model.groupMessages([], "me"), [])
  eq(Model.groupMessages(null, "me"), [])
})

// --------------------------------------------------------------- whenLabel

test("today is a clock time", () => {
  const now = new Date("2026-08-31T18:00:00")
  const label = Model.whenLabel(new Date("2026-08-31T14:05:00").toISOString(), now)
  ok(/^\d{2}:\d{2}$/.test(label), "expected HH:MM, got " + label)
})

test("earlier this week is a weekday and a time", () => {
  const now = new Date("2026-08-31T18:00:00")
  const label = Model.whenLabel(new Date("2026-08-29T14:05:00").toISOString(), now)
  ok(/^[A-Z][a-z]{2} \d{2}:\d{2}$/.test(label), "expected 'Sat 14:05', got " + label)
})

test("older than a week is a date", () => {
  const now = new Date("2026-08-31T18:00:00")
  const label = Model.whenLabel(new Date("2026-03-03T14:05:00").toISOString(), now)
  ok(/^\d{1,2} [A-Z][a-z]{2}$/.test(label), "expected '3 Mar', got " + label)
})

test("no timestamp is no label rather than Invalid Date", () => {
  eq(Model.whenLabel("", new Date()), "")
  eq(Model.whenLabel("not a date", new Date()), "")
})

// --------------------------------------------------------------- odds and ends

test("a subtitle names who spoke", () => {
  eq(Model.subtitleFor({ lastFrom: "Priya", lastText: "hello" }), "Priya: hello")
  eq(Model.subtitleFor({ lastFrom: "", lastText: "hello" }), "hello")
  eq(Model.subtitleFor({ lastFrom: "Priya", lastText: "" }), "")
})

test("text handed to the shell cannot open a tag", () => {
  // The bar tooltip is drawn by a Text item in the shell's own code, which we
  // cannot pin to PlainText from here - so the < comes out instead.
  ok(!Model.plainText('<img src="x">').includes("<"), "a < should not survive")
})

test("unparseable JSON is the fallback, not a throw", () => {
  eq(Model.parseJson("{not json", null), null)
  eq(Model.parseJson('{"a":1}', null), { a: 1 })
})

// ------------------------------------------------------------------ linkify

test("a link becomes clickable", () => {
  eq(
    Model.linkify("see https://example.com/a?b=1 now"),
    'see <a href="https://example.com/a?b=1">https://example.com/a?b=1</a> now'
  )
})

test("an address becomes a mailto", () => {
  ok(Model.linkify("mail me@x.de").includes('href="mailto:me@x.de"'), "expected a mailto")
})

test("a bare www gets a scheme", () => {
  ok(Model.linkify("www.example.com").includes('href="https://www.example.com"'), "expected https")
})

test("the sentence's full stop is not part of the address", () => {
  const html = Model.linkify("go to https://example.com.")
  ok(html.includes('>https://example.com</a>.'), "trailing stop should fall outside: " + html)
})

test("markup in a message is escaped, not rendered", () => {
  // The words come from whoever sent the message. Escaping happens before any
  // <a> is built, so nothing they write can become a tag.
  const html = Model.linkify('<script>alert(1)</script>')
  ok(!html.includes("<script"), "a script tag survived: " + html)
  ok(html.includes("&lt;script&gt;"), "expected it escaped")
})

test("an img a sender wrote cannot fetch anything", () => {
  const html = Model.linkify('<img src="https://tracker/x.gif">')
  ok(!html.includes("<img"), "an img survived: " + html)
})

test("javascript and data URLs are left as words", () => {
  ok(!Model.linkify("javascript:alert(1)").includes("<a "), "javascript: should not link")
  ok(!Model.linkify("data:text/html,x").includes("<a "), "data: should not link")
})

test("quotes cannot break out of the href", () => {
  const html = Model.linkify('say "hi" to https://example.com')
  ok(html.includes("&quot;hi&quot;"), "quotes should be escaped: " + html)
})

test("newlines become breaks, since rich text ignores them", () => {
  ok(Model.linkify("a\nb").includes("<br>"), "expected a break")
})

test("hasLink is false for ordinary words, so plain lines stay plain", () => {
  eq(Model.hasLink("no links here at all"), false)
  eq(Model.hasLink("one https://x.y here"), true)
  // The regex is global; asking twice must give the same answer.
  eq(Model.hasLink("one https://x.y here"), true)
})

// ------------------------------------------------------- links from the span

const SPAN = [{ start: 4, end: 15, href: "https://x.y/plan" }]

test("words that were a link become the link, address and all", () => {
  eq(
    Model.linkify("see our roadmap today", "", SPAN),
    'see <a href="https://x.y/plan">our roadmap</a> today'
  )
})

test("a line with a span is a link even with no address in the words", () => {
  eq(Model.hasLink("see our roadmap today"), false)
  eq(Model.hasLink("see our roadmap today", SPAN), true)
})

test("the words in a span are escaped like any other words", () => {
  const html = Model.linkify('a <b>c', "", [{ start: 2, end: 5, href: "https://x.y" }])
  ok(!html.includes("<b>"), "markup survived: " + html)
  ok(html.includes("&lt;b&gt;"), "expected it escaped: " + html)
})

test("a span cannot point somewhere that runs", () => {
  const html = Model.linkify("click me", "", [{ start: 0, end: 8, href: "javascript:alert(1)" }])
  ok(!html.includes("<a "), "a javascript: span linked: " + html)
  eq(html, "click me")
})

test("a span pointing outside the line is dropped rather than cutting it", () => {
  eq(Model.linkify("short", "", [{ start: 2, end: 99, href: "https://x.y" }]), "short")
  eq(Model.linkify("short", "", [{ start: -1, end: 3, href: "https://x.y" }]), "short")
  eq(Model.linkify("short", "", [{ start: 3, end: 3, href: "https://x.y" }]), "short")
})

test("overlapping spans keep the first and drop what runs into it", () => {
  const html = Model.linkify("one two", "", [
    { start: 4, end: 7, href: "https://b.b" },
    { start: 0, end: 3, href: "https://a.a" },
    { start: 1, end: 5, href: "https://c.c" },
  ])
  eq(html, '<a href="https://a.a">one</a> <a href="https://b.b">two</a>')
})

test("an address outside the spans is still found on its own", () => {
  const html = Model.linkify("see our roadmap today, or https://z.z", "", SPAN)
  ok(html.includes('href="https://x.y/plan"'), "expected the span: " + html)
  ok(html.includes('href="https://z.z"'), "expected the bare address too: " + html)
})

test("words inside a span are not linked twice", () => {
  const html = Model.linkify("go https://x.y/a now", "", [{ start: 3, end: 16, href: "https://x.y/a" }])
  eq(html, 'go <a href="https://x.y/a">https://x.y/a</a> now')
})

test("a span takes the theme's colour like any other link", () => {
  const html = Model.linkify("see our roadmap today", "#7aa2f7", SPAN)
  ok(html.includes('style="color:#7aa2f7"'), "expected the tint: " + html)
  ok(html.includes('<font color="#7aa2f7">'), "expected the font tag too: " + html)
})

test("a quote in the href cannot break out of the attribute", () => {
  const html = Model.linkify("go", "", [{ start: 0, end: 2, href: 'https://x.y/"onx="1' }])
  ok(!html.includes('"onx='), "the href broke out: " + html)
  ok(html.includes("&quot;"), "expected it escaped: " + html)
})

test("no spans is the plain line it always was", () => {
  eq(Model.linkify("just words", "", []), "just words")
  eq(Model.linkify("just words", "", null), "just words")
})

test("a line keeps its spans through the grouping", () => {
  const links = [{ start: 0, end: 2, href: "https://x.y" }]
  const groups = Model.groupMessages([
    { id: "1", fromId: "a", text: "go", links: links },
    { id: "2", fromId: "a", text: "and", links: [] },
    { id: "3", fromId: "b", text: "go", links: links },
  ], "me")
  eq(groups[0].lines[0].links, links)
  eq(groups[0].lines[1].links, [])
  eq(groups[1].lines[0].links, links)
})

test("a message from before links were read groups without throwing", () => {
  const groups = Model.groupMessages([{ id: "1", fromId: "a", text: "go" }], "me")
  eq(groups[0].lines[0].links, [])
})

// ------------------------------------------------------------------ density

test("each named spacing is a distinct multiplier, in order", () => {
  const scales = Model.densityNames().map(Model.densityScale)
  for (let i = 1; i < scales.length; i++)
    ok(scales[i] > scales[i - 1], "spacing should grow: " + JSON.stringify(scales))
})

test("cosy is the theme's own spacing, untouched", () => {
  eq(Model.densityScale("cosy"), 1.0)
})

test("an unknown or missing name falls back to cosy rather than to nothing", () => {
  // A bad value in shell.json must not collapse every gap to zero.
  for (const bad of ["", null, undefined, "enormous", 7])
    eq(Model.densityScale(bad), 1.0, JSON.stringify(bad) + " should fall back")
})

test("the name is not case sensitive", () => {
  eq(Model.densityScale("ROOMY"), Model.densityScale("roomy"))
})

test("every name the settings form offers actually maps", () => {
  // The manifest lists these; a name in the form with no scale behind it
  // would silently do nothing.
  for (const name of Model.densityNames())
    ok(Model.densityScale(name) > 0, name + " should have a scale")
})

// ---------------------------------------------------------------- reactions

test("clicking a reaction you already gave removes yours", () => {
  const rx = [{ emoji: "\u{1F44D}", count: 2, mine: true }]
  eq(Model.reactionIsMine(rx, "\u{1F44D}"), true)
})

test("clicking one other people gave adds yours", () => {
  const rx = [{ emoji: "\u{1F44D}", count: 2, mine: false }]
  eq(Model.reactionIsMine(rx, "\u{1F44D}"), false)
})

test("a different emoji on the same message is a different decision", () => {
  // Getting this wrong would remove somebody's like when you meant to laugh.
  const rx = [{ emoji: "\u{1F44D}", count: 1, mine: true },
              { emoji: "\u{1F602}", count: 1, mine: false }]
  eq(Model.reactionIsMine(rx, "\u{1F44D}"), true)
  eq(Model.reactionIsMine(rx, "\u{1F602}"), false)
})

test("a fresh pick on a message with none is always an add", () => {
  eq(Model.reactionIsMine([], "\u{1F44D}"), false)
  eq(Model.reactionIsMine(null, "\u{1F44D}"), false)
  eq(Model.reactionIsMine(undefined, "\u{1F44D}"), false)
})

test("an emoji not on the message yet is an add, not a remove", () => {
  const rx = [{ emoji: "\u{1F44D}", count: 1, mine: true }]
  eq(Model.reactionIsMine(rx, "\u{2764}\u{FE0F}"), false)
})

// ---------------------------------------------------------------- presence

const PALETTE = { green: "#9ece6a", red: "#f7768e", yellow: "#e0af68", muted: "#414868" }

test("each state wears a colour from the theme, not a hardcoded one", () => {
  eq(Model.presenceColor("available", PALETTE), "#9ece6a")
  eq(Model.presenceColor("busy", PALETTE), "#f7768e")
  eq(Model.presenceColor("away", PALETTE), "#e0af68")
  eq(Model.presenceColor("offline", PALETTE), "#414868")
})

test("an unknown state gets no dot rather than a wrong one", () => {
  eq(Model.presenceColor("unknown", PALETTE), "")
  eq(Model.presenceColor("", PALETTE), "")
})

test("a theme missing a colour gets no dot, never a broken one", () => {
  // An empty string is how the row decides not to draw it at all.
  eq(Model.presenceColor("available", {}), "")
  eq(Model.presenceColor("available", null), "")
})

test("away falls back to orange where a theme has no yellow", () => {
  eq(Model.presenceColor("away", { orange: "#eb927b" }), "#eb927b")
})

test("an activity is unpacked into words", () => {
  // Graph sends one camel-case word, and a run of capitals needs breaking too.
  eq(Model.presenceLabel("busy", "InAMeeting"), "In A Meeting")
  eq(Model.presenceLabel("busy", "OnThePhone"), "On The Phone")
  eq(Model.presenceLabel("away", "OutOfOffice"), "Out Of Office")
})

test("with no activity the state speaks for itself", () => {
  eq(Model.presenceLabel("available", ""), "Available")
  eq(Model.presenceLabel("offline", "Anything"), "Offline")
  eq(Model.presenceLabel("unknown", ""), "")
})

// ----------------------------------------------------------- link colouring

test("a link is tinted with the colour it is given", () => {
  const html = Model.linkify("go https://x.y", "#7aa2f7")
  ok(html.includes('style="color:#7aa2f7"'), "expected the style: " + html)
  ok(html.includes('<font color="#7aa2f7">'), "expected the font tag too: " + html)
})

test("with no colour it is a plain anchor, as before", () => {
  eq(Model.linkify("go https://x.y", ""), 'go <a href="https://x.y">https://x.y</a>')
})

test("tinting does not weaken the escaping", () => {
  const html = Model.linkify('<script>bad()</script> https://x.y', "#7aa2f7")
  ok(!html.includes("<script"), "a script tag survived: " + html)
})


// ------------------------------------------------------------------ calendar
//
// Days are strings and the events already carry the one they belong to, so
// none of this needs a timezone - which is what makes it testable at all.
// `now` goes in wherever today matters.

const SEP4 = new Date(2026, 8, 4, 10, 20)   // a Friday
const day = (key, when, until, extra) =>
  Object.assign({ id: key + "@" + when, subject: "Meeting", when: when, until: until,
                  startDate: key, endDate: key, allDay: false, showAs: "busy",
                  response: "accepted" }, extra || {})
const slot = (key, from, to) =>
  day(key, key + "T" + from + ":00", key + "T" + to + ":00")

test("a week runs Monday to Sunday, and a work week stops on Friday", () => {
  eq(Model.calendarRange("week", "2026-09-04").keys, [
    "2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03",
    "2026-09-04", "2026-09-05", "2026-09-06"])
  eq(Model.calendarRange("work week", "2026-09-04").keys.length, 5)
  eq(Model.calendarRange("work week", "2026-09-04").keys[4], "2026-09-04")
  eq(Model.calendarRange("day", "2026-09-04").keys, ["2026-09-04"])
})

test("a week can start on Sunday instead, and the work week follows it", () => {
  eq(Model.calendarRange("week", "2026-09-04", true).keys[0], "2026-08-30")
  // Monday to Friday either way: what moves is where the week begins, not
  // which days people work.
  eq(Model.calendarRange("work week", "2026-09-04", true).keys[0], "2026-08-31")
})

test("a month runs from the Monday before the 1st to the Sunday after the last", () => {
  const range = Model.calendarRange("month", "2026-09-04")
  eq(range.keys[0], "2026-08-31")
  eq(range.keys[range.keys.length - 1], "2026-10-04")
  ok(range.days % 7 === 0, "a month grid is whole weeks, got " + range.days)
})

test("stepping a month from the 31st does not skip one", () => {
  // setDate on a 30-day month rolls over, which is how "next month" from 31
  // August lands in October.
  eq(Model.shiftAnchor("month", "2026-08-31", 1), "2026-09-30")
  eq(Model.shiftAnchor("month", "2026-01-31", 1), "2026-02-28")
  eq(Model.shiftAnchor("day", "2026-09-30", 1), "2026-10-01")
})

test("a work week steps a whole week, not five days", () => {
  // Five would walk the anchor onto a Saturday, and the week after that is
  // the wrong one.
  eq(Model.shiftAnchor("work week", "2026-09-04", 1), "2026-09-07")
  eq(Model.shiftAnchor("work week", "2026-09-04", -1), "2026-08-24")
})

test("the range says what it is showing, and leaves this year off", () => {
  eq(Model.rangeLabel("day", ["2026-09-04"], SEP4), "Friday 4 September")
  eq(Model.rangeLabel("day", ["2027-09-04"], SEP4), "Saturday 4 September 2027")
  eq(Model.rangeLabel("week", Model.calendarRange("week", "2026-09-04").keys, SEP4),
     "31 Aug – 6 Sep")
  eq(Model.rangeLabel("week", ["2026-09-07", "2026-09-11"], SEP4), "7 – 11 September")
  // Named for the month it is about, not for the six weeks it draws.
  eq(Model.rangeLabel("month", Model.calendarRange("month", "2026-09-04").keys, SEP4),
     "September 2026")
})

test("an event is on every day it touches", () => {
  const leave = day("2026-09-04", "2026-09-04T00:00:00", "2026-09-07T00:00:00",
                    { allDay: true, endDate: "2026-09-06" })
  const days = Model.calendarDays([leave], Model.calendarRange("week", "2026-09-04").keys,
                                  "2026-09-04", "2026-09-04")
  eq(days.map(d => d.allDay.length), [0, 0, 0, 0, 1, 1, 1])
  eq(days[4].isToday, true)
  eq(days[3].isPast, true)
})

test("all-day events are kept apart from the ones with a clock face", () => {
  const days = Model.calendarDays(
    [day("2026-09-04", "2026-09-04T00:00:00", "2026-09-05T00:00:00", { allDay: true }),
     slot("2026-09-04", "09:00", "10:00")],
    ["2026-09-04"], "2026-09-04", "2026-09-04")
  eq(days[0].allDay.length, 1)
  eq(days[0].timed.length, 1)
  eq(days[0].count, 2)
})

test("a block is clipped to the day it is being drawn on", () => {
  // A call from 23:00 to 01:00 is the tail of one day and the head of the
  // next, which is what every calendar draws.
  const overnight = day("2026-09-04", "2026-09-04T23:00:00", "2026-09-05T01:00:00",
                        { endDate: "2026-09-05" })
  eq(Model.daySpan(overnight, "2026-09-04"), { start: 1380, end: 1440 })
  eq(Model.daySpan(overnight, "2026-09-05"), { start: 0, end: 60 })
})

test("a meeting with no length is still tall enough to click", () => {
  eq(Model.daySpan(slot("2026-09-04", "09:00", "09:00"), "2026-09-04"),
     { start: 540, end: 555 })
})

test("overlapping meetings are given columns, and the ones after them are not", () => {
  const rows = Model.layoutColumns([
    slot("2026-09-04", "09:00", "10:00"),
    slot("2026-09-04", "09:30", "10:30"),
    slot("2026-09-04", "14:00", "15:00")], "2026-09-04")
  eq(rows.map(r => [r.column, r.columns]), [[0, 2], [1, 2], [0, 1]])
})

test("a chain of overlaps is one cluster, and reuses a column that has ended", () => {
  // Three meetings chained across an hour share one width; the third can sit
  // back in the first's column because the first is over by then.
  const rows = Model.layoutColumns([
    slot("2026-09-04", "09:00", "10:00"),
    slot("2026-09-04", "09:30", "10:30"),
    slot("2026-09-04", "10:15", "11:00")], "2026-09-04")
  eq(rows.map(r => r.column), [0, 1, 0])
  eq(rows.map(r => r.columns), [2, 2, 2])
})

test("three at once are three columns", () => {
  const rows = Model.layoutColumns([
    slot("2026-09-04", "14:00", "15:00"),
    slot("2026-09-04", "14:00", "14:30"),
    slot("2026-09-04", "14:00", "14:15")], "2026-09-04")
  eq(rows.map(r => r.columns), [3, 3, 3])
  eq(rows.map(r => r.column).sort(), [0, 1, 2])
})

test("an agenda leaves out the empty days, unless every day is one", () => {
  const days = Model.calendarDays([slot("2026-09-04", "09:00", "10:00")],
                                  Model.calendarRange("week", "2026-09-04").keys,
                                  "2026-09-04", "2026-09-04")
  eq(Model.agendaRows(days).map(r => r.kind), ["day", "event"])
  const empty = Model.calendarDays([], ["2026-09-04"], "2026-09-04", "2026-09-04")
  eq(Model.agendaRows(empty).map(r => r.kind), ["day", "note"])
})

test("the cursor walks the days in the order they are drawn", () => {
  const days = Model.calendarDays(
    [day("2026-09-04", "2026-09-04T00:00:00", "2026-09-05T00:00:00",
         { allDay: true, id: "leave" }),
     Object.assign(slot("2026-09-04", "09:00", "10:00"), { id: "stand" }),
     Object.assign(slot("2026-09-05", "09:00", "10:00"),
                   { id: "next", startDate: "2026-09-05", endDate: "2026-09-05" })],
    ["2026-09-04", "2026-09-05"], "2026-09-04", "2026-09-04")
  // All-day first, then the clock, then the next day.
  eq(Model.eventCursorKeys(days),
     ["2026-09-04:leave", "2026-09-04:stand", "2026-09-05:next"])
})

test("a meeting says when it is, and how long for", () => {
  eq(Model.eventTimeLabel(slot("2026-09-04", "09:00", "09:30")), "09:00 – 09:30")
  eq(Model.eventTimeLabel({ allDay: true }), "All day")
  eq(Model.durationLabel({ minutes: 45 }), "45 min")
  eq(Model.durationLabel({ minutes: 60 }), "1 h")
  eq(Model.durationLabel({ minutes: 90 }), "1 h 30 min")
  eq(Model.durationLabel({ minutes: 2880, allDay: true }), "2 days")
})

test("there is only a question to answer where there is an invitation", () => {
  ok(Model.answerable({ response: "pending" }), "an unanswered invitation")
  ok(Model.answerable({ response: "accepted" }), "changing your mind is the common case")
  ok(!Model.answerable({ response: "none" }), "nobody was invited")
  ok(!Model.answerable({ response: "pending", isOrganizer: true }), "your own meeting")
  ok(!Model.answerable({ response: "pending", cancelled: true }), "a cancelled one")
})

test("the colour says what it does to your day, and declined says nothing", () => {
  const palette = { blue: "#7aa2f7", yellow: "#e0af68", green: "#9ece6a",
                    magenta: "#bb9af7", muted: "#565f89" }
  eq(Model.eventTint({ showAs: "busy" }, palette), "#7aa2f7")
  eq(Model.eventTint({ showAs: "tentative" }, palette), "#e0af68")
  eq(Model.eventTint({ showAs: "oof" }, palette), "#bb9af7")
  eq(Model.eventTint({ showAs: "free" }, palette), "#9ece6a")
  eq(Model.eventTint({ showAs: "busy", response: "declined" }, palette), "#565f89")
  eq(Model.eventTint({ showAs: "busy", cancelled: true }, palette), "#565f89")
})

test("who has answered is counted rather than listed", () => {
  eq(Model.attendeeSummary([{ response: "accepted" }, { response: "accepted" },
                            { response: "tentative" }, { response: "pending" }]),
     "2 accepted, 1 tentative, 1 no reply")
  eq(Model.attendeeSummary([]), "")
})

test("what is next is what has not ended, and never an all-day row", () => {
  const events = [
    Object.assign(slot("2026-09-04", "09:00", "10:00"), { id: "past" }),
    Object.assign(slot("2026-09-04", "10:00", "11:00"), { id: "now" }),
    Object.assign(slot("2026-09-04", "14:00", "15:00"), { id: "later" }),
    day("2026-09-04", "2026-09-04T00:00:00", "2026-09-05T00:00:00",
        { allDay: true, id: "leave" })]
  eq(Model.nextUp(events, SEP4).id, "now")
  ok(Model.isNow(events[1], SEP4), "10:20 is inside 10:00-11:00")
  ok(!Model.isNow(events[0], SEP4), "and outside 09:00-10:00")
  eq(Model.minutesUntil(events[2], SEP4), 220)
})

test("a declined meeting is neither next up nor worth a toast", () => {
  const declined = Object.assign(slot("2026-09-04", "10:25", "11:00"),
                                 { id: "no", response: "declined" })
  eq(Model.nextUp([declined], SEP4), null)
  eq(Model.startingSoon([declined], SEP4, 5).length, 0)
})

test("only what is about to start is worth a toast, and not what already has", () => {
  const soon = Object.assign(slot("2026-09-04", "10:23", "11:00"), { id: "soon" })
  const running = Object.assign(slot("2026-09-04", "10:00", "11:00"), { id: "running" })
  const far = Object.assign(slot("2026-09-04", "11:00", "11:30"), { id: "far" })
  eq(Model.startingSoon([soon, running, far], SEP4, 5).map(e => e.id), ["soon"])
})

test("the grid opens on the working day rather than on midnight", () => {
  const days = Model.calendarDays([slot("2026-09-04", "09:00", "10:00")],
                                  ["2026-09-04"], "2026-09-04", "2026-09-04")
  eq(Model.firstBusyHour(days, SEP4), 8)
  // With nothing on, it opens on the hour it actually is.
  eq(Model.firstBusyHour(Model.calendarDays([], ["2026-09-04"], "2026-09-04", "2026-09-04"),
                         SEP4), 9)
})

test("the now line is only drawn on the day it is now on", () => {
  eq(Model.nowMinutes("2026-09-04", SEP4), 620)
  eq(Model.nowMinutes("2026-09-05", SEP4), null)
})

test("a meeting is checked before it is sent, and told what is wrong", () => {
  const good = { subject: "Sync", date: "2026-09-04", from: "09:00", to: "10:00" }
  eq(Model.newMeetingProblem(good), "")
  eq(Model.newMeetingProblem(Object.assign({}, good, { subject: " " })),
     "A meeting needs a subject")
  eq(Model.newMeetingProblem(Object.assign({}, good, { date: "the fourth" })),
     "The date has to be YYYY-MM-DD")
  eq(Model.newMeetingProblem(Object.assign({}, good, { from: "9am" })),
     "The start time has to be HH:MM")
  eq(Model.newMeetingProblem(Object.assign({}, good, { to: "08:00" })),
     "A meeting has to end after it starts")
  // A whole day has no time of day to get wrong.
  eq(Model.newMeetingProblem({ subject: "Away", date: "2026-09-04", allDay: true }), "")
})

test("what is sent is wall-clock time with no zone on it", () => {
  // The helper is the side that knows this machine's timezone.
  const payload = Model.newMeetingPayload(
    { subject: " Sync ", date: "2026-09-04", from: "09:00", to: "10:00",
      attendees: [{ address: "a@b.c" }, { address: "" }] })
  eq(payload.start, "2026-09-04T09:00:00")
  eq(payload.end, "2026-09-04T10:00:00")
  eq(payload.subject, "Sync")
  eq(payload.online, true)
  eq(payload.attendees, [{ address: "a@b.c", name: "", kind: "required" }])
})

test("a whole day ends at the next midnight, which is what Graph means by it", () => {
  const payload = Model.newMeetingPayload(
    { subject: "Away", date: "2026-09-04", allDay: true, days: 3 })
  eq(payload.start, "2026-09-04T00:00:00")
  eq(payload.end, "2026-09-07T00:00:00")
  eq(payload.showAs, "free")
})

// ---------------------------------------------------------------------------

for (const failure of failures) console.error("FAIL " + failure)
console.log("")
console.log(passed + "/" + (passed + failures.length) + " passed")
process.exit(failures.length === 0 ? 0 : 1)
