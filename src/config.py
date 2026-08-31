#!/usr/bin/env python3
"""Read this plugin's widget entries out of ~/.config/omarchy/shell.json.

The window is one per plugin while the bar widget owns the configuration, so
the window has no settings of its own to be handed - it reads the widget's.
Read-only on purpose: editing is the shell's schema-driven settings form, which
already knows how to write a widget entry safely.
"""

import argparse
import json
import os
import sys

DEFAULT_SHELL_JSON = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "omarchy",
    "shell.json",
)
SECTIONS = ("left", "center", "right")


def out(payload):
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


def fail(code, message):
    out({"ok": False, "error": {"code": code, "message": message}})


def list_widgets(args):
    try:
        with open(args.shell_json, "r", encoding="utf-8") as handle:
            config = json.load(handle)
    except OSError as error:
        fail("no_config", "Could not read %s: %s" % (args.shell_json, error))
    except ValueError as error:
        fail("bad_config", "%s is not valid JSON: %s" % (args.shell_json, error))

    layout = (config.get("bar") or {}).get("layout") or {}
    widgets = []
    for section in SECTIONS:
        entries = layout.get(section) or []
        if not isinstance(entries, list):
            continue
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict) or entry.get("id") != args.plugin_id:
                continue
            widgets.append({
                "section": section,
                "index": index,
                "settings": {k: v for k, v in entry.items() if k != "id"},
            })
    out({"ok": True, "widgets": widgets})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-id", default="janrenz.omarchy.teams")
    parser.add_argument("--list", dest="listing", action="store_true", required=True,
                        help="print this plugin's widget entries")
    parser.add_argument("--shell-json", default=DEFAULT_SHELL_JSON)
    list_widgets(parser.parse_args())


if __name__ == "__main__":
    main()
