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
    "densityScale, densityNames, reactionIsMine, presenceColor, presenceLabel }"
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

// ---------------------------------------------------------------------------

for (const failure of failures) console.error("FAIL " + failure)
console.log("")
console.log(passed + "/" + (passed + failures.length) + " passed")
process.exit(failures.length === 0 ? 0 : 1)
