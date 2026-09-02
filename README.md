# Microsoft Teams for Omarchy

Teams chats and channels in the Omarchy bar, and in a window of their own.

- **A bar icon** that tints when a chat is unread, with a tooltip naming the account and the count.
- **A dropdown behind it**, and deliberately only two things: your presence, and what is unread. Those are the two questions a bar is asked — *how do I look to people* and *does anything need me* — and both are answered by picking from a short list, which is what a popup that closes on click-away can do. Reading a conversation and writing a reply is not, so a row here opens the window at that chat rather than being a smaller copy of it. Right-click the icon to skip the dropdown and go straight to the window.
- **A window** — a real Hyprland toplevel, tiled like anything else — with conversations on the left, the transcript on the right, and a box to answer in. Bound to `SUPER+G`, also on the Omarchy menu under *Teams*.
- **Chats and channels.** One-to-one chats, group chats, and the channels of every team you have joined.
- **Replying**, to a chat or a channel. `Shift+Enter` or `Ctrl+Enter` sends; plain `Enter` is a newline, because a chat box that sends on Enter posts half-written thoughts.
- **Starting a chat** with anybody in the directory, and **marking a chat read** by opening it.
- **A picture opens in the window**, whole rather than cropped to the thumbnail, with **Save as…** to keep a copy — a real save dialog, starting in your Downloads folder and suggesting a name from what the message called the picture. `s` saves, `o` hands it to whatever else views images, `Escape` closes. It used to go straight to `xdg-open`, which took the one thing anybody opens a picture for somewhere this plugin could not follow.
- **Emoji, inline images and clickable links** in the transcript. Both kinds of link: an address somebody typed out in full, and one behind its own words — the composer's link button writes `<a href="…">the release notes</a>`, and the words are all a reader would otherwise get. They open in your browser, tinted from the running theme rather than in Qt's blue.
- **Presence.** Beside each one-to-one chat: a filled circle for available, a filled circle for busy, a ring for away, a dim circle for offline — in the running theme's own colours. Group chats have none, because a group is not away. Told apart from unread by shape and place, not by hue: presence sits immediately in front of the name because it is about the person, unread is a bar down the leading edge because it is about the conversation, and a chat can show both. Needs `Presence.Read.All` — ordinary user consent.
- **Your own presence, set from here.** `p`, or the dot in the header: Available, Busy, Do not disturb, Be right back, Appear away, Appear offline, and *Automatic* to hand it back to Teams. It is the client's own status menu, written through Graph, and it sticks until you hand it back. This one needs `Presence.ReadWrite`, which an administrator has to consent to — writing your own presence is the dearer permission, not reading everybody's — so it is off until you turn it on. There is a second setting for the part nobody expects: a presence you set only shows while Teams believes you are signed in *somewhere*, so the plugin can be that somewhere. See [Your presence](#your-presence).
- **Reactions.** The ones already on a message, counted, with yours marked - click a chip to add or remove yours. The pointer on a chip says who reacted, what Teams calls that reaction, and which of the two a click would do. Reacting is a keyboard job first: `j`/`k` walk the transcript a message at a time, `e` opens the picker on the one under the cursor, and `1`-`6` pick. The mouse can do it too, from the `+` that appears on the message you are pointing at.
- **Keyboard first.** The whole window drives from the keyboard — see below, or press `?` in the window.

![The conversation list, and a chat open beside it](showcase-conversation.png)

![The conversation list](showcase-conversations.png)

Python 3 standard library only. It talks to Microsoft Graph and nothing else. No token ever reaches the QML: `src/teams.py` holds them, and the shell reads JSON from it.

## Installing

```
omarchy plugin add https://github.com/janrenz/omarchy-teams.git --enable
omarchy bar set janrenz.omarchy.teams clientId <your-application-client-id>
```

The client id is not optional, and no default could stand in for it: the sign-in goes against an app registration of yours, described below. Reload the shell afterwards and the icon is in the bar.

Nothing outside the plugin's own directory is written on install, and no configuration of yours is overwritten — the settings live in the widget's own entry in `~/.config/omarchy/shell.json`, alongside whatever else is already in there.

## Removing

```
omarchy plugin remove janrenz.omarchy.teams
```

That takes the plugin off the disk. Three things of yours live outside it and are deliberately left behind — delete them yourself if you want them gone:

| Path | What is in it |
|---|---|
| `~/.config/omarchy/shell.json` | Your settings, in the widget's entry. |
| `~/.local/state/omarchy/teams/` | The tokens. Delete this to sign out. |
| `~/.cache/omarchy/teams/images/` | Images already fetched from Graph. |

The app registration in Azure is yours and is untouched either way; delete it in the portal if you are done with it.

## Keyboard

Press `?` in the window for this same list. Omarchy is keyboard-first, so the
window is a focus ladder rather than a bag of shortcuts: **list → conversation
→ message box**. `h` and `l` step between the rungs, `Escape` walks back out
one rung at a time, and `j`/`k` always mean "down and up in whatever has
focus".

The dropdown behind the bar icon has its own handful, because it holds its own
two things: `p` opens the presence picker (`0`–`6` pick, `Escape` goes back),
`o` opens the window, `r` refreshes, `j`/`k` and `Enter` walk what is unread,
and `Escape` closes it.

### Moving

| Key | What it does |
|---|---|
| `j` / `k`, `↓` / `↑` | Down and up in whatever has focus — the conversations, or the messages in the open one |
| `Enter` | Open the conversation under the cursor, and move focus into it |
| `h` / `←` | Back to the list, **leaving the conversation open**. Narrow windows slide the list out over it |
| `l` / `→` | Into the conversation; again into the message box |
| `Tab` or `i` | Straight to the message box |
| `Escape` | Back one step: reaction picker → message box → conversation → list → close the conversation → close the window |

Escape never skips a rung. Going back to the list does not close what you were
reading, which is the step that used to be missing.

### Scrolling

| Key | What it does |
|---|---|
| `Page Up` / `Page Down` | A screenful of whatever has focus |
| `Ctrl-u` / `Ctrl-d` | Half a screen |
| `Ctrl-b` / `Ctrl-f` | A screen |
| `g` / `G` | To the top / to the newest |
| `Home` / `End` | The same as `g` / `G` |

### Doing

| Key | What it does |
|---|---|
| `a` | Hand this conversation to your coding agent — see below |
| `e` or `+` | React to the message under the cursor. Again, or `Escape`, closes the picker |
| `1` – `6` | Pick that reaction. The one you already gave takes it back |
| `s` / `o` | In a picture: save a copy / open it elsewhere |
| `Shift+Enter` or `Ctrl+Enter` | Send. Plain `Enter` is a newline |
| `u` | Show only unread conversations |
| `n` | Start a new chat |
| `p` | Set your presence, or hand it back to Teams |
| `r` | Reload the open conversation |
| `,` | Settings |
| `?` | This list |

Opening the window itself is `SUPER+G`, or *Teams* in the Omarchy menu.

## You need your own Azure app registration

This is the one part nobody can do for you, and it is not optional.

An Azure app registration declares up front which delegated permissions it is allowed to request. A registration set up for mail therefore *cannot* ask for `Chat.Read` — the consent screen refuses before you ever see it. So unlike the Office 365 mail plugin, this one ships no default client id.

1. Go to **Azure Portal → Microsoft Entra ID → App registrations → New registration**.
2. Name it whatever you like. Under *Supported account types* pick **Accounts in this organizational directory only** unless you know you need otherwise. Leave the redirect URI empty.
3. Open the new registration → **Authentication** → *Advanced settings* → set **Allow public client flows** to **Yes**. This is what enables the device-code sign-in. Save.
4. Go to **API permissions → Add a permission → Microsoft Graph → Delegated permissions** and add:

   | Permission | For | Consent |
   |---|---|---|
   | `User.Read` | knowing who you are | user |
   | `Chat.ReadWrite` | reading your chats, and marking one read by opening it | user |
   | `Chat.Create` | starting a new chat | user |
   | `ChatMessage.Send` | replying in a chat | user |
   | `People.Read` | finding the people you talk to | user |
   | `User.ReadBasic.All` | finding everybody else | user |
   | `Team.ReadBasic.All` | listing your teams | user |
   | `Channel.ReadBasic.All` | listing their channels | user |
   | `ChannelMessage.Read.All` | reading channel messages | **admin** |
   | `ChannelMessage.Send` | posting in a channel | user |
   | `Presence.Read.All` | the presence dot beside a one-to-one chat | user |
   | `Files.ReadWrite` | sending a file into a chat — optional, see below | user |
   | `Presence.ReadWrite` | setting your own presence — optional, see below | **admin** |

   `Chat.ReadWrite` rather than `Chat.Read` on purpose: marking a chat read is
   a write, and `markChatReadForUser` refuses anything less. Everything in that
   list except the channel row is ordinary user consent.

   The last two are the permissions this plugin does not ask for unless you say
   so, and for `Files.ReadWrite` the reason is not consent: a registration
   declares which permissions it may *request*, so asking for one it does not
   list fails the whole sign-in rather than that one scope. Add it here and turn
   on **Send files** in the widget's settings; leave both alone and everything
   else works exactly as before.

   `Presence.ReadWrite` is opt-in for that reason *and* because of consent. It
   is the only permission besides the channel ones that needs an administrator:
   reading the whole organisation's presence is ordinary user consent, and
   writing your own is not. So a sign-in that asks for it without the grant
   fails outright, which is why it waits for **Set your presence** to be turned
   on. Everything else is unaffected either way.

5. Copy the **Application (client) ID**.
6. In Omarchy, open the Teams widget's settings and fill in **Account name** (a short label such as `work`) and **Azure client id**.
7. Open the window (`SUPER+G`) and press **Sign in**. Enter the code it shows at the URL it gives you.

### If channels are refused

`ChannelMessage.Read.All` normally needs an administrator to consent for the whole tenant. A device-code sign-in asking for it either gets everything or fails outright — it does not partly succeed. That is why the scopes are split in two:

- **Include teams and channels** off → asks only for the chat scopes, which any user can grant themselves.
- On → also asks for the channel scopes.

If the sign-in fails complaining about consent, either ask an admin to grant it, or turn the setting off and sign in for chats alone. The window has a *Sign in for chats only* button for exactly this, and says **chats only** in its header afterwards so you know why there are no teams listed. An **Add channels…** button re-runs the wider sign-in later if the grant arrives.

What the tenant actually granted is recorded from the token response rather than assumed from what was requested — an admin can withhold one scope and grant the rest, and the window hides the teams column instead of showing one that 403s on every click.

## Settings

Open the window (`SUPER+G`) and press the gear, or `,`. The form writes into
the widget's entry in `~/.config/omarchy/shell.json`; `omarchy bar set
janrenz.omarchy.teams <key> <value>` does the same thing from a terminal.

Nothing in the shell renders a settings form for a third-party bar widget - a
manifest schema is declared, but the only reference to it anywhere in the
shell is the line that writes it into the registry - so the plugin brings its
own.

| Key | Default | What it does |
|---|---|---|
| `account` | — | Short name for this sign-in. Letters, numbers, dot, dash, underscore. |
| `clientId` | — | **Required.** Your app registration's Application (client) ID. |
| `authority` | `common` | `common`, `organizations`, or your tenant id. |
| `channels` | `true` | Whether to ask for team and channel access at sign-in. |
| `sendFiles` | `false` | Whether to ask for `Files.ReadWrite` at sign-in, which is what an **Attach** button needs. Your app registration has to declare it first. |
| `setPresence` | `false` | Whether to ask for `Presence.ReadWrite` at sign-in, which is what `p` and the status chip need. Your registration has to declare it and an administrator has to consent to it. |
| `holdPresence` | `false` | Whether to hold a presence session open for this machine, so a presence you set has something to show against. Needs `setPresence`. |
| `chats` | `25` | How many chats to list (1–40). |
| `density` | `cosy` | How much room the window gives things: `compact`, `cosy`, `roomy`, `spacious`. A multiplier over the theme's own spacing, so it follows your font size rather than fighting it. |
| `refreshIntervalSec` | `120` | How often to poll (30–3600). |
| `pausePolling` | `true` | Stop polling while the screen has been idle five minutes or there is no network. Doubles the interval on battery. |
| `icon` / `label` | `󰊻` | Bar glyph, or text instead of it. |
| `ipcTarget` | — | A name of your own for the dropdown, so a key can summon it: set `teams` and bind `omarchy-shell teams toggle`. Empty means the dropdown opens by clicking the icon. The window is separate and always answers to `omarchy-shell shell toggle janrenz.omarchy.teams`. |
| `tintOnUnread` | `true` | Highlight the bar icon while a chat is unread. |
| `notify` | `true` | Desktop notification when a chat has something new in it. |
| `agentHandover` | `true` | Whether `a` and the **Ask agent** button are there at all, and whether a draft from an agent is accepted. |

## Notifications

A chat with something new in it raises a desktop notification: the chat's name, and a line of what was said. More than three arriving in one poll become a single summary instead of a stack.

What counts as new is *new since the shell started watching*, not *unread*. The first answer after a sign-in — or after a laptop wakes up to a morning of messages — is an entire backlog at once, and announcing all of it is what makes people turn notifications off for good. So the first poll of an account primes quietly and only what turns up after it is announced. Nothing you sent yourself is announced either: Graph leaves a chat you just spoke in unread until the read mark catches up.

Clicking the notification opens that chat. Several messages in one chat update one notification rather than stacking three, and the click still works after the shell has been restarted underneath it — the action travels as data on the notification rather than as a callback into the process that sent it.

## When it does not poll

A poll is also a token refresh, and Graph counts every one of them, so it stops when there is nobody to poll for. Nothing is asked of Graph while the screen has been idle for five minutes, or while the machine has no network at all, and a fetch goes out the moment you come back or reconnect rather than at the next tick. Idle inhibitors count as being present, so a full-screen call does not look like an empty desk. On battery the interval is doubled, and tripled in the power-saver profile.

Anything you ask for by hand still goes out, offline included: a failure you can see beats a silence you cannot. The bar's tooltip says why nothing is moving while it is paused. Set `pausePolling` to `false` to keep the old fixed cadence.

They are raised from behind the bar icon, not from the window, so they arrive whether or not the window is open — and only once, though both have a service of their own polling the same account.

## Your coding agent

Omarchy already knows which coding agent you use — `omarchy default agent`
picks one, `omarchy-agent` launches it. Press `a` in a chat or a channel, or the
**Ask agent** button beside the message box, and that agent opens on the
conversation you are reading.

What crosses over is a pointer, not a transcript. The prompt names the account
alias, the chat id — or the team and channel ids — and the message the cursor
was on, and points at a skill in `skills/omarchy-teams/`; the agent then reads
the conversation through `src/teams.py`, the same helper the window uses. Two
reasons for that. Anyone on this machine can read another process's command
line, and an agent window lives for hours — so other people's messages have no
business being in it. And the agent reads what is in the conversation *now*, not
what happened to be on screen when you pressed the key.

The skill tells it to draft rather than to post. An answer it writes comes back
into the message box, focused and unsent:

```bash
omarchy-shell shell summon janrenz.omarchy.teams \
  '{"draft":{"chat":"19:…@thread.v2","text":"Ich schaue morgen früh drauf."}}'
```

The window opens if it was closed. Sending stays a keypress you make — nothing
an agent does here reaches Teams.

`src/handover.sh` is what the key runs, and it is usable on its own: `--print`
shows the prompt instead of launching anything, which is also how you would
point a Hyprland binding at a particular chat.

Turn the whole thing off with `agentHandover` in the settings and the key, the
button and the help entry are gone, and a draft arriving from an agent is
refused rather than quietly applied.

## Sending a file

With `Files.ReadWrite` granted and **Send files** on, a chat gets an **Attach**
button beside Send, and a file dropped anywhere on the window goes to the chat
on screen. Whatever is in the message box goes with it as its comment.

A drop that will not go through says so while the file is still in the air: the
window outlines itself and names what is in the way — a channel rather than a
chat, a sign-in without `Files.ReadWrite`, or a file already going up.

Graph has no "post a file to a chat", and this does what Teams itself does: the
file goes to your own OneDrive, into the same **Microsoft Teams Chat Files**
folder, a sharing link is made for it, and the message carries a reference to
that link. Three requests, and only the last one puts anything in front of
anybody — so if that one fails, the plugin says the file is in your OneDrive
rather than calling it a failure, because that is where it is.

Two limits, both deliberate:

- **Chats only, not channels.** A channel's files live in the team's SharePoint
  library, and writing there needs `Files.ReadWrite.All` — a permission most
  tenants keep behind an administrator. The button is not offered in a channel
  rather than failing there.
- **4 MB.** That is Graph's limit for putting a file in one request. More than
  that needs an upload session, whose URL is on a SharePoint host, and this
  plugin talks to `graph.microsoft.com` and nothing else — which is the rule
  that stops a crafted message from making it fetch or send anything anywhere.
  The refusal says so.

Sending a file appears in your own OneDrive as well as in the chat, exactly as
it does when Teams sends one. Names collide by adding a number rather than
replacing what was there.

## Your presence

With `Presence.ReadWrite` granted and **Set your presence** on, a dot with a
word beside it appears in two places — the window's header, and the dropdown
behind the bar icon — `p` opens the menu from either, and a number picks a row:

| | |
|---|---|
| `0` | **Automatic** — hand presence back to Teams, which is its own *Reset status* |
| `1`–`6` | Available, Busy, Do not disturb, Be right back, Appear away, Appear offline |

Those six are not a choice of wording. Graph pairs an availability with an
activity and refuses combinations of its own devising, so the picker offers one
row per pair Microsoft actually documents — `Offline` with `OffWork` among them,
which is the one whose two halves differ and the one that would otherwise fail
as a `400`. What you set holds until you clear it, exactly as it does in Teams:
a preferred presence overrides whatever your clients are reporting, which is
what makes *Do not disturb* stay on while you keep typing.

It is the same menu in both places, so the numbers mean the same thing
whichever one is open. In the dropdown it takes the panel over rather than
dropping across it — there is no room to overlay a popup on itself — and
`Escape` there backs out to what is unread rather than closing the panel.

The dot says what Graph reports **now**, not what you chose. Graph will hand
back your effective presence and will not say whether a preference is behind it,
so the menu ticks the row that matches what is true rather than inventing a
memory of the last button pressed.

### The part nobody expects

A presence only exists while you have a *presence session* — a Teams client
signed in somewhere. With none, your preferred presence is stored and you are
`Offline` regardless, and a picker that appears to do nothing is worse than no
picker. Teams on your phone is a session; so is Teams on another machine.

**Let Teams see you at this machine** makes this plugin one of those clients.
It holds a session open and renews it every twenty minutes, following the
desktop rather than asserting anything: available while somebody is at the
machine, away once the screen has been idle five minutes, and let go when the
shell stops so you are not left looking available to a room you have gone home
from. Idle inhibitors count as being present, so a call does not look like an
empty desk.

It will not say more than that. Graph takes `Busy` in a session only as
*InACall* or *InAConferenceCall*, and this plugin knows about neither, so it
does not claim them to get a red dot. Busy and Do not disturb are yours to set
from the menu, where they mean you said so.

The session is named after the app registration rather than after the machine —
Graph's requirement, not a shortcut — so two machines running this plugin renew
one session between them instead of holding two.

## What it does not do

- **Only the six reactions Teams offers.** 👍 ❤️ 😂 😮 😢 😡. Graph refuses anything else with "Unicode ... is not supported", so the picker offers exactly what will work rather than letting you pick something that silently fails.
- **No unread counts for channels.** Graph will say whether a *chat* has been read since its last message, but exposes nothing equivalent for channels. Rather than invent a number, channels carry no unread mark at all.
- **Teams are closed until opened.** Their channels are one request per team; listing all of them up front cost 29 requests and two hundred rows on an account in 28 teams.
- **No live updates.** It polls on the interval above. Graph change notifications need a public webhook endpoint, which a desktop shell has no business running.
- **A message never chooses its own markup.** A Teams message is HTML written by whoever sent it, and Qt's rich text fetches what it is told to fetch. So the markup is flattened in `teams.py`, and the only tag the window ever builds is an `<a>` around text it escaped first. Emoji come from the character Teams already puts in the tag's `alt`. A link keeps its address, but as an offset into the flattened text rather than as a tag — so what reaches the window is still only words, and the window still builds every tag it draws. Only `http`, `https` and `mailto` become links, checked in `teams.py`, again in `Model.js` where the anchor is written, and once more in `openUrl` before `xdg-open` sees it; anything else stays the plain words it was.
- **Images are fetched by the helper, never by the window.** They live behind the Graph API and need your token; the host is checked before that token is attached, so an `<img src="https://evil/">` in a message cannot be used to collect it. Anything not on `graph.microsoft.com` is dropped from the message entirely.
- **Files go into chats, not channels, and up to 4 MB.** See [Sending a file](#sending-a-file) for why both of those are where they are.
- **No status message.** Teams lets you write a line of text under your presence, and Graph will take one. The six states are what the picker offers; a text field with an expiry and an @-mention picker in it is a different feature, and it is not here yet.
- **No "in a call", and no reading back which presence you chose.** Both for the same reason: the plugin will not report something it does not know. See [Your presence](#your-presence).

## Development

```
dev/link.sh          # stage the QML where Quickshell can import qs.Commons
python3 dev/test-teams.py                           # the helper: parsing, permission, hosts
node dev/test-model.js                              # the shaping the window binds to
python3 src/teams.py fetch --account work --demo    # synthetic data, no sign-in
```

`--demo` works through the whole plugin, so the layout can be built without a mailbox or a tenant. Every read is answered from the fixtures in `src/teams.py`, and every write — sending, starting a chat, marking read — returns as if it had happened and posts nothing. That is what makes it safe to drive the window automatically.

### The showcase images

```
dev/showcase.sh [outdir]     # regenerate showcase-*.png and preview.png in the repo root
```

It saves your `shell.json`, installs one demo widget in place of yours, photographs the window, and puts your configuration back — including on failure or Ctrl-C. Nothing of yours is in the images: the widget it installs carries `"demo": true` and a placeholder account, client id and tenant, so the window is drawing invented people and is not signed in to anything.

Two settings exist for its benefit, both ignored unless `demo` is on:

| Key | Does |
|---|---|
| `demo` | Answer every read from the fixtures, and refuse every write. |
| `demoOpen` | The id of a conversation to open by itself once the list loads, e.g. `demo-chat-0`. There is no key that opens a conversation — only a click, which an automated run cannot aim at a row whose position depends on the theme's font size. |

`SHOWCASE_WIDTH` and `SHOWCASE_HEIGHT` override the window size it photographs (1080×720 by default).

`preview.png` is a copy of `showcase-conversation.png` under the one name the marketplace looks for in the repository root; the script writes both so the listing card cannot drift from the screenshots in this file.

## Changelog

### 0.4.5 — 2026-09-02

- **A clicked notification shows the conversation again.** Opening a chat from
  a toast said "An account needs a name" where the messages should have been.
  `open()` asks `config.py` for the settings and then applies the payload
  without waiting for the answer, so a summon that mounts the window reached
  `fetchMessages` while the account name was still a subprocess away — and the
  helper refuses a nameless account. `fetchMessages` was the one read in this
  file with no `configured` guard, and because the recovery path re-reads the
  chat list rather than the open conversation, the error then stayed on screen
  until the chat was clicked again. The open is remembered now and run once
  there is an account to run it for, left loading in the meantime.
- **A conversation opened from a toast knows its own name.** The payload
  carries ids and no title, so the window came up called "Teams — " with a
  blank header: the row was one this file made up, and nothing re-pointed it at
  the real one when the chat list arrived. It adopts the real row now — the
  title, and the subtitle and presence that travel with it — and only while the
  title is still missing, so a row that came from the sidebar is left alone.

### 0.4.4 — 2026-09-02

- **Inline pictures are drawn again.** A message's pictures had stopped
  appearing entirely: the rounded-corner change put `canRoundPictures` on the
  frame the picture sits in, and read it unqualified from the `Loader` inside
  that frame. A QML binding sees its own object, the root of its own file and
  the ids in it — not the properties of an unnamed parent in between — so the
  lookup threw on every picture, `sourceComponent` never resolved, and the
  Loader loaded nothing. The frame has an id now and the property is read
  through it. Nothing was wrong with the fetch: the helper had been downloading
  and caching each picture all along, and the window then drew an empty box
  over it.
- **`dev open` works on a real account.** It only ever set `demoOpen`, which
  the window honours while the fixtures are on, so `dev account` followed by
  `dev open` left the demo conversation on screen beside the real sidebar and
  read as the open having been ignored. On a real account the id now goes in
  the way a clicked notification does. This is how the picture above was
  confirmed drawn.

### 0.4.3 — 2026-09-02

- **A redirect can no longer walk a token off Graph.** The host check ran on
  the URL the helper was handed, which is precisely the address a redirect
  stops being: urllib follows one by copying the request's headers onto the new
  request, `Authorization` among them, and compares no hosts while doing it. A
  `302` pointing anywhere else would have handed over a token that can read
  this account, having passed the check first. Every request now goes through
  an opener that asks again — the token comes off the moment the host changes,
  a redirect off `https` or away from `graph.microsoft.com` is refused, and the
  content PUT that sends a file follows nothing at all.
- **The file being sent is resolved once, not three times.** Reading it asked
  the path what it was, then how big it was, then opened it, so the file that
  was measured was not necessarily the file that was read. It is opened once
  now and everything after that is asked of the descriptor. A symlink is still
  followed — dragging a link to your own file means the file — but it is
  followed once, and the 4 MB cap is enforced on what was actually read as well
  as on what was measured, since a file can grow while it is being sent.
- **A folder, a pipe or a device says so instead of hanging.** Opening first
  and asking afterwards is only safe if the open cannot block, so it is
  non-blocking: a FIFO with nobody writing to it would otherwise have held the
  helper open with the window waiting on it.

### 0.4.2 — 2026-09-02

- **A file in a conversation is now something you can see.** Teams puts nothing
  in the body of a message that carries a file — an `<attachment>` tag, which
  strips to nothing, with the file itself in a field this plugin only ever
  wrote and never read back. So a file sent with no comment arrived as a
  message with nothing in it at all, from either side: sending one worked
  perfectly and looked exactly like it had not. Files now draw as their name,
  linked, and open where anything else opens.
- **A chat whose newest message is a file no longer reads as an empty chat.**
  Graph strips the tag out of the preview it hands back with a chat and puts
  nothing in its place, so the sidebar line was blank. It says "a file or a
  picture" instead, which is as much as can be told without one request per
  chat — and more than a blank line was telling anybody.

### 0.4.1 — 2026-09-02

- **Opening the window finds the one you already have.** Asking for the window
  while it was open somewhere else did nothing you could see: showing a window
  that is already shown is not an instruction to raise it, switch to its
  workspace, or hand it the keyboard, so a click aimed at a Teams window one
  workspace over looked like a click that had been swallowed. It now asks the
  compositor to focus the window it just found, which is the part Qt cannot do
  from inside it.
- **The bar icon no longer hides the window it was asked to open.** Right-click
  summoned rather than opened, and to the shell a window on another workspace
  is simply open — so the first click hid the thing you were reaching for and
  the second brought it back, in front of you this time. Closing the window is
  the window's job, and a keybinding still toggles it.

### 0.4.0 — 2026-09-02

- **A dropdown behind the bar icon**, holding your presence and what is
  unread. Until now the icon only opened the window, on the grounds that a
  conversation wants somewhere that does not close on click-away half way
  through a reply — which is still true of replying, and not true at all of
  the two things people actually ask a bar. Setting your presence is picking
  one row from six. Seeing what is waiting is reading a short list. Both fit a
  popup; neither was worth a window. A row opens the window at that chat, so
  the dropdown is a way in rather than a second, worse client.
- **Right-click the icon** for the window directly, which is where somebody
  who already knows they are about to write a reply wants to be.
- **`ipcTarget`**, so a key can summon the dropdown the way `SUPER+G` summons
  the window. The shell routes `shell toggle` on this plugin id to the window
  and can never reach the dropdown, so the dropdown needs a name of its own.
- The presence circle, the header chip and the picker are now one component
  each rather than three copies of the first two and two of the third. Nothing
  about them changed; there is simply one place left to change them, which is
  what made putting the picker in the dropdown a small job instead of a
  duplicate of it.
- Nothing new is fetched for any of this: the dropdown binds to the Service
  the bar icon was already polling with, so opening it costs no Graph request.

### 0.3.0 — 2026-09-02

- **Your own presence, set from the window.** `p`, or the dot that is now in
  the header: the six states Teams' own status menu offers, and *Automatic* to
  hand presence back to it. Reading everybody else's presence has been here
  since 0.1.0; setting your own is the other half, and it was missing because
  it is the dearer permission — `Presence.ReadWrite` needs an administrator
  where `Presence.Read.All` does not. So it is opt-in, gated on what the tenant
  actually granted, and nothing appears until it is really there.
- **A presence session, so setting one means something.** Graph stores a
  preferred presence but shows `Offline` unless a Teams client is signed in
  somewhere, which on a desktop with no Teams running is every time. **Let
  Teams see you at this machine** makes the plugin one of those clients:
  available while somebody is at the machine, away once nobody is, and let go
  when the shell stops. It claims nothing it cannot know — not in a call, not
  presenting.
- **A refresh no longer asks for less than the sign-in was granted.** The
  hourly token refresh asked for the base scope set, and the granted scopes are
  recorded from whatever comes back — so an account that had signed in for
  `Files.ReadWrite` lost the **Attach** button an hour later, until it was
  signed in again. It now asks for exactly what that sign-in holds.
- `Presence.Read.All` was missing from the permission table in this README,
  which is a scope the plugin has always requested. Anybody whose sign-in
  worked had added it anyway; a registration built strictly from that table
  would have failed at the first sign-in.

### 0.2.0 — 2026-09-01

- **A file dropped on the window is answered, not ignored.** The drop area used
  to switch itself off when the sign-in could not send files, when a channel
  was open rather than a chat, or while another file was going up - so a drop
  did nothing and said nothing about why. It now stays live and the overlay
  names what is in the way while the file is still in the air; letting go
  anyway says the same thing under the composer. A link dragged out of a
  browser is turned away by name.
- **A reaction chip says who reacted.** Under the pointer: the people, what
  Teams calls that reaction, and which of add-or-remove a click would do. Graph
  lists reactions one per person, so the names were already in hand and merely
  being counted and thrown away.

### 0.1.0

- First release.


## License

MIT — see [LICENSE](LICENSE). The only dependency is Python 3 from the standard library; nothing is vendored and nothing is installed with pip.
