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
    "subtitleFor, oneLine, plainText, parseJson, linkify, hasLink, escapeHtml }"
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

// ---------------------------------------------------------------------------

for (const failure of failures) console.error("FAIL " + failure)
console.log("")
console.log(passed + "/" + (passed + failures.length) + " passed")
process.exit(failures.length === 0 ? 0 : 1)
