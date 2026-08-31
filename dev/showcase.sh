#!/usr/bin/env bash
# Generate the showcase images: the real window, on the real shell, showing
# invented people.
#
#   dev/showcase.sh [outdir]        # default: ./
#
# Nothing of yours ends up in an image. The widget this installs carries
# "demo": true, which makes teams.py answer every read out of its own fixtures
# and refuse every write, so the window is drawing invented conversations and
# is not signed in to anything. The real account name, client id and tenant are
# replaced for the duration rather than reused.
#
# Your shell.json is saved first and put back on the way out, including on
# failure or Ctrl-C.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$PWD}"
# The size the window was designed for. Hyprland would otherwise tile it into
# whatever column the current layout leaves, which is a tall strip with half
# the frame empty - fine to use, wrong to put in a README.
SHOT_W="${SHOWCASE_WIDTH:-1080}"
SHOT_H="${SHOWCASE_HEIGHT:-720}"
SHELL_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
PLUGIN_ID="janrenz.omarchy.teams"
WORK="$(mktemp -d)"
BACKUP="$WORK/shell.json.yours"

for tool in grim jq python3 hyprctl omarchy-shell; do
  command -v "$tool" >/dev/null || { echo "showcase: $tool is required" >&2; exit 1; }
done

# One at a time. Two runs at once means the second saves a shell.json that the
# first has already replaced with a demo widget, and whichever restores last
# writes that back as if it were yours.
LOCK="${XDG_RUNTIME_DIR:-/tmp}/omarchy-teams-showcase.lock"
exec 9>"$LOCK"
flock -n 9 || { echo "showcase: another run is in progress" >&2; exit 1; }

# Refuse to start from a config this script left behind, so a backup is never a
# backup of the demo.
if jq -e --arg id "$PLUGIN_ID" '
      [.bar.layout[][]? | select(type == "object" and .id == $id and .demo == true)] | length > 0
    ' "$SHELL_JSON" >/dev/null 2>&1; then
  echo "showcase: $SHELL_JSON still has a demo widget in it - restore it first" >&2
  exit 1
fi

cp "$SHELL_JSON" "$BACKUP"
restore() {
  cp "$BACKUP" "$SHELL_JSON"
  omarchy restart shell >/dev/null 2>&1 || true
  rm -rf "$WORK"
  echo "showcase: your shell.json is back"
}
trap restore EXIT

# Replace every instance of this plugin with one demo widget carrying the
# settings a scenario wants, then wait until the shell answers again.
install_widget() {
  python3 - "$SHELL_JSON" "$PLUGIN_ID" "$1" <<'PY'
import json, sys
path, plugin_id, overrides = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
config = json.load(open(path))
widget = {
    "id": plugin_id,
    "demo": True,
    # The account has to look configured or the service never fetches, and it
    # must not be yours. None of this reaches Graph: demo answers locally.
    "account": "demo",
    "clientId": "00000000-0000-0000-0000-000000000000",
    "authority": "common",
    "channels": True,
    "chats": 25,
    "density": "cosy",
    # Nothing to poll for, and a refresh mid-capture would reshuffle the list.
    "refreshIntervalSec": 3600,
}
widget.update(overrides)
for section, entries in config["bar"]["layout"].items():
    config["bar"]["layout"][section] = [
        e for e in entries if not (isinstance(e, dict) and e.get("id") == plugin_id)
    ]
config["bar"]["layout"]["right"].append(widget)
json.dump(config, open(path, "w"), indent=2)
PY
  omarchy restart shell >/dev/null 2>&1
  for _ in $(seq 1 60); do
    if omarchy-shell shell ping >/dev/null 2>&1; then
      # ping answers as soon as the IPC is up, which is before the plugins
      # have finished loading. Opening the window in that gap gets a window
      # that is torn down a second later.
      sleep 4
      return 0
    fi
    sleep 0.5
  done
  echo "showcase: the shell did not come back" >&2
  return 1
}

# The window is a real toplevel, so Hyprland knows exactly where it is - no
# guessing from the pixels the way a layer-surface panel would need.
window_geometry() {
  hyprctl clients -j | jq -r '
    [.[] | select(.title | test("^Teams($| \u2014)"))] | first
    | if . == null then empty
      else "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])" end'
}

window_address() {
  hyprctl clients -j | jq -r '
    [.[] | select(.title | test("^Teams($| \u2014)"))] | first
    | if . == null then empty else .address end'
}

# Float the window at its designed size and lift it clear of anything on top.
#
# Hyprland here speaks Lua: `hyprctl dispatch setfloating address:...` is the
# old syntax and fails, silently if its error is swallowed. And window.float is
# a toggle rather than a setter, so it is flipped only when the window is
# actually tiled - calling it unconditionally tiles an already-floating window
# and the capture comes out the wrong shape every other run.
stage_window() {
  local address="$1" floating
  floating="$(hyprctl clients -j | jq -r --arg a "$address" '
    .[] | select(.address == $a) | .floating')"
  if [ "$floating" != "true" ]; then
    hyprctl dispatch "hl.dsp.window.float({ window = 'address:$address' })" >/dev/null 2>&1 || true
    sleep 0.5
  fi
  hyprctl dispatch "hl.dsp.window.resize({ x = $SHOT_W, y = $SHOT_H, relative = false, window = 'address:$address' })" >/dev/null 2>&1 || true
  # Omarchy gives most windows a default opacity, and grim photographs the
  # screen rather than the surface - so a translucent window puts whatever is
  # behind it into the image. In a showcase image that is a privacy bug, not a
  # cosmetic one: the first run of this script caught a terminal through it.
  hyprctl dispatch "hl.dsp.window.set_prop({ window = 'address:$address', prop = 'opacity', value = 1 })" >/dev/null 2>&1 || true
  hyprctl dispatch "hl.dsp.window.bring_to_top({ window = 'address:$address' })" >/dev/null 2>&1 || true
  hyprctl dispatch "hl.dsp.window.center({ window = 'address:$address' })" >/dev/null 2>&1 || true
}

# One attempt. Returns non-zero if the window never came up or went away
# again, both of which are worth simply retrying.
capture_once() {
  local name="$1" overrides="$2"
  install_widget "$overrides"

  # hide first so toggle is known to be opening rather than closing.
  omarchy-shell -q shell hide "$PLUGIN_ID" >/dev/null 2>&1 || true
  sleep 1
  omarchy-shell shell toggle "$PLUGIN_ID" >/dev/null 2>&1 || true

  local geometry="" address=""
  for _ in $(seq 1 40); do
    geometry="$(window_geometry || true)"
    [ -n "$geometry" ] && break
    sleep 0.5
  done
  [ -n "$geometry" ] || { echo "showcase: the window never appeared" >&2; return 1; }

  address="$(window_address || true)"
  [ -n "$address" ] && stage_window "$address"

  # Let the fetch land, and the resize finish, before photographing.
  sleep 3

  # Re-read: staging moved and resized it, and opening a conversation renames
  # the window, so the geometry from the wait loop above is already stale.
  local staged=""
  for _ in $(seq 1 10); do
    staged="$(window_geometry || true)"
    [ -n "$staged" ] && break
    sleep 0.5
  done
  # A window that opened and then vanished means the shell was still loading
  # the plugin when it was told to open. Photographing anyway captures the
  # desktop, so this reports failure and lets the caller start over.
  [ -n "$staged" ] || { echo "showcase: the window went away again" >&2; return 1; }
  geometry="$staged"

  mkdir -p "$OUT"
  grim -g "$geometry" "$OUT/$name.png"
  echo "  -> $OUT/$name.png  ($geometry)"

  omarchy-shell -q shell hide "$PLUGIN_ID" >/dev/null 2>&1 || true
  sleep 1
}

capture() {
  echo "showcase: $1"
  local attempt
  for attempt in 1 2 3; do
    if capture_once "$@"; then return 0; fi
    echo "showcase: retrying $1 ($attempt)" >&2
    sleep 3
  done
  echo "showcase: gave up on $1" >&2
  return 1
}

# The conversation list, and one conversation being read. demoOpen is honoured
# only when demo is on, and saves aiming a synthetic click at a row whose
# position depends on the theme's font size.
capture "showcase-conversations" '{}'
capture "showcase-conversation"  '{"demoOpen": "demo-chat-0"}'

# The marketplace looks for preview.png in the repository root and nothing
# else - showcase-*.png is invisible to it - so the card image is kept in step
# with the showcase rather than left to rot at whatever the layout was months
# ago.
cp "$OUT/showcase-conversation.png" "$OUT/preview.png"
echo "  -> $OUT/preview.png  (marketplace card)"

echo "showcase: done"
