# GAPS.md — Microsoft Teams for Omarchy

**Companion to [`SPEC.md`](SPEC.md).** That file says what the plugin does; this
one says what it does not do *that it arguably should*, and where the spec has no
answer at all.

Written 2026-09-04 against version 0.6.1. Every finding carries the evidence it
was drawn from, so it can be re-checked rather than believed.

## How to read this

| | |
|---|---|
| **Gap** | Behaviour or a contract that is missing, and whose absence is not a stated decision |
| **Divergence** | Something two of the three plugins do and this one does not |
| **Unspecified** | Code decides it; no document says what the decision should be |

**Severity is about consequence, not effort.** `high` means it can lose data,
leak a credential, or break a stated invariant. `medium` means a user meets it.
`low` means a maintainer meets it.

## What is *not* in here

`README.md` → *What it does not do* lists **deliberate non-goals**, and they stay
that way: the six reactions, no channel unread counts, teams closed until opened,
no live updates, files into chats only and 4 MB, joining handing off, a meeting
bookable but not editable, one calendar, whole-day events drawn per day, no
in-window reminders, no message search, no status message, no "in a call".
`SPEC.md` §13 records them. **Do not re-raise them as findings.**

Joining in particular is not a gap: *"a meeting is audio, video and screen
sharing, and this is a QML panel over a Python helper."*

---

## TEAMS-1 — A channel's replies are invisible · `high` · Gap

**In a Teams channel this plugin reads root posts only. Every reply is
unreachable — it cannot be read, and it cannot be written.**

`cmd_messages` (`teams.py:1114`):

```python
elif args.team and args.channel:
    path = "/teams/%s/channels/%s/messages" % (…)
```

Graph's channel `/messages` returns **root messages**. A reply lives at
`/teams/{team}/channels/{channel}/messages/{id}/replies`, and that endpoint is
called nowhere:

```
$ grep -n 'replies' src/teams.py
2785:# different lengths, both sides of the thread, one that was edited - which two
```

The one hit is a comment in the demo fixtures. `cmd_send` for a channel posts to
the same `/messages` collection, so what it creates is always a **new root
post**, never a reply. And `message_row` carries no reply count — compare the
Slack plugin's, which has `threadTs`, `replyCount`, `replyUsers`, `latestReply`
and `threadUnread`.

**Why this is severe rather than cosmetic:** a Teams channel is
reply-threaded by construction. Most channels hold a handful of root posts with
the entire conversation hanging off them as replies. So a channel that is busy
reads here as a channel that is nearly silent, and a user answering what they see
posts a new top-level message into a channel where everybody else is replying in
a thread.

**Why it belongs in this file rather than in the non-goals:** it is not in them.
`README.md` says *"**Replying**, to a chat or a channel"* — which is true of
posting a message and not true of replying to one — and the *What it does not do*
list, which is otherwise scrupulous, does not mention replies at all. The
`Quotes and forwards` section covers a different thing: a **chat's**
`messageReference` quote-reply.

**What the spec should say:** either channel replies are read (one
`/replies` request per root post the user opens — the same shape as
`conversations.history` in Slack, and Graph does not ration it the way Slack
does) and written (`POST …/messages/{id}/replies`), or the README states plainly
that channels show root posts only and says why. The second is a legitimate
answer — it costs a request per post opened — but it has to be an answer rather
than a silence.

---

## TEAMS-2 — Three Services, three polls, and no coordination · `high` · Divergence

This is the plugin's own stated open problem, from `AGENTS.md`:

> **`Service.qml` is instantiated more than once.** `BarWidget.qml` has one and
> `TeamsWindow.qml` has another, and the bar is one surface *per monitor* — so a
> two-monitor desktop with the window open polls the account three times an
> interval. The mail plugin solved the same problem by moving the data into a
> `kinds: ["service"]` singleton (`Store.qml`); this plugin has not yet.

Both other plugins have solved it, and by different means (`PLATFORM.md` §6):
mail with the singleton, Slack with an `flock` in the helper that hands a waiting
caller the snapshot the holder wrote. **This plugin has neither.**

Live configuration on this machine makes the cost concrete: `refreshIntervalSec`
120, with `calendar`, `calendarWrite`, `setPresence` and `holdPresence` all on.
Each Service's poll is a `fetch` — chats, plus teams when allowed, plus a batched
presence request. Graph throttles per application per tenant, so three of
everything is three times closer to a 429 than it needs to be, and a poll is also
a token refresh.

The calendar itself is **not** part of that multiplication, and the gating is
worth crediting: `calendarActive` is `pane === "calendar" && window.visible`, so
only the window loads it, and the reminder path is behind `wantsMeetingAlerts`,
which requires `notifies` (`Service.qml:1481`). That is the right shape — but see
`TEAMS-3`, because on this plugin `notifies` is not what it is in Slack.

**One consequence worth stating separately:** `markAllRead` from the dropdown is
the one thing here that cannot be undone (`BarPanel.qml`, armed by the first
press and done by the second). After it runs, the *other* Services still hold
their own snapshots and keep showing what was just cleared until their own timers
fire — the same lag documented as `SLACK-1` in the Slack repo, but with a longer
reach here because there is no lock making the snapshots agree either.

**What the spec should say:** which of the two existing answers this plugin
adopts. Given it needs both shared fetches *and* shared read state, the mail
plugin's singleton is the closer fit; given manual refresh and `markAllRead`,
Slack's argument that a lock covers what a singleton does not applies here too.
That is a decision, and `PLATFORM.md` §6 currently records three states rather
than one choice.

---

## TEAMS-3 — There is no `notifies` election: every bar instance announces · `high` · Divergence

`BarWidget.qml:97`:

```qml
Service {
    id: service
    // The bar is always here and the window is not, so new messages are
    // announced from behind the icon rather than from behind the window.
    notifies: true
}
```

**Unconditionally true.** Slack's equivalent (`BarWidget.qml:123`) is
`notifies: root.primaryInstance`, elected from
`bar.moduleWidgets(root.moduleName)[0]` and reading `bar.moduleSlots` so that it
**re-elects when a monitor is unplugged**. Its comment is this one's plus the
clause this one is missing:

> announced from behind the icon rather than from behind the window — and **from
> behind one icon rather than one per monitor.** See `primaryInstance`.

`PLATFORM.md` §4.2 states the election as the shared contract, and Slack's
`AGENTS.md` records the bug it was written for:

> Before that election every copy of the widget announced: two monitors, two
> toasts per message, each with its own replace-id so they stacked instead of
> updating.

**The bar is one surface per monitor**, so on a two-monitor desktop this plugin
has two bar Services with `notifies: true`, and three things follow — each of
them the duplicate Slack already fixed:

| Behind `notifies` | Consequence of two |
|---|---|
| `Notifier` for new messages | Two toasts per message, each with its own `-r` replace-id, so they **stack instead of updating** |
| `wantsMeetingAlerts` (`Service.qml:1481`) | Two reminders per meeting, and two calendar loads driving them |
| `holdSession` / `hold-presence` heartbeat | Two renewals of one session every twenty minutes |

The presence one is the least harmful — `AGENTS.md` notes Graph names the session
after the application, so two renewals collide on one session rather than
creating two — but it is still twice the requests, and `AGENTS.md` says the
heartbeat *"sits behind `notifies`, the same 'one of the three Services does
this' flag the notifications use."* **On this plugin that flag does not mean
that.**

Note also that `Notifier.observe` being idempotent does *not* save it here.
Idempotence protects against one Service announcing a snapshot it inherited
(Slack's `SPEC.md` §2.4); it does nothing about two separate Services each with
their own `observe` state, which is exactly this case.

**What the spec should say:** `notifies` is elected, not asserted — port
`primaryInstance` from Slack, including the `moduleSlots` read that makes it
re-elect. This is the smallest high-severity fix in the set: the code to copy
exists, in a sibling repo, with its rationale attached.

---

## TEAMS-4 — `Notifier.qml` is a copy of the mail plugin's, prose and all · `low` · Gap

`diff src/Notifier.qml ../janrenz.omarchy.slack/src/Notifier.qml` — 12 differing
lines, and every one of them is this plugin still describing a mailbox:

| This repo says | Slack's copy says |
|---|---|
| "wakes up to a morning's **mail**" | "wakes up to a morning of **messages**" |
| "is an entire **mailbox** at once" | "is an entire **backlog** at once" |
| "Scopes keep one **mailbox's** first round…" | "…one **workspace's** first round…" |
| "a **store** watching two accounts primes each" | "a **service** watching two of them primes each" |
| "announce the whole **mailbox**" | "announce everything waiting" |

There is no mailbox in this plugin and no store — `SPEC.md` §5 records that the
absence of a store is one of its defining facts (see `TEAMS-2`). The file was
copied from `caseonline.omarchy.office365` and the comments were never rewritten;
Slack's copy was.

Harmless at runtime. It matters because `AGENTS.md` and `PLATFORM.md` §11 both
make comments load-bearing — *"state plainly what would otherwise only live in
the git log"* — and a comment describing the wrong plugin is worse than none. It
is also the clearest single piece of evidence for `PLAT-1`.

**What the spec should say:** nothing new. Rewrite the five comments, or make
`Notifier.qml` genuinely shared and stop pretending three copies are three files.

---

## TEAMS-5 — Lists are `Repeater`s; mail's diffing model was never ported · `medium` · Divergence

The mail plugin's `AGENTS.md`:

> **`MailList.qml` is a `ListView` on purpose**, and the comment at the top says
> why a `Repeater` over a plain array was worse. The Slack and Teams plugins have
> not made that change yet; if you are porting UI between them, port this too.

Every list here — the transcript included — is a `Repeater` inside a
`ScrollView`. Every row is instantiated, and every row is rebuilt whenever the
array is replaced. A `ListView` over a plain JS array recreates *all* of its
delegates when the array changes, so `reuseItems` alone buys nothing. The trade
between the two diffing models is written up in `PLATFORM.md` §9.2.

**It costs more here than in Slack**, because of the calendar. `EventChip` is
instantiated for every event in every day column of the current span, and
`SPEC.md` §4.7 already records one consequence: `service.clock` ticks every
minute and *"the day columns must not"* bind to it, **or every delegate in the
grid is rebuilt once a minute.** That mitigation exists because the rebuild is
expensive. A diffing model would make the constraint less sharp.

**What the spec should say:** which model the transcript and the calendar grid
use, and why. The analysis is done and written down in two repos; the decision is
what is missing.

---

## TEAMS-6 — `cursoredMessage()` is inlined twice · `low` · Divergence

`AGENTS.md` warns about it rather than fixing it:

> **There is no `cursoredMessage()` here.** The Slack plugin has one; this window
> inlines "the cursor, or the newest if it is nowhere yet" in `startPicking` and
> in `agentArgv`. Copying code across from that repo without checking will produce
> a `ReferenceError` that only shows up in the log.

Two copies of one rule, in a file where — per `PLATFORM.md` §10.2 — an
unresolved name is **not** a parse error, throws once per binding into the
shell's log, and leaves whatever depended on it undrawn. That is how inline
pictures disappeared in 0.4.3 while the fetch behind them worked perfectly.

The known failure mode is documented and the thing that causes it is still
there.

**What the spec should say:** nothing new. Extract the function; the warning
becomes unnecessary.

---

## TEAMS-7 — `demo` is load-bearing and unspecified · `medium` · Unspecified · shared: `PLAT-3`

`Service.qml` reads `setting("demo", false)` and `demoOpen`, and `--demo` is what
makes every write — sending, starting a chat, marking read, RSVPing, booking,
cancelling — return as if it had happened and post nothing. Neither appears in
any manifest schema in any of the three plugins:

```
caseonline.omarchy.office365/manifest.json   occurrences of "demo": 0
janrenz.omarchy.slack/manifest.json          occurrences of "demo": 0
janrenz.omarchy.teams/manifest.json          occurrences of "demo": 0
```

So they cannot be set from the settings panel, are not documented as settings,
and escape the rule in `PLATFORM.md` §3 that adding a setting means adding it to
the manifest *and* reading it through `setting()`.

**The stakes are higher here than in the other two**, because `calendarWrite` is
on in the live configuration: the writes `--demo` neutralises include
`cancel-event`, and `SPEC.md` §8.6 records that cancelling *"asks twice — there
is no route back from either."*

The mail plugin has already been bitten by this class: a harness whose fixture
alias was a real signed-in mailbox pressed Send and made a real API request, and
only a malformed id stopped it.

**What the spec should say:** either `demo` is a real setting with a schema entry
saying plainly what it disables, or it is a harness-only override read from
somewhere that is not the widget's settings — and the choice is stated.

---

## PLAT-1 — Shared components are copies, and they have drifted · `medium` · Divergence

Line-counts of `diff` output between the three repos' copies of the same file:

| File | slack↔teams | mail↔slack | mail↔teams |
|---|---|---|---|
| `src/config.py` | **2** | 219 | 219 |
| `src/SelectableText.qml` | **2** | 14 | 14 |
| `src/ImageViewer.qml` | **4** | n/a | n/a |
| `src/Notifier.qml` | 12 | 20 | 10 |
| `src/PollGate.qml` | 14 | 4 | 10 |
| `src/LabeledField.qml` | 7 | 28 | 21 |
| `src/handover.sh` | 54 | — | — |
| `src/Model.js` (first 190 lines) | 48 | — | — |

`config.py` differs from Slack's copy by **exactly one line** across 151 — the
default `--plugin-id`.

`PollGate.qml` is the instructive one, because its 14-line diff from Slack's is
**almost entirely a real feature**: this plugin added `needIdle` and `idleNow` so
the presence session can follow the desktop without asking the poll timer to
stop over it. Slack's copy carries a rate-limit rationale this one lacks. So the
file is a genuine fork of a genuine common core — and nothing separates the two.

`Model.js`'s first ~190 lines are the same helpers in both plugins with 48 lines
of drift, mostly comment wording, some of it real: `reactionIsMine` keys on
`emoji` here and on `name` in Slack, because the two APIs name the field
differently. **A shared function with a plugin-specific key is a function that
looks portable and is not**, and nothing marks it.

`TEAMS-4` is the same problem showing its other face: a copy nobody updated.

**No mechanism and no document says which copy is canonical.** The redirect
guard, the poll gate and the link builder each have to be fixed three times by
somebody who knows all three repos have them.

**What the spec should say:** either a canonical source and a sync step in the
release ritual, or an explicit decision that these are forks and drift is
accepted — with the common core separated from the per-plugin fork in the files
where both exist. `PLATFORM.md` describes the shared contract without saying who
owns the shared code.

---

## PLAT-2 — Three answers to the several-Services problem, and no platform decision · `medium` · Unspecified

Folded into `TEAMS-2`, which is this plugin's side of it. The platform-level
statement that is missing: which of the singleton and the lock a fourth plugin
should adopt, and that a plugin needing shared *UI* state needs something the
lock alone does not give it.

---

## Summary

| ID | Severity | Class | One line |
|---|---|---|---|
| TEAMS-1 | high | Gap | A channel's replies cannot be read or written, and it is not a stated non-goal |
| TEAMS-2 | high | Divergence | Three Services, three polls; both other plugins solved this |
| TEAMS-3 | high | Divergence | `notifies: true` unconditionally — every bar instance announces, on every monitor |
| TEAMS-4 | low | Gap | `Notifier.qml` still describes a mailbox and a store |
| TEAMS-5 | medium | Divergence | Lists are `Repeater`s; costs most in the calendar grid |
| TEAMS-6 | low | Divergence | `cursoredMessage()` inlined twice, with a warning instead of a fix |
| TEAMS-7 | medium | Unspecified | `demo` neutralises `cancel-event` and is in no manifest |
| PLAT-1 | medium | Divergence | Shared components are copies with silent drift; no canonical source |
| PLAT-2 | medium | Unspecified | Three answers to the several-Services problem, no platform decision |
