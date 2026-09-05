# SPEC.md — Microsoft Teams for Omarchy

**Status: descriptive.** This records what the plugin does as of version
**0.6.1** (2026-09-04). It is the contract; `AGENTS.md` is how to change it;
`README.md` is for somebody deciding whether to install it. The contract all
three communication plugins share lives in [`PLATFORM.md`](PLATFORM.md) and is
not restated here.

---

## 1. Scope

Microsoft Teams chats, channels, presence and the calendar, in the bar and in a
window of their own.

| | |
|---|---|
| Plugin id | `janrenz.omarchy.teams` |
| Kinds | `bar-widget`, `panel` |
| Entry points | `src/BarWidget.qml`, `src/TeamsWindow.qml` |
| `allowMultiple` | **false** |
| Helper | `src/teams.py` (3200 lines) |
| State | `~/.local/state/omarchy/teams/` |
| API | Microsoft Graph v1.0, and **nothing else** |

The window has two panes — `pane` says which is on screen — conversations and
the calendar.

---

## 2. There is no default client id, and there cannot be one

**This is invariant 7, and it shapes every feature decision in the plugin.**

An Azure app registration declares which delegated permissions it may *request*.
A registration made for mail cannot ask for `Chat.Read`, and asking for a
permission a registration does not declare **fails the whole sign-in, not just
that scope**.

So `clientId` is a required setting with no default, and:

- Anything needing a new Graph permission needs a **README change telling the
  user what to add to their own registration**, and
- a **graceful path for when consent is refused** — the way `channels: false`
  still leaves chats working.

### 2.1 Scope tiers

Each tier is a separate opt-in setting, because each is a separate declaration
the user must have made.

| Constant | Setting | Notes |
|---|---|---|
| `SCOPES_CHATS` | *(base)* | Always requested |
| `SCOPES_CHANNELS` | `channels` | Refusal leaves chats working |
| `SCOPES_FILES` (`Files.ReadWrite`) | `sendFiles` | |
| `SCOPES_PRESENCE` (`Presence.ReadWrite`) | `setPresence` | |
| `SCOPES_CALENDAR` (`Calendars.Read`) | `calendar` | |
| `SCOPES_CALENDAR_WRITE` (`Calendars.ReadWrite`) | `calendarWrite` | |

Two rules that were each a bug:

- **`Files.ReadWrite` is opt-in for a reason that is not consent.** A
  registration declares what it may request; asking for one it does not declare
  fails the whole sign-in. So the setting is *the user saying their registration
  has it*, `SCOPES_FILES` is appended only when it is on, and `can_upload()`
  reads the answer back off the **granted** scopes.
- **`Presence.ReadWrite` is the only opt-in scope whose cost is consent.**
  `Files.ReadWrite` is opt-in because a registration must declare what it
  requests; presence is opt-in for that *and* because an **administrator** has to
  grant it — where `Presence.Read.All`, reading the whole organisation, needs
  nobody. **Do not fold it into `SCOPES_CHATS`:** that turns every working
  chats-only sign-in into a refused one.

### 2.2 A refresh asks for `scopes_held_by(account)`, not the base set

The refresh response's `scope` is what `store_tokens` records as this sign-in's
capabilities, and **asking for less than was granted gets less back** — so an
account signed in with `Files.ReadWrite` lost the Attach button at its first
refresh.

**Anything added as a scope tier has to be read back in `scopes_held_by` too, or
it falls off an hour after sign-in.**

---

## 3. Helper command surface

`python3 src/teams.py <command> --account <alias> [...]`.

### 3.1 Sign-in

| Command | Arguments |
|---|---|
| `login-start` | `--client-id`, `--authority`, `--channels`, `--files`, `--presence`, `--calendar`, `--calendar-write` |
| `login-poll` | — |
| `login-status` | — reports a sign-in left in flight |
| `list`, `remove`, `palette`, `reactions`, `presence-states` | — |

OAuth 2.0 device code, against `login.microsoftonline.com`. Default authority
`common`.

### 3.2 Reading

| Command | Arguments |
|---|---|
| `fetch` | `--account` (repeatable), `--chats`, `--teams`/`--no-teams`, `--demo` |
| `messages` | `--chat` \| (`--team` + `--channel`), `--top`, `--demo` |
| `channels` | `--team`, `--demo` |
| `people` | `--query`, `--demo` |
| `image` | `--url` — `graph.microsoft.com` hostedContents only |
| `calendar` | `--from`, `--days`, `--demo` |
| `event` | `--event`, `--demo` |

### 3.3 Writing

| Command | Arguments |
|---|---|
| `send` | `--chat` \| (`--team` + `--channel`), `--text` \| **`--stdin`**, `--demo` |
| `upload` | `--chat`, `--file` \| **`--stdin`**, `--comment`, `--demo` |
| `react` | `--message`, `--emoji`, `--chat` \| (`--team` + `--channel`), `--remove` |
| `mark-read` | `--chat`, `--demo` |
| `new-chat` | `--user` (repeatable), `--topic`, `--demo` |
| `presence` | `--state`, `--for`, `--demo` |
| `hold-presence` | `--state`, `--for` (default `PT1H`), `--demo` |
| `rsvp` | `--event`, `--response`, `--comment` \| **`--stdin`**, `--silent`, `--demo` |
| `new-event` | **`--stdin`**, `--demo` |
| `cancel-event` | `--event`, `--comment` \| `--stdin`, `--demo` |

**A conversation is addressed one of two ways, and it matters:** a chat is
`--chat 19:…@thread.v2`; a channel is `--team <id> --channel 19:…@thread.tacv2`.

---

## 4. Behavioural contracts worth stating as spec

### 4.1 A calendar is drawn in local days, and only `teams.py` knows what those are

**Invariant 6.** Graph answers in UTC. The helper converts every timestamp and
gives each event the local date it belongs to (`startDate`, `endDate`) plus an
ISO string carrying this machine's offset. `Model.js` groups by **string
comparison** and never builds a date out of a timestamp.

Two traps live in that conversion, and both have tests:

- **An end is exclusive.** An all-day Friday ends at Saturday midnight and a
  23:00 call ends on the next date, so the last day covered is computed from the
  **last moment covered** — `last = end - 1µs`. Otherwise both are drawn on a day
  they are not in.
- **A whole day has to be written in a named zone**, because midnight UTC is the
  previous evening in half the world. Booking an all-day event sends the date
  with this machine's **IANA zone name**, read from `TZ` or `/etc/localtime`. A
  timed meeting is sent as a UTC instant, worked out with the offset in force *on
  that date* — so a meeting booked across a clock change keeps the time it was
  typed at.

**Anything that starts doing date arithmetic in QML is putting the bug back.**

### 4.2 Sending a file is three requests, and Graph has no "post a file"

A file lives in a drive and a message points at it, which is what Teams itself
does:

1. The bytes go to the sender's own OneDrive, into the same
   `Microsoft Teams Chat Files` folder.
2. A sharing link is made.
3. The chatMessage carries a `reference` attachment.

Two things bite:

- **The attachment's `id` must be the driveItem's eTag GUID.** Anything else
  posts a message whose attachment no client can resolve — so a **missing eTag
  fails rather than being invented around**.
- **The body has to be `html` for `<attachment id=…>` to mean anything**, which
  is the one place in this helper where text is *not* sent as text. A comment is
  therefore escaped there.

`UPLOAD_CAP` is **4 MB**: the limit of a single content PUT to Graph. The
documented route past it is an upload session on a `*.sharepoint.com` host, and
**keeping the one-host rule is worth more than the megabytes.** Files go into
chats, not channels (`channel_files_unsupported`).

**A path is resolved once.** `read_upload` opens the file and asks the descriptor
everything after that. Asking the name three times — `isfile`, `getsize`, `open`
— is three chances for it to mean a different file, and the size that was checked
is then not the size that is read. The open is `O_NONBLOCK` because it now
happens first: a FIFO nobody is writing to would otherwise hang a helper the
window is waiting on.

### 4.3 A presence nobody can see is the normal case

`setUserPreferredPresence` stores what the picker asks for, and **Graph then
shows `Offline` unless the user has a *presence session*** — a Teams client
signed in somewhere. On a desktop with no Teams running that is every time, so
the picker looked broken until the plugin could hold a session of its own.

`hold-presence`, behind the `holdPresence` setting, makes this plugin one of those
clients. It renews every twenty minutes and **follows the desktop rather than
asserting anything**: available while somebody is at the machine, away once the
screen has been idle five minutes, and let go when the shell stops, so the user
is not left looking available to a room they have gone home from. **Idle
inhibitors count as being present**, so a call does not look like an empty desk.

Three constraints:

- **The session's vocabulary is narrower than the picker's, on purpose.**
  `setPresence` takes `Busy` only as *InACall* or *InAConferenceCall*, and the
  plugin knows about neither, so it offers available and away and **nothing
  else** — it will not claim them to get a red dot. Busy and Do not disturb are
  the user's to set from the menu, where they mean the user said so.
- **Graph names the session after the application, not the machine.** So two
  machines running this plugin renew **one** session between them. Which is also
  why the heartbeat sits behind `notifies` — the same "one of the three Services
  does this" flag the notifications use.
- **The dot says what Graph reports *now*, not what was chosen.** Graph hands back
  an effective presence and will not say whether a preference is behind it, so the
  menu ticks the row that matches what is true rather than inventing a memory of
  the last button pressed.

`PREFERRED_PRESENCE` offers one row per availability/activity pair **Microsoft
actually documents** — `Offline`/`OffWork` among them, the one whose two halves
differ and the one that would otherwise fail as a 400. Row 0 is Automatic
(`CLEAR_WORDS`: `auto`, `automatic`, `clear`, `reset`), which is Teams' own
*Reset status*.

### 4.4 Channels have no unread state

Graph exposes nothing equivalent to a chat's read mark, so **channels carry no
unread mark at all** rather than an invented number.

**Teams stay closed until opened**, because their channels are one request per
team: listing all of them up front cost 29 requests and two hundred rows on an
account in 28 teams.

This is also why the widget's Service keeps **`includeTeams: false`**: a channel
has no read state to filter on, so the dropdown's tree would cost a request per
team and answer nothing.

### 4.5 Graph refuses reactions outside six emoji

👍 ❤️ 😂 😮 😢 😡 — anything else is *"Unicode ... is not supported"*. The picker
offers **exactly what will work** rather than letting somebody pick something
that silently fails. `REACTIONS` is the list; `1`–`6` picks one.

### 4.6 Two surfaces, and only one can be summoned by name

The shell decides where `summon`/`toggle`/`hide` go from the manifest's `kinds`,
and `isBarWidgetPanelPlugin()` returns false for anything that is *also* a panel
kind. This plugin is both, so **`omarchy-shell shell toggle
janrenz.omarchy.teams` always means the window and can never reach the
dropdown.** The widget's `opened`/`open`/`close` shape exists for the bar's own
click-away and popout coordination, not for that route.

A keybinding onto the dropdown needs the panel's own `IpcHandler`, named by
`ipcTarget`. The mail plugin has the same split for the same reason.

### 4.7 The clock, and what may bind to it

**`service.clock` ticks every minute, and almost nothing may bind to it.** The
line across today and "starts in four minutes" want it; **the day columns must
not**, or every delegate in the grid is rebuilt once a minute.

So `Model.calendarDays` takes `todayKey` — a string that changes at midnight —
and the clock reaches only the two things that need the minute.

### 4.8 A ScrollView takes its size from its child's *implicit* size

An `Item` that sets only `height` scrolls nowhere at all: `contentHeight` stays
at the viewport's, every position clamps to the top, and **the clock face opens
at midnight however carefully the hour was worked out.**
`CalendarGrid`'s `faceContent` sets `implicitHeight` instead, and an Item's
height follows that anyway.

It is also why the grid is scrolled into place by a **short timer** rather than a
`Qt.callLater`: what is being waited for is the ScrollView knowing how tall its
content is, and that is not the next tick.

### 4.9 The calendar's layers close when the pane does

A meeting card left open behind the conversations is a layer nobody can see that
`Escape` is still unwinding, so `showPane("chats")` closes the meeting **and** the
booking form.

### 4.10 There is no `cursoredMessage()` here

The Slack plugin has one; this window inlines "the cursor, or the newest if it is
nowhere yet" in `startPicking` and in `agentArgv`. **Copying code across from
that repo without checking produces a `ReferenceError` that only shows up in the
log.**

---

## 5. State model

**Neither a singleton nor a lock.** `Service.qml` (1661 lines) is instantiated by
`BarWidget.qml` and by `TeamsWindow.qml`, and the bar is one surface per monitor —
so a two-monitor desktop with the window open **polls the account three times an
interval.**

The mail plugin solved this with a `kinds: ["service"]` singleton (`Store.qml`)
and Slack solved it with an flock in the helper (`FetchSlot`). This plugin has
done neither. Recorded here as a fact about the current design; see
`PLATFORM.md` §6.

Service owns: the snapshot, expanded teams and their channels, the open
conversation and transcript, the composer draft, people search, presence and the
held session, reactions, the mark-read queue, and the entire calendar surface —
mode, anchor, span, events, the open event, RSVP, booking and cancelling.

---

## 6. Settings

| Key | Type | Default | Range / options |
|---|---|---|---|
| `account` | string | — | |
| `clientId` | string | — | **Required; no default (§2)** |
| `authority` | string | `""` | `common`, `organizations`, or a tenant id |
| `channels` | boolean | true | Include teams and channels |
| `sendFiles` | boolean | false | Needs `Files.ReadWrite` declared |
| `setPresence` | boolean | false | Needs `Presence.ReadWrite` **admin-granted** |
| `holdPresence` | boolean | false | Let Teams see you at this machine |
| `calendar` | boolean | false | Needs `Calendars.Read` |
| `calendarWrite` | boolean | false | Needs `Calendars.ReadWrite` |
| `calendarView` | string | `week` | `day`, `work week`, `week`, `month` |
| `weekStart` | string | `monday` | `monday`, `sunday` |
| `meetingReminders` | boolean | true | |
| `reminderMinutes` | integer | 5 | 1–60 |
| `chats` | integer | 25 | 1–40 |
| `density` | string | `cosy` | `compact`, `cosy`, `roomy`, `spacious` |
| `refreshIntervalSec` | integer | 120 | 30–3600 |
| `pausePolling` | boolean | true | |
| `icon` | string | `󰊻` | |
| `label` | string | `""` | |
| `ipcTarget` | string | `""` | Names the **dropdown's** IpcHandler |
| `tintOnUnread` | boolean | true | |
| `notify` | boolean | true | |
| `agentHandover` | boolean | true | |

`demo` and `demoOpen` exist only for the harness and the showcase.

**`calendarView` is a setting; switching in the window is for that look only** —
flipping to Month for one glance is not a preference worth writing to
`shell.json`.

### 6.1 Live configuration on this machine

```json
{
  "id": "janrenz.omarchy.teams",
  "account": "german-uds",
  "authority": "german-uds.de",
  "clientId": "b4221167-…",
  "density": "cosy",
  "sendFiles": true, "setPresence": true, "holdPresence": true,
  "calendar": true, "calendarWrite": true, "meetingReminders": true
}
```

Every optional tier is on here, which means all six scopes are declared on that
registration.

---

## 7. Data shapes

### 7.1 Message row (`message_row`)

```
id, from, fromId, when, text, links[], edited,
images[], attachments[], quotes[], reactions[], system
```

`links` is where the links are, rather than the links themselves. `system` is
true for anything whose `messageType` is not `message` — "X added Y to the chat"
has no sender and reads oddly in a list of things people said.

### 7.2 Account view (`fetch_account`)

```
ok, alias, username, displayName, userId,
channels, canMarkRead, canUpload, canStartChat,
presence, canSetPresence, calendar, canWriteCalendar,
me, chats[], teams[], unreadCount, warnings[]
```

Presence for the whole chat list is **one batched request**, and only when the
sign-in is allowed to ask. **The user's own id rides along in the same batch** —
the picker has to say what it is about to change, and that request takes 650 ids,
so asking about one more person costs nothing at all.

### 7.3 Event row (`event_row`)

```
id, subject, preview, when, until, startDate, endDate,
allDay, minutes, where, online, joinUrl,
organizer{name,address}, isOrganizer,
response, responseRequested, showAs, cancelled,
recurring, seriesId, important, private, categories[], attachments
```

With `detailed=True` it also carries `text`, `links[]`, `truncated`,
`attendees[]`, `newTimeProposals`.

- `startDate` / `endDate` are the **local** days the columns group by, `endDate`
  computed from the last moment covered (§4.1).
- `response` is `RESPONSES[...]` or `"none"` — **the window offers an answer only
  where there is a question.**
- `recurring` covers an occurrence, an edited occurrence, or the series itself,
  drawn as a mark the way every calendar marks a repeat.
- `links` on a detailed event are filtered to spans inside `EVENT_BODY_CHARS`,
  the same offsets a message carries and for the same reason.

---

## 8. UI surfaces

### 8.1 Bar widget (`BarWidget.qml`, 155 lines)

Left click is the dropdown, right click is the window. Elects `notifies`.

### 8.2 Dropdown (`BarPanel.qml`, 435 lines)

**Presence, and what is unread. Two things on purpose** — its header says why the
rest is not there. Plus `m`, which marks all of them read and **is the one thing
here that cannot be undone, so it is armed by the first press and done by the
second.**

**The dropdown fetches nothing**: it binds to the Service the bar icon already
owns with `unreadOnly` fixed on it.

The presence picker **takes the panel over rather than dropping across it** —
there is no room to overlay a popup on itself — and `Escape` there backs out to
what is unread rather than closing the panel.

### 8.3 Window (`TeamsWindow.qml`, 2543 lines)

Sidebar, transcript, message box, and the calendar beside them. `pane` says
which of the two is on screen. Also the file chooser and the window-wide
`DropArea`, both ending at `sendFile()` — the one place a `file://` URL becomes a
path.

### 8.4 Calendar components

| File | |
|---|---|
| `CalendarPane.qml` | The toolbar, and which body goes under it |
| `CalendarGrid.qml` | The clock face: a column per day, blocks by the minute, the all-day strip, the line across today |
| `CalendarMonth.qml` | Six rows of seven days, as many chips as a cell holds and a count of the rest |
| `EventChip.qml` | One meeting, in all three — it takes its height from whoever placed it, because in a day column that height **is** how long the meeting is |
| `EventDetail.qml` | One meeting opened: attendees, agenda, Join, the three answers, calling it off |
| `NewMeetingForm.qml` | Booking one. **The window owns the draft; this edits it** |

The month grid **runs into the months either side** rather than leaving the
corners blank — those are real days with real meetings on them, and a grid
showing the 1st as empty because the week began in August would be saying
something untrue.

**An agenda instead, when the window is too narrow for columns.** A week of
columns forty pixels wide is a week nobody can read, and this window is as often
tiled into a third of a screen as not.

**Colour means availability, not decoration:** busy, tentative, free, out of
office, working elsewhere, in the running theme's hues. An unanswered invitation
is an **outline**, because that is the one state with something still to do about
it; anything declined or cancelled is **faint**; a meeting happening *now* takes
the accent.

### 8.5 Presence components

`PresenceDot.qml` (the circle — four states, one place they are drawn),
`PresenceChip.qml` (circle plus word, and the click that opens the picker),
`PresenceMenu.qml` (the picker, numbered; **it is also what knows row 0 is
Automatic**). Both surfaces show the one menu, so the numbers mean the same thing
whichever is open.

### 8.6 Keymap

Beyond the shared set in `PLATFORM.md` §9.1:

| Key | |
|---|---|
| `1`–`6` | Pick that reaction, or take yours back |
| `n` | Start a new chat |
| `p` | Set your presence, or hand it back to Teams |
| `c` | The calendar, and back to the conversations |

**In the calendar:**

| Key | |
|---|---|
| `j` / `k` | The meeting before / after |
| `h` / `l`, or `[` / `]` | The period before / after |
| `1`–`4` | Day, work week, week, month |
| `v` | The next view along |
| `t` | Back to today |
| `Enter` | Open the meeting under the cursor |
| `J` | Join it |
| `n` | Book a meeting |
| `1` / `2` / `3` | In a meeting: accept, tentative, decline |
| `x` | In a meeting: call it off. **Asked twice** |

---

## 9. Window IPC

`TeamsWindow.open(payloadJson)` → `applyPayload`:

| Key | Meaning |
|---|---|
| `chat` | reveal this chat |
| `team` + `channel` | …or this channel |
| `message` | …and this message |
| `draft` | put an agent's answer in the message box, **unsent** |

Harness routes, which exist because **offscreen means no keyboard reaches the
window and every one of the calendar's controls is a key**:

```bash
ipc call dev state | open | spacing | pane | account | size
ipc call dev calendar <view> <anchor>       # switch and report
ipc call dev meeting <id>                   # open one
ipc call dev answer <accept|tentative|decline>
ipc call dev book <subject> <date> <from> <to>
```

`dev size` is there for the layouts that only appear when there is no room — the
list drawer and the calendar's agenda — **though the offscreen platform ignores a
resize**, so those are checked against the real shell or by forcing the branch.

---

## 10. Limits and caps

| Constant | Value |
|---|---|
| `CHAT_CAP` | 40 |
| `TEAM_CAP` / `CHANNEL_CAP` | 30 / 40 |
| `MESSAGE_CAP` | 50 |
| `MAX_RESPONSE_BYTES` | 8 MB |
| `ATTACHMENT_CAP` | 10 |
| `QUOTE_CAP` / `QUOTE_CHARS` | 4 / 400 |
| `NAME_LOOKUP_CAP` | 20 |
| `IMAGE_CAP` | 12 MB |
| `UPLOAD_CAP` | **4 MB** — one Graph content PUT |
| `CALENDAR_CAP` / `CALENDAR_DAYS_CAP` | 250 / 62 |
| `EVENT_BODY_CHARS` | 20 000 |
| `ATTENDEE_CAP` | 60 |
| `PRESENCE_TTL` | 5 min |

### 10.1 Host allowlist

**One host, in both directions.** `GRAPH_HOST_NAME` is `graph.microsoft.com`;
`LOGIN_HOST` is `login.microsoftonline.com`.

- `API_OPENER` — Graph and login
- `IMAGE_OPENER` — Graph only
- `UPLOAD_OPENER` — Graph only, **refusing redirects**

**Anything not on `graph.microsoft.com` is dropped from a message entirely.**

---

## 11. Error codes

`auth_required`, `bad_alias`, `bad_date`, `bad_image_host`, `bad_presence`,
`bad_range`, `bad_reaction`, `bad_redirect`, `bad_response`, `bad_target`,
`bad_time`, `calendar_failed`, `calendar_permission_required`,
`calendar_write_permission_required`, `cancel_failed`,
`channel_files_unsupported`, `channels_failed`, `create_failed`,
`create_permission_required`, `devicecode_failed`, `empty`, `empty_file`,
`empty_query`, `event_failed`, `event_gone`, `expired`, `image_failed`,
`image_too_large`, `login_failed`, `mark_read_failed`,
`mark_read_permission_required`, `messages_failed`, `new_event_failed`,
`no_client_id`, `no_file`, `no_palette`, `no_pending_login`, `no_people`,
`no_subject`, `not_an_image`, `no_user_id`, `people_permission_required`,
`people_search_failed`, `permission_required`, `post_failed`, `presence_failed`,
`presence_permission_required`, `react_failed`, `react_permission_required`,
`response_too_large`, `rsvp_failed`, `send_failed`, `share_failed`, `too_large`,
`unreadable`, `upload_failed`

`GRAPH_PLAIN_ENGLISH` / `friendly()` map Graph's own wording to sentences.

---

## 12. Security invariants

Verbatim from `AGENTS.md`. `PLATFORM.md` §2 carries 1, 3, 4, 5, 8 and 9 in
shared form.

1. The tokens never reach QML — `~/.local/state/omarchy/teams/`, mode 600, on
   stdin. **`clientId` and `authority` are the only settings that belong in
   `shell.json`.** What somebody wrote goes the same way: `send` and `upload`
   read `{"text": …}` / `{"file": …}` on stdin. A path is resolved once (§4.2).
2. **The window never fetches anything remote, and nothing but Graph is talked to
   in either direction.** Inline images live behind Graph and need the token; the
   helper fetches, and the host is checked *before* the token is attached. A
   redirect is part of that check; `urllib.request.urlopen` is called nowhere and
   **a test asserts that**.
3. A message never chooses its own markup. Teams messages are HTML written by
   whoever sent them and Qt's rich text fetches what it is told to fetch, so
   `teams.py` flattens it. Emoji come from the character Teams already puts in the
   tag's `alt`.
4. Stdlib only.
5. Every helper command prints one JSON object and exits 0 even on failure.
6. **A calendar is drawn in local days, and only `teams.py` knows what those
   are** (§4.1).
7. **There is no default client id, and there cannot be one** (§2).
8. No symlinks anywhere in the repo.
9. Colours and spacing come from `qs.Commons`.

---

## 13. Known non-goals

Recorded because they are decisions, not omissions. Full prose in `README.md` →
*What it does not do*.

- **No live updates.** Graph change notifications need a public webhook endpoint,
  which a desktop shell has no business running.
- **Joining opens something else.** A meeting is audio, video and screen sharing;
  this is a QML panel over a Python helper. Everything *around* the meeting is
  here so that opening the other thing is the last step rather than the first.
  **This is not a gap waiting to be closed.**
- **A meeting can be booked and called off, but not edited.** Moving one,
  renaming it, or changing who is invited is a form with a recurrence editor in
  it, and that is a feature of its own.
- **One calendar: yours.** Not a shared one, not a room's, not a colleague's —
  and no free/busy lookup of anybody else before booking. What is shown is what
  `/me/calendarView` answers.
- **A whole-day event is drawn on each day it covers**, not as one bar spanning
  them. Both say the same thing; the bar is the harder one to lay out beside
  meetings that begin mid-morning.
- **No reminders inside the window**, and none for what is already running: the
  notification *is* the reminder, it comes from the poll rather than a timer of
  its own.
- **No search, anywhere.** Graph has one; this plugin does not use it.
- **No status message.** Teams lets you write a line under your presence and
  Graph will take one. A text field with an expiry and an @-mention picker in it
  is a different feature.
- **No "in a call", and no reading back which presence you chose** (§4.3).

---

## 14. Development

Per `PLATFORM.md` §10, plus:

```bash
node    dev/test-model.js                          # 929 lines
python3 dev/test-teams.py                          # 1777 lines
python3 src/teams.py fetch --account work --demo
python3 src/teams.py calendar --account work --from 2026-09-04 --days 7 --demo
dev/run.sh ; dev/shot.sh /tmp/teams.png [demo-chat-0] ; dev/showcase.sh
```

Stage: `$XDG_RUNTIME_DIR/omarchy-teams-dev`. **`dev/stage.sh` decides where, and
refuses to fall back to shared temp.**

`--demo` runs through the whole plugin: every read is answered from fixtures, and
**every write — sending, starting a chat, marking read — returns as if it had
happened and posts nothing.**

**A full `dev/run.sh` after touching a signal handler is what catches the
two-handler failure** described in `PLATFORM.md` §10.2. A harness that comes up is
the proof; `run.sh` reporting that it never came up is the failure.
