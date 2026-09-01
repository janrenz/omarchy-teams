#!/usr/bin/env bash
# Hand the conversation on screen to whichever coding agent Omarchy is set up
# with (`omarchy default agent`), the same way omarchy-agent-crash hands over a
# core dump.
#
# What crosses over is a pointer, never a transcript: the account alias and the
# ids of the chat or channel, plus the path to the skill that says how to read
# one. The agent then asks teams.py itself. That keeps other people's messages
# out of every `ps` listing on the machine, and it means the agent reads what is
# in the conversation now rather than what happened to be on screen when the key
# was pressed.
#
# Usable by hand and from a Hyprland binding:
#   src/handover.sh --account work --chat '19:…@thread.v2' --print

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

account=""
chat=""
team=""
channel=""
title=""
message=""
task=""
print=false

while (($#)); do
  case "$1" in
    --account) account=${2:?--account needs a value}; shift 2 ;;
    --chat)    chat=${2-}; shift 2 ;;
    --team)    team=${2-}; shift 2 ;;
    --channel) channel=${2-}; shift 2 ;;
    --title)   title=${2-}; shift 2 ;;
    --message) message=${2-}; shift 2 ;;
    --task)    task=${2-}; shift 2 ;;
    --print)   print=true; shift ;;
    *) echo "Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z $account ]] || [[ -z $chat && -z $channel ]]; then
  echo "Usage: handover.sh --account <alias> {--chat <id> | --team <id> --channel <id>} [--title t] [--message id] [--task t] [--print]" >&2
  exit 1
fi

# The window launches this detached, so stderr goes nowhere and a plain `echo`
# would make a keypress that does nothing look like a plugin that is broken.
complain() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a Teams -u critical "Teams" "$1"
  fi
  echo "$1" >&2
}

# The skill is named by absolute path rather than by name. Only some harnesses
# have a skill mechanism at all, and none of them look inside a plugin folder,
# so a path is the one form every agent can follow.
skill="$(cd "$here/.." && pwd)/skills/omarchy-teams/SKILL.md"

: "${task:=Catch me up on this conversation, and if it wants an answer from me, draft one into the window with the draft recipe in the skill. Post nothing.}"

if [[ -n $chat ]]; then
  where="  account alias: $account
  chat:          $chat${title:+  ($title)}"
  read_it="python3 $here/teams.py messages --account $account --chat '$chat' --top 30"
else
  where="  account alias: $account
  team:          $team
  channel:       $channel${title:+  ($title)}"
  read_it="python3 $here/teams.py messages --account $account --team '$team' --channel '$channel' --top 30"
fi
[[ -n $message ]] && where+="
  message:       $message  (the one the keyboard cursor was on)"

prompt=$(
  cat <<PROMPT
I am reading a Microsoft Teams conversation in the Omarchy Teams plugin and want
your help with it.

Which conversation:
$where

Read it with the plugin's own helper. It holds the tokens, prints one JSON object
per call, and is the only thing here that talks to Graph:

  $read_it

Before you do anything else, read this skill: it lists the rest of the helper's
commands, what may and may not be done with them, and how to put a draft reply
back into the window instead of posting it yourself.

  $skill

What I want: $task
PROMPT
)

if [[ $print == "true" ]]; then
  printf '%s\n' "$prompt"
  exit 0
fi

if ! command -v omarchy-agent >/dev/null 2>&1; then
  complain "This Omarchy has no omarchy-agent, so there is nothing to hand this conversation to."
  exit 1
fi

# Omarchy ships without a default agent. Erroring into a void would be a
# keypress that opens nothing and explains nothing, so send them to the picker
# the menu uses - and say why, since the prompt is dropped on that path.
if [[ -z $(omarchy-default-agent) ]]; then
  complain "Choose a coding agent first — then press a again."
  exec omarchy-agent --pick
fi

exec omarchy-agent --prompt "$prompt"
