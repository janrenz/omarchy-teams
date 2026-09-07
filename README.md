# Microsoft Teams for Omarchy

Teams chats, channels and your calendar in the Omarchy bar, and in a window of their own.

- **A bar icon** that tints when a chat is unread, with a tooltip naming the account and the count.
- **A dropdown behind it**, and deliberately only two things: your presence, and what is unread. Those are the two questions a bar is asked — *how do I look to people* and *does anything need me* — and both are answered by picking from a short list, which is what a popup that closes on click-away can do. Reading a conversation and writing a reply is not, so a row here opens the window at that chat rather than being a smaller copy of it. The one thing it does beyond answering those two is **mark every unread chat read** — `m`, asked twice — because that is the other way of being done with a list of what needs you. Right-click the icon to skip the dropdown and go straight to the window.
- **A window** — a real Hyprland toplevel, tiled like anything else — with conversations on the left, the transcript on the right, and a box to answer in. Bound to `SUPER+G`, also on the Omarchy menu under *Teams*.
- **Chats and channels.** One-to-one chats, group chats, and the channels of every team you have joined.
- **Replying**, to a chat or a channel. `Shift+Enter` or `Ctrl+Enter` sends; plain `Enter` is a newline, because a chat box that sends on Enter posts half-written thoughts.
- **Starting a chat** with anybody in the directory, and **marking a chat read** by opening it.
- **A picture opens in the window**, whole rather than cropped to the thumbnail, with **Save as…** to keep a copy — a real save dialog, starting in your Downloads folder and suggesting a name from what the message called the picture. `s` saves, `o` hands it to whatever else views images, `Escape` closes. It used to go straight to `xdg-open`, which took the one thing anybody opens a picture for somewhere this plugin could not follow.
- **Emoji, inline images and clickable links** in the transcript. Both kinds of link: an address somebody typed out in full, and one behind its own words — the composer's link button writes `<a href="…">the release notes</a>`, and the words are all a reader would otherwise get. They open in your browser, tinted from the running theme rather than in Qt's blue.
- **Presence.** Beside each one-to-one chat: a filled circle for available, a filled circle for busy, a ring for away, a dim circle for offline — in the running theme's own colours. Group chats have none, because a group is not away. Told apart from unread by shape and place, not by hue: presence sits immediately in front of the name because it is about the person, unread is a bar down the leading edge because it is about the conversation, and a chat can show both. Needs `Presence.Read.All` — ordinary user consent.
- **Your own presence, set from here.** `p`, or the dot in the header: Available, Busy, Do not disturb, Be right back, Appear away, Appear offline, and *Automatic* to hand it back to Teams. It is the client's own status menu, written through Graph, and it sticks until you hand it back. This one needs `Presence.ReadWrite`, which an administrator has to consent to — writing your own presence is the dearer permission, not reading everybody's — so it is off until you turn it on. There is a second setting for the part nobody expects: a presence you set only shows while Teams believes you are signed in *somewhere*, so the plugin can be that somewhere. See [Your presence](#your-presence).
- **Where you are working from, set from here too.** `w`, or the word beside the presence chip: *In the office*, *Remote*, *Time off*, **your buildings by name**, and *Automatic* to hand it back. Teams keeps it beside your presence rather than inside it, and so does this: a presence says whether you can be interrupted, a location says where you are, and they are two different writes to Graph. Graph aggregates three layers behind it and says which one won, so the picker can tell "I chose this" from "my working hours say this". Setting a building needs no permission at all: it is a place id, and that is a string as far as Graph is concerned. Only *listing* your tenant's buildings does, so a building you name yourself works on any sign-in. See [Naming a building](#naming-a-building).
- **And it can work it out from the wifi**, which is the one thing the Windows client does that a Linux desktop had no way to. Tell it which SSID is which building — once, from the settings panel, while you are standing in the building — and it reports that to Graph as an *automatic* location whenever this machine is on that network, and withdraws it when you leave. A location you pick by hand still wins, because that is what the layers are for. Teams on Windows reads the same mapping out of the tenant's own Places configuration; no Graph endpoint hands that over, so this keeps your copy of the part that concerns you. See [The wifi can decide](#the-wifi-can-decide).
- **Reactions.** The ones already on a message, counted, with yours marked - click a chip to add or remove yours. The pointer on a chip says who reacted, what Teams calls that reaction, and which of the two a click would do. Reacting is a keyboard job first: `j`/`k` walk the transcript a message at a time, `e` opens the picker on the one under the cursor, and `1`-`6` pick. The mouse can do it too, from the `+` that appears on the message you are pointing at.
- **Your calendar**, in the same window: `c`, or **Calendar** in the header. Day, work week, week and month; a clock face with overlapping meetings side by side and a line across today; whole-day things in a strip of their own; a month grid that runs into the months either side; and an agenda instead when the window is too narrow for columns. Open a meeting for who is coming and what each of them said, **accept, tentative or decline** with a line for the organiser, **book one** with people from the directory in it, or **call one off**. **Join** hands the link to whatever handles Teams meetings here, which is the one thing a QML window cannot do itself. A notification a few minutes before each one. Needs `Calendars.Read`, and `Calendars.ReadWrite` for anything that changes something — both ordinary user consent. See [Your calendar](#your-calendar).
- **Keyboard first.** The whole window drives from the keyboard — see below, or press `?` in the window.

![The conversation list, and a chat open beside it](showcase-conversation.png)

![The conversation list](showcase-conversations.png)

Python 3 standard library only. It talks to Microsoft Graph and nothing else. No token ever reaches the QML: `src/teams.py` holds them, and the shell reads JSON from it.

## Installing

```
omarchy plugin add https://github.com/janrenz/omarchy-teams.git --enable
omarchy bar set janrenz.omarchy.teams account work
```

That is the whole setup. The account name is just a short label for the sign-in; the sign-in itself goes through the plugin's own Azure app registration, so there is nothing to register in a portal first. Reload the shell afterwards and the icon is in the bar — open the window with `SUPER+G` and press **Sign in**.

If your organisation will not consent to an app registered elsewhere, [bring your own registration](#bringing-your-own-app-registration) and the rest works the same.

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

Removing the plugin does not withdraw the consent you gave. That lives in your own tenant: open <https://myapplications.microsoft.com>, find the app, and revoke its permissions there — or ask an administrator, who sees the same grant under *Enterprise applications* in the portal. If you registered an app of your own, it is untouched either way; delete it in the portal if you are done with it.

## Keyboard

Press `?` in the window for this same list. Omarchy is keyboard-first, so the
window is a focus ladder rather than a bag of shortcuts: **list → conversation
→ message box**. `h` and `l` step between the rungs, `Escape` walks back out
one rung at a time, and `j`/`k` always mean "down and up in whatever has
focus".

The dropdown behind the bar icon has its own handful, because it holds its own
few things: `p` opens the presence picker (`0`–`6` pick, `Escape` goes back),
`w` the work location picker (`0`–`3`, then a digit per building), `m` marks
every unread chat read, `o`
opens the window, `r` refreshes, `j`/`k` and `Enter` walk what is unread, and
`Escape` closes it. Either picker closes the other: both take the digits, and
one of them has to own the keyboard.

`m` asks twice. Graph has no route back to unread, so the first press says how
many chats it is about and the second does it — `Escape`, or any other key,
answers no. It is offered only when something is unread and the sign-in may
mark chats read at all, and it is about chats alone: a channel has no unread
mark to clear.

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

### The calendar

| Key | What it does |
|---|---|
| `c` | The calendar, and back to the conversations |
| `j` / `k` | The meeting before / after, in the order they are drawn |
| `h` / `l`, or `[` / `]` | The period before / after |
| `1` – `4` | Day, work week, week, month |
| `v` | The next view along |
| `t` | Back to today |
| `Enter` | Open the meeting under the cursor |
| `J` | Join it |
| `n` | Book a meeting |
| `r` | Read the range again |
| `1` / `2` / `3` | In an open meeting: accept, tentative, decline |
| `x` | In an open meeting: call it off. Asked twice |
| `Escape` | Close the meeting, then the form, then back to the conversations |

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
| `w` | Say where you are working from, or hand that back |
| `r` | Reload the open conversation |
| `,` | Settings |
| `?` | This list |

Opening the window itself is `SUPER+G`, or *Teams* in the Omarchy menu.

## Signing in

Give the widget an account name — a short label such as `work`, which is what the tokens are filed under — open the window with `SUPER+G`, and press **Sign in**. It shows a code and a URL; enter the code there, and the consent screen names the permissions below. That is all of it.

The sign-in goes through this plugin's own app registration, published for accounts in any organizational directory, so the token that comes back belongs to your tenant and never leaves your machine. The client id is in `src/teams.py` in plain sight, which is where a desktop client's client id belongs: it is a public client, it holds no secret, and the device-code flow proves nothing except that the person at the browser is who they say they are. Thunderbird and the Azure CLI publish theirs for the same reason.

Two things your organisation still decides for itself:

- **Whether it will consent to an app registered elsewhere at all.** Some tenants only let users consent to apps their own administrator has approved or that carry a verified publisher. If the sign-in comes back saying an administrator has to approve it, either ask yours to — the app id is `b4221167-67e0-44ba-b111-9f9d31db87f9` — or [register your own](#bringing-your-own-app-registration), which nobody has to approve because it is already theirs.
- **The two admin-consent permissions**, `ChannelMessage.Read.All` and `Presence.ReadWrite`. Those need an administrator whichever registration you sign in with — see [If channels are refused](#if-channels-are-refused). There is a third, `Place.Read.All`, that this registration deliberately does *not* declare — see [Naming a building](#naming-a-building).

## Bringing your own app registration

Optional, and worth it only if your tenant will not consent to the plugin's registration or you would rather the consent screen named one of yours.

An Azure app registration declares up front which delegated permissions it is allowed to request. A registration set up for mail therefore *cannot* ask for `Chat.Read` — the consent screen refuses before you ever see it. So a registration for this plugin has to declare the whole list, and the optional rows have to be there before the settings that ask for them can be turned on.

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
   | `Presence.ReadWrite` | setting your own presence and work location — optional, see below | **admin** |
   | `Calendars.Read` | your calendar — optional, see below | user |
   | `Calendars.ReadWrite` | answering an invitation, booking a meeting, calling one off — optional, see below | user |

   `Chat.ReadWrite` rather than `Chat.Read` on purpose: marking a chat read is
   a write, and `markChatReadForUser` refuses anything less. Everything in that
   list except the channel row is ordinary user consent.

   The last two are the permissions this plugin does not ask for unless you say
   so, and for `Files.ReadWrite` the reason is not consent: a registration
   declares which permissions it may *request*, so asking for one it does not
   list fails the whole sign-in rather than that one scope. Add it here and turn
   on **Send files** in the widget's settings; leave both alone and everything
   else works exactly as before.

   The two calendar permissions are opt-in for the same reason as
   `Files.ReadWrite` and not for consent: both are ordinary user consent — it
   is your own calendar — but a registration declares reading and writing
   separately, so a plugin that asked for the write scope uninvited would fail
   the sign-in of everybody whose registration lists only the read one. Add
   whichever you want and turn on **Calendar**, and **Answer and create
   meetings** for the second. `Calendars.ReadWrite` is sent *in place of*
   `Calendars.Read`, not beside it — it contains it.

   **`Calendars.Read.Shared` is not on this list on purpose.** Calendars other
   people shared with you are drawn without it — see [More than one calendar,
   shared ones included](#more-than-one-calendar-shared-ones-included) — because
   a shared calendar you have added lives in your own mailbox, and reading your
   own mailbox is what `Calendars.Read` is. The `.Shared` scopes are for
   reaching a calendar nobody added, through `/users/{someone}`, and this plugin
   never asks for that. Declaring it does no harm; it just does nothing.

   `Presence.ReadWrite` is opt-in for that reason *and* because of consent. It
   is one of three permissions here that need an administrator — the other two
   being `ChannelMessage.Read.All` and `Place.Read.All` — where reading the
   whole organisation's presence is ordinary user consent and writing your own
   is not. So a sign-in that asks for it without the grant fails outright,
   which is why it waits for **Set your presence and work location** to be
   turned on. Everything else is unaffected either way.

   **`Place.Read.All` is not on this list either, and that is a decision.**
   This registration is multi-tenant: a permission declared on it is a
   permission every other organisation's administrator is asked to consent to,
   and *read every place in the directory* is not a thing to put in front of
   somebody installing a chat widget. `Presence.ReadWrite` is admin consent
   too, but it writes one field of the signed-in user's own presence; this
   reads the whole tenant's estate. So the shared registration does not ask for
   it, and a sign-in that tries is refused before it starts rather than failing
   with an Entra error. Building *names* are a reason to bring a registration
   of your own — see [Naming a building](#naming-a-building) — and nothing else
   in the plugin depends on it.

5. Copy the **Application (client) ID**.
6. In Omarchy, open the Teams widget's settings and put it in **Azure client id**. A single-tenant registration also needs its tenant id in **Authority**; `common` is for multi-tenant ones.
7. Sign in as above. If you were already signed in through the plugin's registration, sign in again — the token is tied to the registration that issued it.

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
| `clientId` | the plugin's own registration | An app registration's Application (client) ID. Empty signs in through the plugin's; fill it in to use one of yours. |
| `authority` | `common` | `common`, `organizations`, or your tenant id. |
| `channels` | `true` | Whether to ask for team and channel access at sign-in. |
| `sendFiles` | `false` | Whether to ask for `Files.ReadWrite` at sign-in, which is what an **Attach** button needs. The plugin's registration declares it; a registration of your own has to as well. |
| `setPresence` | `false` | Whether to ask for `Presence.ReadWrite` at sign-in, which is what `p`, `w` and the two status chips need. An administrator has to consent to it whichever registration you use. |
| `holdPresence` | `false` | Whether to hold a presence session open for this machine, so a presence you set has something to show against. Needs `setPresence`. |
| `readPlaces` | `false` | Whether to ask for `Place.Read.All` at sign-in, which fetches your tenant's buildings so the picker and the rules can name one. Admin consent, and **only on a registration of your own** — the plugin's shared one refuses it. Needs `setPresence` and `clientId`. |
| `buildingNames` | `[]` | One per line, `<place id> = what you call it`. How a building gets a name without `readPlaces`. Name them in the window's settings, which shows the place id Graph already reports for you. |
| `wifiLocations` | `[]` | One rule per line, `ssid = where` — a building's name, a bare place id, `office`, `remote`, `timeoff`, or `none` to report nothing there; `*` as the ssid is any other network. Tick them in the window's settings rather than writing them here. |
| `calendar` | `false` | Whether to ask for `Calendars.Read` at sign-in, which is what the calendar pane needs. |
| `calendarWrite` | `false` | Whether to ask for `Calendars.ReadWrite` instead, which is what answering an invitation, booking a meeting and calling one off need. Needs `calendar`. |
| `calendarIds` | — | Which calendars the pane draws, as Graph's ids — tick them in the window's settings rather than writing them here. Empty means your calendar alone. At most 8 are drawn. Needs no permission beyond `calendar`. |
| `calendarView` | `week` | Which view the calendar opens on: `day`, `work week`, `week`, `month`. |
| `weekStart` | `monday` | Which day a week begins with: `monday` or `sunday`. |
| `meetingReminders` | `true` | A notification a few minutes before each meeting. Needs `calendar` and `notify`. |
| `reminderMinutes` | `5` | How long before a meeting to say so (1–60). |
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

## Quotes and forwards

A message that answers another one shows what it is answering, in a block above
the reply with a bar down its side and the name of whoever wrote it. A forwarded
message shows the same way, labelled with who it came from.

Neither arrives in the message. Teams puts the quoted message in the message's
attachments and leaves an `<attachment id="...">` placeholder in the body where
it belongs — and that placeholder is stripped along with every other tag, so
before this a reply arrived on its own, with the thing being replied to nowhere
on screen. The two are shaped differently: a quote-reply carries a preview Teams
has already flattened, a forward carries the original's own HTML, and that one
goes through the same reader a message body does. Nothing is fetched to draw
either of them — the quote is already in the message that was fetched.

The text is cut to 400 characters. A quote is context for the reply, and past a
few lines it stops being context and becomes something to scroll past to reach
what was actually said.

Graph will also name somebody with an id and no display name at all — seen on a
forwarded message and on the forward inside it at the same time, so the message
had no author and the forward no source. Those ids are looked up in the
directory, all of them in one request and only ever when a name is actually
missing: a conversation where everybody was named costs nothing extra. An id the
directory will not resolve leaves the name out rather than the message.

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

## Where you are working from

The chip beside the presence one, and `w` from either surface. Teams keeps this
next to your presence rather than inside it, and so does this plugin: a
presence says whether you can be interrupted, a work location says where you
are, and Graph writes them with two different calls.

| | |
|---|---|
| `0` | **Automatic** — hand it back to whatever your working hours say |
| `1`–`3` | In the office, Remote, Time off |
| `4`… | Your buildings, by name — with `Place.Read.All`, see below |

Three states, because those are the three `setManualLocation` takes. Graph's
fourth value, `unspecified`, is what it *reports* when nothing has been said
about today — a state to read and never one to send, so the picker does not
offer it and row 0 does the job it would have done.

A building is not a fourth state: it is *In the office* with a `placeId` on it,
which is exactly what the call takes, so row 1 stays for the days you are in
the building and cannot be bothered to say which. Six buildings are numbered,
because a row here is a single digit and four are already spoken for; the rest
are still there in the settings panel.

### Naming a building

A building is a **place id**, and setting one needs no permission whatsoever —
`Presence.ReadWrite` covers it, because an id is a string as far as
`setManualLocation` is concerned. What needs a permission is *listing* the
buildings, and that permission is `Place.Read.All`: admin consent, and a read
of the tenant's entire estate.

**The plugin's shared registration will not ask for it.** It is multi-tenant,
so a permission declared on it is one every other organisation's administrator
is asked to consent to, and that is not a bill to hand other people for a name
in a dropdown. Turning **List your buildings** on with the shared registration
is refused before the sign-in starts, rather than failing with an Entra error
half way through — the setting is disabled in the panel until an **Azure client
id** of your own is filled in.

So there are two ways to have a building, and the first needs nobody:

**Name it yourself.** One line, `<place id> = what you call it`, in **Which
buildings you know**. The name is then usable in the picker and in a wifi
rule. A bare place id works directly in a rule too, with no name and no
setting at all.

Where does the id come from? The settings panel shows it. **If any Teams
client has ever put you in a building — the Windows one does it from the wifi —
Graph hands that id straight back on your own presence**, which this plugin
already reads:

> **Graph puts you in place eb706f15-137e-4722-b4d1-b601481d9251**
> `[ Altbau                    ]`
> Teams has reported this building for you, so the id is right.

Failing that, ask whoever runs Microsoft Places (`Get-Place -Type Building`).

**Or let Graph list them.** [Register your own
app](#bringing-your-own-app-registration), add `Place.Read.All` to it, get your
own administrator's consent — your tenant, your decision, nobody else's
consent screen — put the client id in the widget's settings and turn **List
your buildings** on. The picker then grows a row per building automatically,
with the names the tenant gave them.

That path has one more prerequisite the plugin cannot see around: Places hides
buildings until an administrator has run
`Set-PlacesSettings -EnableBuildings 'Default:true'`, and until then the
endpoint answers `200` with nothing in it. The plugin says which of the two
happened rather than showing an empty list — an unconfigured tenant and a
permission that was never granted look identical from the outside, and only one
of them is anybody's to fix.

Setting one costs no second permission and no second sign-in:
`Presence.ReadWrite` covers both writes, so turning **Set your presence and
work location** on turns both on together. If the presence picker is there,
this one is there. Only *naming a building* asks for anything more.

### Three layers, and which one won

Graph does not keep one work location, it keeps three and aggregates them:
what you chose by hand, what a Teams client noticed, and what your working
hours expect — in that order of precedence. `w` writes the manual layer, which
is why a *Remote* chosen this morning outlives a schedule that expected you in
the building.

And it reports which layer won, which the presence cannot do: the picker ticks
the row that is true and says *from your working hours*, *from your wifi*, or
*noticed by a Teams client* when the answer is not one you gave — the middle
one where the winning report is the one this plugin made itself. **Automatic**
is ticked when no layer has anything to say, so a day nobody has decided about
looks like one.

Handing it back clears the manual layer **and** the automatic one for today —
that is what Graph's `clearLocation` does, not an extra this plugin chose —
leaving the schedule, and nothing at all if the schedule is silent. A tenant
with Microsoft Places switched off has no layers to aggregate, and the chip
then says *work location* rather than inventing a place.

## The wifi can decide

The Windows client sets your work location on its own from the wireless
network, and it can do that because an administrator has listed the office
SSIDs in Places and mapped access points to buildings. **No Graph endpoint
exposes either list** — it is Exchange PowerShell all the way down — so this
plugin cannot read the tenant's mapping and does not pretend to. It keeps your
copy of the part that concerns you instead.

Which is one setting, and best made from the settings panel while you are
sitting in the building:

> **You are on cloudhouse-internet. What is that?**
> ☑ Hauptgebäude · HQ  ☐ Werkstatt Nord  ☐ In the office  ☐ Remote  ☐ Time off
> ☐ Report nothing here

Tick one and that is the rule. Written out, rules look like this, and
`shell.json` is welcome to hold them directly:

```
cloudhouse-internet = Hauptgebäude
gaeste-wlan         = remote
*                   = none
```

The right-hand side is a building's name, its label, a bare place id, or one
of `office`, `remote`, `timeoff`, `none`. `*` is any other network. A place id
is recognised on its shape, so a rule can point at a building on a sign-in
that cannot list any. A *name* nobody answers to — a building renamed in
Places, a typo, a name never declared — is shown as a problem rather than
quietly doing nothing, which is the whole failure mode of a mapping like this.

**It writes the automatic layer, not the manual one.** That is the difference
between a convenience and a nuisance: manual beats automatic, so *Remote*
picked by hand on a Tuesday morning still stands while you sit on the office
wifi, and the plugin's report shows through again the moment you hand the
manual one back. Walking to a network you have said nothing about leaves your
location alone rather than clearing it — tethering to a phone should not
announce anything — and only a rule saying `none` withdraws what this machine
reported.

The network is checked every three minutes, and again when NetworkManager says
connectivity changed, so walking between buildings moves it without waiting for
a tick. The SSID comes from `nmcli`; Quickshell's own networking module reports
whether wifi is on but never which network. And it is let go when the shell
stops, so a laptop shut at the office does not leave this machine claiming to
be there.

Two honest limits, both from the layer being shared. Graph keeps **one**
automatic location per user, not one per device, so two machines running this
plugin on different networks will talk over each other — the last one to
report wins. And the picker says *from your wifi* rather than *noticed by a
Teams client* only when the winning report is the one this plugin made; when
another client got there first it cannot tell you which.

## Your calendar

`c`, or **Calendar** in the header. The same window, the other pane: day, work
week, week and month, on the same account and the same keyboard.

- **Four views**, numbered `1`–`4` and stepped with `[` and `]`. `t` comes back
  to today. Which one it opens on is a setting; switching in the window is for
  that look only, because flipping to Month for one glance is not a preference
  worth writing to `shell.json`.
- **A clock face** for the day, work week and week: a column per day, blocks
  positioned by the minute, meetings that overlap drawn side by side, and a
  line across today at the time it actually is. Whole-day things — leave, a
  conference, an away day — sit in a strip of their own above it, because an
  absence that covers Tuesday is not a meeting from midnight to midnight.
- **A month grid** that runs into the months either side rather than leaving
  the corners blank. Those are real days with real meetings on them, and a grid
  that showed the 1st as empty because the week began in August would be saying
  something untrue. A cell shows as many as it has room for and counts the
  rest.
- **An agenda instead**, when the window is too narrow for columns. A week of
  columns forty pixels wide is a week nobody can read, and this window is as
  often tiled into a third of a screen as it is not.
- **Colour means availability**, not decoration: busy, tentative, free, out of
  office, working elsewhere — in the running theme's own hues. An invitation
  nobody has answered is drawn as an outline, because that is the one state
  with something still to do about it, and anything declined or cancelled is
  drawn faint. A meeting that is happening *now* takes the accent.
- **Open one** with `Enter` or a click: when and where, whether it repeats,
  who organised it, everyone invited and what each of them said, and the
  agenda — flattened out of the HTML the invitation was written in, with its
  links kept and tinted, the same way a chat message is.
- **Answer it.** Accept, tentative, decline — `1`, `2`, `3`, or the buttons —
  with a line for the organiser if you want one, and a switch for Teams' own
  *don't send a response*. Changing your mind later is the same three buttons.
- **Book one.** `n`, **New meeting**, or a double-click on an empty hour, which
  fills the day and the time in from where you clicked. Subject, day, from and
  to or all-day, a room, an agenda, and people from the same directory search
  the new-chat card uses — click a guest to make them optional. **Teams
  meeting** is on by default, which is what puts the join link in the
  invitation.
- **Call one off.** Your own meeting is cancelled and everybody invited is
  told; somebody else's is taken off your calendar and nobody is told. The
  button says which, and asks twice — there is no route back from either.
- **Join** with `J` or the button, and from the block itself without opening
  it — which is what somebody four minutes late wants.
- **A word before it starts.** A notification a few minutes ahead, with a click
  that opens the meeting where the Join button is. Nothing you have declined is
  announced, and neither is anything that was already running when the shell
  started — the same prime-then-announce rule the message notifications follow.

Reading it needs `Calendars.Read` and everything that changes anything needs
`Calendars.ReadWrite`. Both are ordinary user consent — no administrator — but
an app registration declares the two separately, so they are two settings and
two tiers. With only the read one, the calendar is there and the buttons that
would change it are not.

### More than one calendar, shared ones included

A mailbox holds more than the one calendar. There are the user's own extras — a
project calendar, whatever Outlook was pointed at — the holiday and birthday
feeds it subscribes to, and every calendar a colleague shared and you added.
**Calendars to show** in the widget's settings lists all of them, ticked one by
one, and the pane draws what is ticked, merged into the same day columns.

Tick nothing and it draws your calendar alone, which is what it did before
there was a choice — an existing configuration keeps exactly the calendar it
had.

**This needs no new permission.** Graph serves every calendar in a mailbox from
that mailbox, added shared ones included, so `Calendars.Read` reaches all of
them. `Calendars.Read.Shared` is for the other route — `/users/{someone}` —
which reaches a colleague's calendar nobody has added, and nothing here uses
it. If a calendar you want is not in the list, add it in Outlook first and it
will be.

A meeting in somebody else's calendar is **read-only**, whatever your own
sign-in is allowed to do:

- It carries a `` mark on its row and says whose calendar it came from.
- Accept, tentative, decline and *call it off* are not offered. The invitation
  was addressed to the calendar's owner; Graph refuses an answer sent on their
  behalf, and a button that always fails is worse than no button.
- **Join** still works. A link is a link, and being invited is not what makes
  it openable.

Each calendar is a request of its own — Graph has no way to ask several for the
same window — so at most eight are drawn, and the settings form says so if more
are ticked. A calendar that will not answer, because it was unshared or
deleted since it was ticked, is named in the pane and costs only itself: the
rest of the week still draws.

### Joining hands off, and that is deliberate

**Join** opens the meeting's link in whatever handles Teams meetings on this
machine — the desktop client, or a browser. It is the one thing in this plugin
that leaves the window, and it is not a gap waiting to be closed: a meeting is
audio, video and screen sharing, and this is a QML panel over a Python helper.
Everything *around* the meeting — knowing it is coming, what it is about, who
is in it, and whether you are going — is here so that opening the other thing
is the last step rather than the first.

### Times, and why none of them are guessed

Graph answers in UTC. `teams.py` converts every timestamp to this machine's
local time and works out which local day each event belongs to, and the window
groups by that — so no timezone arithmetic happens above the helper at all.
Two places where the obvious reading is wrong, and both are covered by tests:

- **An end is exclusive.** An all-day Friday ends at Saturday midnight, and a
  23:00 call ends on the following date. The last day an event covers is
  computed from the last moment it covers, or both would be drawn on a day they
  are not in.
- **A whole day has to be filed in a named zone.** Midnight UTC is the previous
  evening in half the world, so booking an all-day event sends the date with
  this machine's IANA zone name — read from `TZ` or `/etc/localtime`. A
  timed meeting does not need one and is sent as a UTC instant, worked out with
  the offset that will be in force *on that date*, so a meeting booked across a
  clock change keeps the time it was typed at.

## What it does not do

- **Only the six reactions Teams offers.** 👍 ❤️ 😂 😮 😢 😡. Graph refuses anything else with "Unicode ... is not supported", so the picker offers exactly what will work rather than letting you pick something that silently fails.
- **No unread counts for channels.** Graph will say whether a *chat* has been read since its last message, but exposes nothing equivalent for channels. Rather than invent a number, channels carry no unread mark at all.
- **Teams are closed until opened.** Their channels are one request per team; listing all of them up front cost 29 requests and two hundred rows on an account in 28 teams.
- **No live updates.** It polls on the interval above. Graph change notifications need a public webhook endpoint, which a desktop shell has no business running.
- **A message never chooses its own markup.** A Teams message is HTML written by whoever sent it, and Qt's rich text fetches what it is told to fetch. So the markup is flattened in `teams.py`, and the only tag the window ever builds is an `<a>` around text it escaped first. Emoji come from the character Teams already puts in the tag's `alt`. A link keeps its address, but as an offset into the flattened text rather than as a tag — so what reaches the window is still only words, and the window still builds every tag it draws. Only `http`, `https` and `mailto` become links, checked in `teams.py`, again in `Model.js` where the anchor is written, and once more in `openUrl` before `xdg-open` sees it; anything else stays the plain words it was.
- **Images are fetched by the helper, never by the window.** They live behind the Graph API and need your token; the host is checked before that token is attached, so an `<img src="https://evil/">` in a message cannot be used to collect it. Anything not on `graph.microsoft.com` is dropped from the message entirely.
- **Files go into chats, not channels, and up to 4 MB.** See [Sending a file](#sending-a-file) for why both of those are where they are.
- **Joining opens something else.** A meeting is audio and video; this is a QML panel. Everything around the meeting is here, and the join link goes to whatever handles Teams meetings on this machine. See [Joining hands off](#joining-hands-off-and-that-is-deliberate).
- **A meeting can be booked and called off, but not edited.** Moving one, renaming it, or changing who is invited is a form with a recurrence editor in it, and that is a feature of its own. Cancel and rebook, or use Outlook for that one thing.
- **One calendar: yours.** Not a shared one, not a room's, not a colleague's — and no free/busy lookup of anybody else before booking. What the plugin shows is what `/me/calendarView` answers.
- **A whole-day event is drawn on each day it covers**, not as one bar spanning them. Both say the same thing; the bar is the harder one to lay out beside meetings that begin mid-morning.
- **No reminders inside the window**, and none for what is already running: the notification is the reminder, it comes from the poll rather than from a timer of its own, and what was under way when the shell started is not announced.
- **No search, in a calendar or anywhere else.** Graph has one; this plugin does not use it. Step to the week.
- **No status message.** Teams lets you write a line of text under your presence, and Graph will take one. The six states are what the picker offers; a text field with an expiry and an @-mention picker in it is a different feature, and it is not here yet.
- **A building, but not a floor or a desk.** Places has floors, sections, desks and rooms under a building, and Graph's work location will take any place id. The picker lists buildings alone: a floor is not what anybody means by "where are you working from", and the list would stop being a list. `location --place` passes any id through for anybody who wants one.
- **The plugin's registration will not list your buildings**, on purpose — `Place.Read.All` is admin consent and a tenant-wide read, and this app id is shared. Name a building yourself, or bring your own registration. See [Naming a building](#naming-a-building).
- **The wifi rules are per user, not per tenant.** Teams on Windows reads the office SSIDs and the access-point-to-building mapping out of the tenant's Places configuration; no Graph endpoint exposes either, so this plugin cannot inherit yours and you tell it once instead. See [The wifi can decide](#the-wifi-can-decide).
- **One automatic location per user, not per machine.** Graph keeps a single automatic layer, so two desktops running this plugin on different networks overwrite each other and the last report wins. Nothing to be done about it from here; it is where Graph put the state.
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
| `demoPane` | `calendar` opens the calendar by itself once the fetch says there is one. The calendar's `demoOpen`, and for the same reason: `c` is a keystroke aimed at a window an automated run has not focused. |

`SHOWCASE_WIDTH` and `SHOWCASE_HEIGHT` override the window size it photographs (1080×720 by default).

`preview.png` is a copy of `showcase-conversation.png` under the one name the marketplace looks for in the repository root; the script writes both so the listing card cannot drift from the screenshots in this file.

## Changelog

### 0.10.0 — 2026-09-07

- **Your buildings in the work-location picker**, as rows under *In the
  office* — `4` onwards — and the chip then says *Hauptgebäude* rather than
  *in the office*, which is what everybody else sees anyway. A building is not
  a fourth state: it is the office row with a `placeId` on it, which is exactly
  what `setManualLocation` takes.
- **Setting a building needs no permission at all**, which is the part worth
  being clear about. A place id is a string as far as the presence call is
  concerned. Only *listing* the tenant's buildings needs `Place.Read.All` —
  and **this plugin's shared app registration deliberately does not ask for
  it**: it is admin consent and a read of the whole directory's estate, and
  declaring it on a multi-tenant app puts it in front of every other
  organisation signing in through the same app id. Trying is refused before the
  sign-in starts rather than failing with an Entra error.
- **So a building can be named locally instead**, in **Which buildings you
  know** — one line, `<place id> = what you call it` — and used by name in the
  picker and the wifi rules. A bare place id works in a rule directly, with no
  name and no setting.
- **And the settings panel tells you the id.** If any Teams client has ever put
  you in a building, Graph reports that place id back on your own presence,
  which this plugin already reads — so it is shown, waiting to be named,
  instead of being something to go and look up.
- **Listing them from Graph is still there** for anybody who would rather have
  the tenant's own names: register your own app, add `Place.Read.All`, and turn
  **List your buildings** on. Your tenant, your consent decision. A tenant that
  has not run `Set-PlacesSettings -EnableBuildings` answers `200` with nothing,
  and the plugin says so rather than showing an empty list.
- **It can work the building out from the wifi**, which is the one thing the
  Windows client did that a Linux desktop had no way to. Tell it which SSID
  means which building — from the settings panel, which offers the network you
  are on and the buildings it knows — and it reports that to Graph whenever
  this machine is on that network.
- **On the automatic layer, deliberately.** Manual beats automatic, so a
  location picked by hand still stands while you sit on the office wifi, and
  the wifi's answer shows through again the moment you hand the manual one
  back. A network with no rule leaves your location alone rather than clearing
  it: tethering to a phone should not announce anything. Let go when the shell
  stops, so a laptop shut at the office does not leave this machine claiming to
  be there.
- **The mapping is yours, not the tenant's, and that is not a shortcut.** Teams
  on Windows reads the office SSIDs and the access-point-to-building mapping
  out of Places; both live in Exchange PowerShell and no Graph endpoint exposes
  either, so there is nothing to inherit. The panel says so rather than leaving
  anybody wondering why their tenant's list did not appear.
- A rule pointing at a name nobody answers to — a building renamed in Places —
  is shown as a problem instead of quietly doing nothing, which is the failure
  mode a mapping like this has.
- The SSID comes from `nmcli`: Quickshell's networking module reports whether
  wifi is on but never which network.

### 0.9.0 — 2026-09-07

- **Where you are working from, set from the plugin.** `w`, or the word beside
  the presence chip: *In the office*, *Remote*, *Time off*, and *Automatic* to
  hand it back. Teams has had the control next to your presence for a while and
  Graph had no way to write it; it does now — `setManualLocation` on the
  presence resource — so the picker that already set one of the two can set
  both. No new permission and no re-sign-in: `Presence.ReadWrite` covers both
  writes, which is why this rides on the setting that was already there rather
  than arriving as one of its own.
- **The picker says which layer it is looking at.** Graph keeps three work
  locations and aggregates them — what you chose, what a client noticed, what
  your working hours expect — and unlike a presence it reports which one won.
  So the row it ticks carries *from your working hours* or *noticed by a Teams
  client* when the answer is not one you gave, and **Automatic** is ticked when
  nobody has said anything about today. See
  [Where you are working from](#where-you-are-working-from).
- **`w` and `p` close each other.** Two overlays that both take the digits, in
  both surfaces, and only one of them can own the keyboard.
- The window's header now reads `available · in the office`, two chips with a
  separator between them. Without it the two words ran together into one
  sentence about the presence, which is one thing to click and not two.

### 0.8.0 — 2026-09-06

- **Every calendar in the mailbox, not just the one.** The pane asked Graph for
  `/me/calendarView`, which is the default calendar and nothing else — so a
  project calendar of your own, the holiday feed Outlook subscribes to, and
  every calendar a colleague shared with you were all invisible here, however
  plainly they sit in Outlook. **Calendars to show** in the widget's settings
  now lists what the mailbox actually holds, ticked one by one, and the pane
  merges what is ticked into the same day columns. Tick nothing and it draws
  your calendar alone, exactly as before.

  This needed no new permission and asks for none. A shared calendar you have
  added lives in *your* mailbox, and Graph serves it from there — `Calendars.Read`
  reaches it. The `.Shared` scopes are for reaching a calendar nobody added,
  through `/users/{someone}`, which this plugin does not do.

- **A meeting in somebody else's calendar is read-only, and says so.** It
  carries a mark on its row, names the calendar it came from, and offers no
  Accept, Tentative, Decline or *call it off* — the invitation was addressed to
  the calendar's owner, Graph refuses an answer sent on their behalf, and a
  button that always fails is worse than no button. **Join** still works: a
  link is a link. Which calendar owns a row is decided against the *default
  calendar's* owner rather than the signed-in name, because that name is a user
  principal name and a mailbox whose primary address differs from it would
  otherwise have had every calendar the user owns turn read-only.

- **One stale pick costs only itself.** Each calendar is a request of its own,
  so at most eight are drawn and the settings form says so if more are ticked.
  A calendar that was unshared or deleted since it was ticked is named in the
  pane instead of failing the week around it.

### 0.7.0 — 2026-09-06

- **Signing in no longer starts with an Azure portal.** Until now the plugin
  shipped no client id and refused to do anything without one, so installing it
  meant registering an application first — a step most people cannot take at
  all, because creating app registrations is something plenty of tenants only
  let administrators do. Anyone who could not do it got a widget that said
  *add an account name and client id* and never said anything else. The plugin
  now publishes an app registration of its own, registered for accounts in any
  organizational directory, and an empty `clientId` falls through to it: an
  account name and **Sign in** is the whole setup.

  Nothing about who holds what has changed. The registration only decides which
  permissions the consent screen may *ask* for; the consent, the token and every
  message it fetches belong to your tenant and stay on your machine. The client
  id is in `src/teams.py` in plain sight because a public client's id is not a
  secret — Thunderbird and the Azure CLI publish theirs too.

  `clientId` stays as a setting, and it is still the answer for a tenant that
  will not consent to an application registered somewhere else. What was
  *required* is now *optional*, and the README's registration walkthrough is
  still there for anyone who wants one of their own.

### 0.6.1 — 2026-09-04

- **The key list scrolls.** `?` draws every binding the window has, and since
  the calendar added a section of its own that is more list than a tiled
  window is tall — so the last of it, including the line saying `Esc` closes
  it, was drawn off the bottom edge with no way to reach it. It is now as
  tall as it is until the window is shorter, and then it scrolls: the wheel,
  `j` and `k`, `Page up` and `Page down`, `Ctrl-d` and `Ctrl-u`, `g` and `G`.
  While it is up those keys move the list rather than the conversations
  behind it.

### 0.6.0 — 2026-09-04

- **Your calendar, in the same window.** `c`, or **Calendar** in the header:
  day, work week, week and month, on the account that was already signed in.
  A clock face with a column per day, meetings that overlap drawn side by
  side, whole-day things in a strip of their own, and a line across today at
  the time it actually is; a month grid that runs into the months either side,
  because those are real days with real meetings on them; and an agenda
  instead when the window is too narrow for columns, which is most of the time
  on a tiled desktop.

  Colour says what a meeting does to your day rather than what the theme's
  accent is — busy, tentative, free, out of office — and an invitation nobody
  has answered is an outline, because that is the one state with something
  still to do about it.

- **What a meeting is, and what to do about it.** Open one for when and where,
  whether it repeats, who organised it, everybody invited and what each of them
  said, and the agenda — flattened out of the invitation's HTML with its links
  kept, exactly the way a chat message is, because an invitation is somebody
  else's markup too. Accept, tentative or decline with a line for the
  organiser and a switch for Teams' own *don't send a response*; book one, with
  people from the same directory search the new-chat card uses; call one off,
  which cancels it for everybody if it is yours and quietly removes it if it is
  not. **Join** hands the link to whatever handles Teams meetings on this
  machine — the one thing a QML window genuinely cannot do itself, and the
  README says so rather than pretending otherwise.

- **A word before a meeting starts.** A notification a few minutes ahead,
  clicking through to the meeting where the Join button is. Nothing declined is
  announced, and neither is anything already under way when the shell started —
  the same prime-then-announce rule the message notifications follow. Off with
  one setting, and it only ever costs a request on the Service that already
  does the announcing.

- **Two new permission tiers, both ordinary user consent.** `Calendars.Read`
  for the calendar and `Calendars.ReadWrite` for anything that changes it.
  Separately declared by an app registration, so they are separately opt-in:
  asking for the write scope uninvited would fail the sign-in of everybody
  whose registration lists only the read one. With the read grant alone the
  calendar is there and the buttons that would change it are not, which is the
  same shape as `channels: false` still leaving chats working.

- **Every timestamp is converted once, in the helper.** Graph answers in UTC
  and a calendar is drawn in local days, so `teams.py` does the conversion and
  hands the window the local day each event belongs to — no timezone
  arithmetic above it at all. Two things the obvious reading gets wrong are
  covered by tests: an end is exclusive, so the last day an event covers is
  computed from the last moment it covers rather than from its end; and a
  whole-day event has to be filed in a named zone, because midnight UTC is the
  previous evening in half the world.

### 0.5.0 — 2026-09-02

- **Mark every unread chat read, from the dropdown.** `m`, or the tick beside
  the header's buttons. Being done with a list of what needs you is the other
  half of the question the dropdown exists to answer, and until now the only
  way to answer it was to open all of them.

  It asks twice: Graph has no route back to unread, and in a popup whose every
  other key is a single keystroke, one stray `m` would have cleared a mailbox.
  The first press says how many chats it is about, the second does it, and
  `Escape` — or any other key at all — answers no. `Escape` backs out of the
  question before it backs out of the panel, the same order the presence picker
  uses, and an armed question never survives the panel being closed and opened
  again: coming back to one still holding a question is how the answer gets
  given by accident.

  Offered only when there is something to mark and the sign-in may mark it. A
  mailbox signed in before `Chat.ReadWrite` was asked for cannot, and an offer
  that would fail is worse than no offer. Chats only, because a channel has no
  unread mark to clear — see the note about channel unread counts above.
- **Marks are queued rather than dropped.** Graph wants a request per chat and
  one `Process` cannot run two commands, so a second mark asked for while the
  first was in flight used to be discarded silently — opening two unread chats
  quickly read only one of them. They now go one at a time, the refresh that
  has to follow is spent once at the end rather than after each, and a refusal
  empties the queue instead of asking twenty more times to be told the same
  thing.

### 0.4.7 — 2026-09-02

- **A message whose sender Graph would not name had no author.** It returns
  `displayName: null` and gives the id on its own — on a real forwarded message
  it did it twice at once, so the message showed with no author and the forward
  it carried with no source, which is how "I got this from mike" ended up
  attributed to nobody. The unnamed ids are resolved against the directory now:
  one request for all of them, and none at all when every sender was named, so
  the ordinary conversation costs nothing. A tenant that refuses the lookup, or
  an id it does not know, leaves the name out rather than the message.

### 0.4.6 — 2026-09-02

- **A quoted message is drawn again.** Replying to a message in Teams shows
  what is being replied to; here the reply arrived on its own, and a "Yes" with
  no visible question above it reads as a remark about nothing. The quote was
  never in the body to strip: Teams puts it in the message's attachments and
  leaves an `<attachment id="...">` placeholder in the body, which was stripped
  with every other tag, and the attachment reader was looking for a file to open
  and skipped anything without a URL — which a quote has none of. Quotes and
  forwarded messages are read out of those attachments now and drawn above the
  reply. See [Quotes and forwards](#quotes-and-forwards).

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
