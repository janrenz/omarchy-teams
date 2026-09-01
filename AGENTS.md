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
src/BarWidget.qml       The bar icon. Opens the window; there is no dropdown.
src/TeamsWindow.qml     The window. Sidebar, transcript, message box. ~1.7k lines.
src/Notifier.qml        notify-send, with the prime-then-announce rule.
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
   belong there.
2. **The window never fetches anything remote.** Inline images live behind Graph
   and need the token; the helper fetches them, and the host is checked *before*
   the token is attached. Anything not on `graph.microsoft.com` is dropped from
   the message entirely.
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
dev/link.sh                                       # stage the QML for Quickshell
dev/showcase.sh                                   # regenerate the README images
```

`dev/link.sh` assembles a Quickshell config folder in
`$XDG_RUNTIME_DIR/omarchy-teams-dev` and symlinks the sources into it. It has
to: Quickshell only imports modules from inside its own config folder, so
`Commons/` and `Ui/` from `/usr/share/omarchy/shell/` must sit beside a
`shell.qml` — and the repo itself may not contain symlinks (invariant 7).

Note what is missing: this repo has **no offscreen harness**. The Slack plugin's
`dev/stage.sh` + `dev/run.sh` + `dev/shot.sh` trio starts the window under
`QT_QPA_PLATFORM=offscreen` and photographs it without touching your real
shell.json; here the only way to see the window is `dev/showcase.sh`, which
swaps your shell.json for a demo widget and puts it back on the way out
(including on failure or Ctrl-C). Porting that trio over is the single biggest
improvement available to this repo's dev loop.

`--demo` runs through the whole plugin: every read is answered from fixtures in
`teams.py`, every write — sending, starting a chat, marking read — returns as if
it had happened and posts nothing. `demo` and `demoOpen` are settings that exist
only for the showcase.

**Installed-copy edits need a real restart.** `omarchy-shell shell reloadConfig`
and `rescanPlugins` both return ok without re-reading plugin QML or a widget's
entry in `shell.json`. Run `omarchy-restart-shell` and confirm the PID moved
(`pgrep -af 'quickshell -n'`). A surviving PID also proves the QML parsed — a
fatal QML error makes it exit instead.

## Things that will surprise you

- **`Service.qml` is instantiated more than once.** `BarWidget.qml` has one and
  `TeamsWindow.qml` has another, and the bar is one surface *per monitor* — so a
  two-monitor desktop with the window open polls the account three times an
  interval. The mail plugin solved the same problem by moving the data into a
  `kinds: ["service"]` singleton (`Store.qml`); this plugin has not yet.
- **Graph refuses reactions outside 👍 ❤️ 😂 😮 😢 😡** with "Unicode ... is not
  supported". The picker offers exactly what will work rather than letting
  someone pick something that silently fails.
- **Channels have no unread state.** Graph exposes nothing equivalent to a
  chat's read mark, so channels carry no unread mark at all rather than an
  invented number. Teams stay closed until opened because their channels are one
  request per team.
- **Lists are `Repeater`s inside `ScrollView`s**, including the transcript. Every
  row is instantiated. `ListView` with `reuseItems` is the fix if a long
  conversation gets slow — the mail plugin's `MailList.qml` carries a comment on
  exactly this trade-off.
- **The window is a `FloatingWindow`** — a real Hyprland toplevel, tiled like
  anything else. It has no app id of its own, so its `title` is the only handle
  a Hyprland window rule has on it.
- **`omarchy-shell shell summon janrenz.omarchy.teams '<json>'`** delivers that
  JSON to `TeamsWindow.open(payloadJson)`, which currently ignores it. Same for
  `omarchy-shell shell call <id> <method> <arg>`, which routes to any method on
  the loaded window.

## House style

Comments and prose explain **why**, never what — look at the header of
`Service.qml` or `dev/link.sh` for the register. Full sentences. A comment that
restates the line below it does not survive review. The README is written for a
person deciding whether to install this, and says plainly what the plugin does
not do.

Keep the work inside the window. When something cannot be finished here, that is
the bug — not a reason to hand the user off to a browser or the Teams web app.
