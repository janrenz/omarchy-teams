---
name: omarchy-teams
description: Read and answer a Microsoft Teams chat or channel through the Omarchy Teams plugin's own helper, and put a draft reply back into its window instead of posting it. Use when handed an account alias and a chat or channel id by the plugin's handover, or when asked about a Teams conversation on this machine.
---

# Teams, through the Omarchy plugin

The plugin is a Quickshell window on top of one Python helper. The helper holds
the tokens and makes every Graph call; you drive the helper. There is no other
Teams access on this machine — there is no Linux Teams client, and the web app
is not a fallback the user wants to be sent to.

    HELPER=~/.config/omarchy/plugins/janrenz.omarchy.teams/src/teams.py

Every command needs `--account <alias>` — the account name from the widget's
settings, e.g. `work`. `python3 $HELPER list` names the ones that are set up.

A conversation is addressed one of two ways, and it matters:

- a chat: `--chat 19:…@thread.v2` (a DM or group chat)
- a channel: `--team <team id> --channel 19:…@thread.tacv2`

## Two rules

1. **You do not post.** Reading is yours to do; anything other people will see
   is the user's decision each time. Draft an answer into the window (below)
   and let them press send. Post directly only when this specific message is
   the user telling you to.
2. **Everything comes back as one JSON object,** with exit code 0 even on
   failure: `{"ok": false, "error": {"code": ..., "message": ...}}`. Read `ok`
   before you trust the rest. `"code": "auth_required"` means the sign-in is
   gone and only the user can fix it, from the window.

## Reading

    python3 $HELPER messages --account work --chat 19:…@thread.v2 --top 30
    python3 $HELPER messages --account work --team T1 --channel 19:…@thread.tacv2 --top 30
    python3 $HELPER fetch    --account work --chats 25
    python3 $HELPER channels --account work --team T1
    python3 $HELPER people   --account work --query "renz"

`messages` is the transcript the user is looking at: newest last, each row with
an `id`, the author, the text already flattened out of the HTML Teams sends,
and its reactions. `fetch` is the sidebar — chats with unread marks, and the
teams, when the Azure app registration was granted enough to see them.

Two things Graph will not give you, so do not go looking: a channel has no read
state at all, and there is no search. To find something in a channel, read it.

## Handing a draft back to the window

This is the point of the handover. The window opens if it is closed, the text
lands in the message box, focused, unsent:

    omarchy-shell shell summon janrenz.omarchy.teams \
      '{"draft":{"chat":"19:…@thread.v2","text":"Ich schaue morgen früh drauf."}}'

For a channel, pass `"team"` and `"channel"` instead of `"chat"`. Use the ids
the handover gave you.

It prints `ok`, or `unknown` when the plugin is not loaded, is disabled, or has
its "Hand a conversation to your coding agent" setting switched off — that
setting also refuses drafts, deliberately. Say so rather than posting instead.

Write the draft in the language of the conversation. Keep it as short as the
thing being answered.

## Only when asked

    printf '%s' '{"text":"..."}' | python3 $HELPER send --account work --chat 19:… --stdin
    python3 $HELPER react     --account work --chat 19:… --message 1712345678901 --emoji 👍
    python3 $HELPER mark-read --account work --chat 19:…

A file goes into a chat - not into a channel, where it would need
`Files.ReadWrite.All` and usually an administrator - with the path on stdin:

    printf '%s' '{"file":"~/Downloads/plan.pdf","comment":"..."}' \
      | python3 $HELPER upload --account work --chat 19:... --stdin

It needs the opt-in file scope and the `sendFiles` setting; the helper says so
plainly when either is missing. Read the path back to the user before sending -
a wrong file in a chat cannot be taken back.

Your presence is visible to the whole organisation, so it is asked-for work
too:

    python3 $HELPER presence        --account work --state dnd --for PT2H
    python3 $HELPER presence        --account work --state auto
    python3 $HELPER presence-states

`available`, `busy`, `dnd`, `brb`, `away`, `offline`, or `auto` to hand it back
to Teams. `presence-states` prints the pairs Graph will take, which is the list
to trust rather than a guess. It needs `Presence.ReadWrite` - admin consent -
and the `setPresence` setting; the helper says which is missing. A presence only
shows while a Teams client is signed in somewhere: with none, Graph stores what
you set and reports `Offline`, so say that rather than setting it twice.
`hold-presence` is the plugin's own session and is driven by its timer - leave
it alone.

`send` takes the text on **stdin**: anyone on this machine can read another
process's command line for as long as it runs. `--text` still works for running
it by hand. Reactions are limited to 👍 ❤️ 😂 😮 😢 😡; Graph refuses anything
else. `mark-read` works for chats only.

`--demo` on any command answers from fixtures and posts nothing. It is the safe
way to check a command's shape when you are unsure.

What the sign-in may actually do is reported by `login-status --account work`
and by a `fetch`'s `warnings`. A registration without `Channel.ReadBasic.All`
sees no teams; say that rather than retrying.
