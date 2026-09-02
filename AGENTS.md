# AGENTS.md

An Omarchy shell plugin: Microsoft Teams chats and channels in the bar and in a
window of their own. Quickshell/QML on top of one Python helper. Read
`README.md` for what it does and how it is set up — this file is about changing
it.

## Orientation, in one pass

```
manifest.json           schemaVersion 1. kinds, entryPoints, and the settings
                        schema the shell's settings panel renders. Adding a
                        setting means adding it here AND reading it through
                        `setting()`.
src/teams.py            The helper. Holds the tokens, makes every Graph call,
                        prints one JSON object per invocation. Stdlib only.
src/Model.js            Pure JS: shaping, grouping, labels, link building. No Qt
                        types, so `node dev/test-model.js` can run it.
src/Service.qml         Owns the Processes that run teams.py, the poll timer,
                        and the state the UI binds to.
src/BarWidget.qml       The bar icon, and the Loader that mounts BarPanel
                        beside it. Left click is the dropdown, right click is
                        the window.
src/BarPanel.qml        The dropdown: your presence, and what is unread. Two
                        things on purpose - see its header for why the rest is
                        not here.
src/PresenceDot.qml     The circle. Four states, one place they are drawn.
src/PresenceChip.qml    The circle plus the word, and the click that opens the
                        picker. In the window's header and the dropdown's.
src/PresenceMenu.qml    The picker itself, numbered. Both surfaces show this
                        one; it is also what knows row 0 is Automatic.
src/TeamsWindow.qml     The window. Sidebar, transcript, message box. ~1.7k lines.
                        Also the file chooser and the window-wide DropArea, which
                        both end at sendFile() - the one place a file:// URL
                        becomes a path.
src/Notifier.qml        omarchy-notification-send, the prime-then-announce rule,
                        and the click that opens the chat.
src/PollGate.qml        Whether it is worth polling at all: idle, network, battery.
src/handover.sh         Builds the prompt that hands a conversation to the
                        user's coding agent and execs omarchy-agent. Runnable by
                        hand; --print shows the prompt and launches nothing.
skills/omarchy-teams/   What that agent is pointed at: the helper's commands, and
                        how to hand a draft back instead of posting it.
src/SettingsForm.qml    The settings UI shown inside the shell's settings panel.
src/ImageViewer.qml     A picture from the transcript, with save-as.
```

Data flows one way: `teams.py` → JSON → `Service.qml` → `Model.js` → the window.
Nothing goes back the other way except a command line and a stdin payload.

## Invariants. Breaking one of these is a security bug, not a regression

1. **The tokens never reach QML.** They live in `~/.local/state/omarchy/teams/`,
   mode 600, and reach `teams.py` on **stdin** — never in argv (anyone on the
   machine can read another process's command line) and never in `shell.json`
   (world-readable). `clientId` and `authority` are the only settings that
   belong there. **What somebody wrote goes the same way**: `send` and `upload`
   read `{"text": …}` / `{"file": …}` on stdin, and the window uses those paths.
   `--text` and `--comment` remain for running the helper by hand.
2. **The window never fetches anything remote, and nothing but Graph is talked
   to in either direction.** Inline images live behind Graph and need the token;
   the helper fetches them, and the host is checked *before* the token is
   attached. Anything not on `graph.microsoft.com` is dropped from the message
   entirely. The same rule is why a file being *sent* is capped at 4 MB: that is
   the limit of a single content PUT to Graph, and the documented route past it
   is an upload session on a `*.sharepoint.com` host. Keeping the one-host rule
   is worth more than the megabytes.
3. **A message never chooses its own markup.** A Teams message is HTML written by
   whoever sent it, and Qt's rich text fetches what it is told to fetch — so
   `teams.py` flattens it, and the only tag the window ever builds is an `<a>`
   around text it escaped itself. Emoji come from the character Teams already
   puts in the tag's `alt`. `http`, `https`, `mailto` only — checked in
   `teams.py`, again in `Model.js` where the anchor is written, and once more in
   `openUrl` before `xdg-open` sees it. Keep all three.
4. **Stdlib only.** No pip, nothing vendored.
5. **Every helper command prints one JSON object** and exits 0 even on failure —
   `{"ok": false, "error": {...}}` — so the window always has something to
   render. Exit non-zero only when the arguments themselves were unusable.
6. **There is no default client id, and there cannot be one.** An Azure app
   registration declares which delegated permissions it may request, so a
   registration made for mail cannot ask for `Chat.Read`. Anything needing a new
   Graph permission needs a README change telling the user what to add to their
   own registration, and a graceful path for when consent is refused — the way
   `channels: false` still leaves chats working.
7. **No symlinks anywhere in this repo.** `omarchy plugin validate` refuses a
   plugin folder that contains one. That is why the dev harness is assembled
   outside the repo — see below.
8. **Colors and spacing come from `qs.Commons`** (`Color`, `Style`, `Border`).
   No hardcoded hex, no hardcoded pixel gaps; use `Style.space()` and the
   density scale so the window follows the theme's font size.

## The dev loop

```bash
node   dev/test-model.js                          # the shaping the window binds to
python3 dev/test-teams.py                         # parsing, permission, host checks
python3 src/teams.py fetch --account work --demo   # synthetic data, no sign-in

dev/run.sh                                        # the real window, offscreen
dev/shot.sh /tmp/teams.png [demo-chat-0]          # photograph what it is drawing
dev/showcase.sh                                   # regenerate the README images
```

A syntax check across the whole repo, which is worth having before a commit and
is not on `$PATH`:

```bash
/usr/lib/qt6/bin/qmlformat src/*.qml >/dev/null   # silence means they all parse
```

A bare `qmlformat` is "command not found", and inside a loop with `|| echo FAIL`
that reads as every file being broken - which is a confusing way to learn that
nothing is wrong. It catches what a running shell does not: a file that parses
but is never imported by the harness.

`dev/link.sh` assembles a Quickshell config folder in
`$XDG_RUNTIME_DIR/omarchy-teams-dev` (`dev/stage.sh` decides where, and refuses
to fall back to shared temp) and symlinks the sources plus `dev/shell.qml` into
it. It has to: Quickshell only imports modules from inside its own config
folder, so `Commons/` and `Ui/` from `/usr/share/omarchy/shell/` must sit beside
a `shell.qml` — and the repo itself may not contain symlinks (invariant 7).

**Those links point back into the repo, so writing to the stage writes to the
repo.** A scratch harness saved as `$STAGE/shell.qml` goes straight through the
symlink and overwrites `dev/shell.qml`. Give a throwaway one any other name.

`dev/run.sh` starts the window under `QT_QPA_PLATFORM=offscreen` and never
touches your `shell.json`, which is what makes it safe to run while you are
using Teams — unlike `dev/showcase.sh`, which swaps your `shell.json` for a demo
widget and puts it back on the way out (including on failure or Ctrl-C).
`dev/shot.sh` asks the harness to photograph itself, because offscreen means
there is no screen to grab. `qs -p $STAGE/shell.qml ipc call dev state` prints
what the service thinks is going on, which is the first thing to ask when the
window comes up empty; `dev open`, `dev spacing`, `dev pane` and `dev account`
are the other knobs.

The harness applies its fixture settings from `onSettingsLoadedChanged`, through
a `Qt.callLater`, and both halves of that matter. The window sets
`settingsLoaded` *before* it assigns the settings it just read from the bar
layout, so fixtures applied inline are overwritten one line later — and a plain
timer racing that read wins most of the time, which is how a harness ends up
quietly showing your real account instead of the fixtures. Both of those were
real, and both looked like something else entirely.

`--demo` runs through the whole plugin: every read is answered from fixtures in
`teams.py`, every write — sending, starting a chat, marking read — returns as if
it had happened and posts nothing. `demo` and `demoOpen` are settings that exist
only for the harness and the showcase.

**Installed-copy edits need a real restart.** `omarchy-shell shell reloadConfig`
and `rescanPlugins` both return ok without re-reading plugin QML or a widget's
entry in `shell.json`. Run `omarchy-restart-shell` and confirm the PID moved
(`pgrep -af 'quickshell -n'`). A surviving PID also proves the QML parsed — a
fatal QML error makes it exit instead.

## Things that will surprise you

- **A toast is a route back in, and it survives a shell restart.** Notifications
  go out through `omarchy-notification-send`, whose `--exec` becomes the
  `omarchy-exec-argv` hint: the click action rides as *data*, so omarchy can
  still run it after the shell that sent it has been restarted, which a live
  libnotify action cannot. Clicking runs `omarchy-shell shell summon <id>
  '<json>'` and the payload lands in the window's `open()`. Two traps: that
  sender has no `--` to end its options, so a headline that is exactly one of
  its flags is guarded with a leading space in `asText()`; and `-r` needs the id
  a previous send printed with `-p`, which is what makes several messages in one
  conversation update one toast instead of stacking.
- **The poll gate's signals arrive late.** For the first second or two of a
  shell's life UPower has no devices, NetworkManager reports `Unknown`
  connectivity and `canCheckConnectivity` is false - measured, on this machine.
  Every default in `PollGate.qml` therefore means "go ahead": a gate that failed
  closed would swallow the first fetch after every shell start, which is the one
  that fills an empty panel.
- **Two surfaces, and only one of them can be summoned by name.** The shell
  decides where `summon`/`toggle`/`hide` go from the manifest's `kinds`, and
  `isBarWidgetPanelPlugin()` returns false for anything that is *also* a panel
  kind. This plugin is both, so `omarchy-shell shell toggle
  janrenz.omarchy.teams` always means the window and can never reach the
  dropdown - the widget's `opened`/`open`/`close` shape is there for the bar's
  own click-away and popout coordination, not for that route. A keybinding onto
  the dropdown therefore needs the panel's own `IpcHandler`, which is what the
  `ipcTarget` setting names. The mail plugin has the same split for the same
  reason.
- **The dropdown fetches nothing.** It binds to the Service the bar icon
  already owns, with `unreadOnly` fixed on that one, so opening it costs no
  Graph request and the filtering is `Model.conversationRows`' existing
  argument rather than a second copy of it. Which is also why the widget's
  Service keeps `includeTeams: false`: a channel has no read state to filter
  on, so the tree would cost a request per team and answer nothing.
- **`Service.qml` is instantiated more than once.** `BarWidget.qml` has one and
  `TeamsWindow.qml` has another, and the bar is one surface *per monitor* — so a
  two-monitor desktop with the window open polls the account three times an
  interval. The mail plugin solved the same problem by moving the data into a
  `kinds: ["service"]` singleton (`Store.qml`); this plugin has not yet.
- **Sending a file is three requests, and Graph has no "post a file".** A file
  lives in a drive and a message points at it, which is what Teams itself does:
  the bytes go to the sender's own OneDrive (into the same "Microsoft Teams Chat
  Files" folder), a sharing link is made, and the chatMessage carries a
  `reference` attachment. Two things bite. The attachment's `id` must be the
  driveItem's eTag GUID - anything else posts a message whose attachment no
  client can resolve, so a missing eTag fails rather than being invented
  around. And the body has to be `html` for `<attachment id=…>` to mean
  anything, which is the one place in this helper where text is *not* sent as
  text - so a comment is escaped there.
- **`Files.ReadWrite` is opt-in for a reason that is not consent.** An app
  registration declares which permissions it may *request*; asking for one it
  does not declare fails the whole sign-in, not just that scope. So the setting
  is the user saying their registration has it, `SCOPES_FILES` is only appended
  when it is on, and `can_upload()` reads the answer back off the granted
  scopes.
- **A presence nobody can see is the normal case.** `setUserPreferredPresence`
  stores what the picker asks for, and Graph then shows `Offline` unless the
  user has a *presence session* - a Teams client signed in somewhere. On a
  desktop with no Teams running, that is every time, so the picker looked
  broken until the plugin could hold a session of its own (`hold-presence`,
  behind the `holdPresence` setting). The session's vocabulary is narrower than
  the picker's on purpose: `setPresence` takes `Busy` only as *InACall* or
  *InAConferenceCall*, and the plugin knows about neither, so it offers
  available and away and nothing else. Graph names the session after the
  application, not the machine, so two machines renew one session - which is
  also why the heartbeat sits behind `notifies`, the same "one of the three
  Services does this" flag the notifications use.
- **`Presence.ReadWrite` is the only opt-in scope whose cost is consent.**
  `Files.ReadWrite` is opt-in because a registration must declare what it
  requests; presence is opt-in for that *and* because an administrator has to
  grant it, where `Presence.Read.All` - reading the whole organisation - needs
  nobody. Do not fold it into `SCOPES_CHATS`: that turns every working
  chats-only sign-in into a refused one.
- **A refresh asks for `scopes_held_by(account)`, not the base set.** The
  refresh response's `scope` is what `store_tokens` records as this sign-in's
  capabilities, and asking for less than was granted gets less back - so an
  account signed in with `Files.ReadWrite` lost the Attach button at its first
  refresh. Anything added as a scope tier has to be read back in that function
  too, or it will fall off an hour after sign-in.
- **Graph refuses reactions outside 👍 ❤️ 😂 😮 😢 😡** with "Unicode ... is not
  supported". The picker offers exactly what will work rather than letting
  someone pick something that silently fails.
- **Channels have no unread state.** Graph exposes nothing equivalent to a
  chat's read mark, so channels carry no unread mark at all rather than an
  invented number. Teams stay closed until opened because their channels are one
  request per team.
- **Lists are `Repeater`s inside `ScrollView`s**, including the transcript. Every
  row is instantiated, and every row is rebuilt whenever the array is replaced.
  That second half is measured, not assumed: a `ListView` over a plain JS array
  recreates *all* of its delegates when the array changes, so `reuseItems` on its
  own buys nothing. Making a long conversation cheap needs a model that diffs,
  and there are two, neither free. `Quickshell.ScriptModel` (`values` plus
  `objectProp: "id"`) diffs for you but exposes only `modelData` — every
  `required property string foo` in the delegate becomes `modelData.foo`, and a
  delegate that outlives its row during a remove transition then reads through a
  null, so the last non-null row has to be kept. Or the mail plugin's way: a
  `ListModel` with the diff written by hand (`MailList.qml`), which keeps the
  role-named delegate properties. Mail chose the second deliberately.
- **The window is a `FloatingWindow`** — a real Hyprland toplevel, tiled like
  anything else. It has no app id of its own, so its `title` is the only handle
  a Hyprland window rule has on it.
- **`omarchy-shell shell summon janrenz.omarchy.teams '<json>'`** delivers that
  JSON to `TeamsWindow.open(payloadJson)`, which hands it to `applyPayload`:
  `chat` - or `team` plus `channel` - and `message` reveal a message (what a
  clicked notification passes), `draft` puts an agent's answer in the message
  box unsent. The shell drains its payload queue in a loop and delivers to a
  window that is already open, so anything added there has to survive arriving
  twice and must not throw away a draft being typed. `omarchy-shell shell call
  <id> <method> <arg>` routes to any method on the loaded window - `agentDraft`
  is the same draft route, and returns what it made of the payload.
- **The coding-agent handover is one setting away from not existing.**
  `agentHandover` gates the `a` key, the button, the help entry and the inbound
  draft. A feature that reaches other people's messages has to be refusable, so
  check the gate rather than assuming it.
- **There is no `cursoredMessage()` here.** The Slack plugin has one; this
  window inlines "the cursor, or the newest if it is nowhere yet" in
  `startPicking` and in `agentArgv`. Copying code across from that repo without
  checking will produce a `ReferenceError` that only shows up in the log.

## House style

Comments and prose explain **why**, never what — look at the header of
`Service.qml` or `dev/link.sh` for the register. Full sentences. A comment that
restates the line below it does not survive review. The README is written for a
person deciding whether to install this, and says plainly what the plugin does
not do.

Keep the work inside the window. When something cannot be finished here, that is
the bug — not a reason to hand the user off to a browser or the Teams web app.
