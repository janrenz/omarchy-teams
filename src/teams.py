#!/usr/bin/env python3
"""Microsoft Teams for the Omarchy shell: chats, channels, and replying.

Everything that holds a token lives in this file. The QML above it never sees
one - it runs this and reads JSON, the same arrangement the Office 365 mail
plugin uses, and for the same reason: a shell process that renders untrusted
content should not also be the thing holding credentials.

Standard library only.

There is no default client id, unlike the mail plugin. An Azure app
registration declares which delegated permissions it may ask for, so a
registration set up for Mail cannot request Chat.Read - the consent screen
refuses before the user sees it. Teams therefore needs a registration of its
own, and only the person who owns the tenant can make one. See README.md.
"""

import argparse
import json
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

GRAPH = "https://graph.microsoft.com/v1.0"
USER_AGENT = "omarchy-teams-plugin/1.0"

# "common" accepts work/school and personal accounts alike. Teams chats only
# exist on work/school accounts in practice, but the authority is left open so
# a tenant can pin it to their own id.
DEFAULT_AUTHORITY = "common"

# Two tiers, because they are consented very differently.
#
# Chats are ordinary user consent: anyone can grant Chat.Read for their own
# chats. Channels are not - ChannelMessage.Read.All is admin-consent-only in
# most tenants, and a device-code flow asking for it in one breath with the
# chat scopes fails entirely rather than partly. Splitting them means a refused
# channel consent costs the channels, not the whole plugin.
SCOPES_CHATS = "openid profile offline_access User.Read Chat.Read ChatMessage.Send"
SCOPES_CHANNELS = (
    SCOPES_CHATS
    + " Team.ReadBasic.All Channel.ReadBasic.All ChannelMessage.Read.All ChannelMessage.Send"
)

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "omarchy",
    "teams",
)

# A sidebar nobody can read is not worth the requests it costs.
CHAT_CAP = 40
TEAM_CAP = 30
CHANNEL_CAP = 40
MESSAGE_CAP = 50
MAX_RESPONSE_BYTES = 8 * 1024 * 1024


def scopes_for(channels):
    return SCOPES_CHANNELS if channels else SCOPES_CHATS


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------


def out(payload):
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


def fail(code, message, **extra):
    payload = {"ok": False, "error": dict({"code": code, "message": message}, **extra)}
    out(payload)


class AccountError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def alias_problem(alias):
    """Why this alias may not be used as a filename, or None."""
    if not alias:
        return "An account needs a name"
    if not re.match(r"^[A-Za-z0-9._-]{1,64}$", alias) or alias in (".", ".."):
        return "Account names may use letters, numbers, dot, dash and underscore only"
    return None


def state_path(alias, kind="account"):
    problem = alias_problem(alias)
    if problem:
        raise AccountError("bad_alias", problem)
    suffix = "" if kind == "account" else "." + kind
    return os.path.join(STATE_DIR, alias + suffix + ".json")


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    """Write a token file only the user can read.

    The mode is set on the temp file before anything is written into it, so
    there is never a moment where a refresh token sits on disk world-readable.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.chmod(os.path.dirname(path), stat.S_IRWXU)
    tmp = path + ".tmp"
    handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
        json.dump(data, stream)
    os.replace(tmp, path)


def read_capped(response, limit=MAX_RESPONSE_BYTES):
    """Read a response body, refusing one that will not fit in memory twice."""
    body = response.read(limit + 1)
    if len(body) > limit:
        raise AccountError("response_too_large", "The server sent more than this plugin will read")
    return body


def http(url, *, method="GET", data=None, json_body=None, headers=None, timeout=20):
    """Return (status, parsed_json). Non-2xx comes back with its body parsed."""
    body = None
    request_headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        request_headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif json_body is not None:
        body = json.dumps(json_body).encode()
        request_headers["Content-Type"] = "application/json"
    request_headers.update(headers or {})

    request = urllib.request.Request(url, data=body, method=method, headers=request_headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = read_capped(response)
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as error:
        try:
            raw = read_capped(error)
            return error.code, (json.loads(raw) if raw else {})
        except (ValueError, AccountError):
            return error.code, {}
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return 0, {"error": {"message": "Could not reach Microsoft: %s" % error}}


def authority_base(authority):
    return "https://login.microsoftonline.com/%s" % (authority or DEFAULT_AUTHORITY)


def graph_error(payload, fallback):
    if not isinstance(payload, dict):
        return fallback
    error = payload.get("error")
    if isinstance(error, dict):
        return error.get("message") or error.get("code") or fallback
    return payload.get("error_description") or fallback


# --------------------------------------------------------------------------
# tokens
# --------------------------------------------------------------------------


def store_tokens(alias, account, token_response):
    account = dict(account)
    account["refresh_token"] = token_response.get("refresh_token", account.get("refresh_token", ""))
    account["access_token"] = token_response.get("access_token", "")
    account["expires_at"] = time.time() + int(token_response.get("expires_in", 3600)) - 120
    # What the tenant actually granted, which is not what was asked for when an
    # admin withholds the channel scopes. Recording it is what lets the window
    # hide the teams column instead of showing one that 403s on every open.
    granted = token_response.get("scope")
    if granted:
        account["scopes"] = str(granted)
    write_json(state_path(alias), account)
    return account


def has_channels(account):
    """Whether this sign-in may read channel messages.

    Unknown means no. Offering the teams column and failing on every click is
    worse than not offering it, and the plugin says which sign-in would fix it.
    """
    return "channelmessage.read.all" in str((account or {}).get("scopes", "")).lower()


def access_token(alias, account):
    if account.get("access_token") and time.time() < float(account.get("expires_at", 0)):
        return account["access_token"], account

    refresh_token = account.get("refresh_token")
    if not refresh_token:
        raise AccountError("auth_required", "Not signed in")

    status, payload = http(
        authority_base(account.get("authority")) + "/oauth2/v2.0/token",
        method="POST",
        data={
            "client_id": account.get("client_id", ""),
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "scope": scopes_for(has_channels(account)),
        },
    )
    if status != 200 or "access_token" not in payload:
        raise AccountError("auth_required", payload.get("error_description", "Sign in again").split("\r")[0])
    return payload["access_token"], store_tokens(alias, account, payload)


def graph_get(token, path, params=None, extra_headers=None):
    url = GRAPH + path
    if params:
        url += "?" + urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    headers = {"Authorization": "Bearer " + token}
    headers.update(extra_headers or {})
    return http(url, headers=headers)


# --------------------------------------------------------------------------
# sign-in
# --------------------------------------------------------------------------


def cmd_login_start(args):
    client_id = str(args.client_id or "").strip()
    if not client_id:
        fail(
            "client_id_required",
            "Teams needs its own Azure app registration - an app registered for mail cannot "
            "ask for Chat.Read. Create a public-client registration with device-code flow "
            "enabled, add the Graph delegated permissions, and put its client id in this "
            "widget's settings. See the plugin's README.",
        )
    authority = str(args.authority or "").strip() or DEFAULT_AUTHORITY
    status, payload = http(
        authority_base(authority) + "/oauth2/v2.0/devicecode",
        method="POST",
        data={"client_id": client_id, "scope": scopes_for(args.channels)},
    )
    if status != 200 or "device_code" not in payload:
        fail("devicecode_failed",
             payload.get("error_description", "Could not start sign-in").split("\r")[0])

    write_json(
        state_path(args.account, "pending"),
        {
            "device_code": payload["device_code"],
            "client_id": client_id,
            "authority": authority,
            "channels": bool(args.channels),
            "interval": int(payload.get("interval", 5)),
            "expires_at": time.time() + int(payload.get("expires_in", 900)),
        },
    )
    out({
        "ok": True,
        "status": "pending",
        "userCode": payload.get("user_code", ""),
        "verificationUri": payload.get("verification_uri", "https://microsoft.com/devicelogin"),
        "interval": int(payload.get("interval", 5)),
        "expiresIn": int(payload.get("expires_in", 900)),
    })


def cmd_login_poll(args):
    pending_path = state_path(args.account, "pending")
    pending = read_json(pending_path)
    if not pending:
        fail("no_pending_login", "No sign-in in progress")
    if time.time() > pending.get("expires_at", 0):
        os.remove(pending_path)
        fail("expired", "That code expired - start again")

    status, payload = http(
        authority_base(pending.get("authority")) + "/oauth2/v2.0/token",
        method="POST",
        data={
            "client_id": pending.get("client_id", ""),
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": pending.get("device_code", ""),
        },
    )
    if status != 200:
        error = payload.get("error", "")
        if error in ("authorization_pending", "slow_down"):
            out({"ok": True, "status": "pending"})
        os.remove(pending_path)
        message = payload.get("error_description", "Sign-in failed").split("\r")[0]
        # The one failure worth naming, because the way out is different: the
        # channel scopes need an administrator, the chat scopes do not.
        if pending.get("channels") and error in ("invalid_grant", "consent_required", "invalid_client"):
            message += (
                "  Channel access needs an administrator to consent for the tenant. "
                "Turn channels off in settings to sign in for chats alone."
            )
        fail("login_failed", message)

    account = {
        "alias": args.account,
        "client_id": pending.get("client_id", ""),
        "authority": pending.get("authority", DEFAULT_AUTHORITY),
    }
    account = store_tokens(args.account, account, payload)
    os.remove(pending_path)

    status, me = graph_get(account["access_token"], "/me", {"$select": "displayName,userPrincipalName,id"})
    if status == 200:
        account["displayName"] = me.get("displayName", "")
        account["username"] = me.get("userPrincipalName", "")
        account["userId"] = me.get("id", "")
        write_json(state_path(args.account), account)

    out({
        "ok": True,
        "status": "signed-in",
        "username": account.get("username", ""),
        "displayName": account.get("displayName", ""),
        "channels": has_channels(account),
    })


# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------


def plain_text(html):
    """A chat message as one line of text.

    Teams messages are HTML even when someone typed one word. Nothing here
    renders markup, so it comes out as text: the emoji and images become their
    alt text or nothing, and what is left is what was said.
    """
    text = str(html or "")
    text = re.sub(r"<\s*(script|style)\b[^>]*>.*?<\s*/\s*\1\s*>", "", text, flags=re.I | re.S)
    text = re.sub(r"<\s*br\s*/?\s*>", "\n", text, flags=re.I)
    text = re.sub(r"<\s*/\s*(p|div|li)\s*>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = (text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<")
                .replace("&gt;", ">").replace("&quot;", '"').replace("&#39;", "'"))
    text = re.sub(r"[ \t]+\n", "\n", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def chat_title(chat, me_id):
    """What to call a chat in a list.

    A group chat usually has a topic. A one-to-one never does, so it is named
    after the other person - which means dropping yourself from the members,
    or every chat would read as your own name.
    """
    topic = (chat.get("topic") or "").strip()
    if topic:
        return topic
    names = []
    for member in chat.get("members") or []:
        if str(member.get("userId") or "") == str(me_id or ""):
            continue
        name = (member.get("displayName") or "").strip()
        if name:
            names.append(name)
    if not names:
        return "(no one else here)"
    if len(names) <= 3:
        return ", ".join(names)
    return "%s and %d others" % (", ".join(names[:3]), len(names) - 3)


def message_row(message):
    sender = ((message.get("from") or {}).get("user") or {})
    body = (message.get("body") or {})
    return {
        "id": message.get("id", ""),
        "from": sender.get("displayName") or "",
        "fromId": sender.get("id") or "",
        "when": message.get("createdDateTime", ""),
        "text": plain_text(body.get("content")),
        "edited": bool(message.get("lastEditedDateTime")),
        # A system message ("X added Y to the chat") has no sender and reads
        # oddly in a list of things people said.
        "system": message.get("messageType", "message") != "message",
    }


def chat_rows(token, me_id, top):
    """The user's chats, newest first, with an unread mark."""
    status, payload = graph_get(
        token, "/me/chats",
        {"$top": str(min(top, CHAT_CAP)), "$expand": "members,lastMessagePreview"},
    )
    if status != 200:
        return [], graph_error(payload, "Could not read your chats")

    rows = []
    for chat in payload.get("value", []):
        preview = chat.get("lastMessagePreview") or {}
        last_when = str(preview.get("createdDateTime") or "")
        read_when = str(((chat.get("viewpoint") or {}).get("lastMessageReadDateTime")) or "")
        rows.append({
            "id": chat.get("id", ""),
            "kind": "chat",
            "title": chat_title(chat, me_id),
            "chatType": chat.get("chatType", "oneOnOne"),
            "lastFrom": (((preview.get("from") or {}).get("user") or {}).get("displayName") or ""),
            "lastText": plain_text((preview.get("body") or {}).get("content"))[:160],
            "when": last_when,
            # No read timestamp at all means never opened, which is unread.
            "unread": bool(last_when) and (not read_when or read_when < last_when),
        })
    rows.sort(key=lambda row: row["when"], reverse=True)
    return rows, ""


def team_rows(token):
    """Joined teams and their channels, flattened for a sidebar."""
    status, payload = graph_get(token, "/me/joinedTeams", {"$top": str(TEAM_CAP)})
    if status != 200:
        return [], graph_error(payload, "Could not read your teams")

    teams = []
    for team in payload.get("value", [])[:TEAM_CAP]:
        team_id = team.get("id", "")
        channel_status, channel_payload = graph_get(
            token, "/teams/%s/channels" % urllib.parse.quote(team_id, safe=""),
            {"$top": str(CHANNEL_CAP)},
        )
        channels = []
        if channel_status == 200:
            for channel in channel_payload.get("value", [])[:CHANNEL_CAP]:
                channels.append({
                    "id": channel.get("id", ""),
                    "teamId": team_id,
                    "name": channel.get("displayName", ""),
                    "description": (channel.get("description") or "").strip(),
                })
        channels.sort(key=lambda row: row["name"].lower())
        teams.append({
            "id": team_id,
            "name": team.get("displayName", ""),
            "channels": channels,
            # One unreadable team is not worth failing the sidebar over.
            "problem": "" if channel_status == 200 else graph_error(channel_payload, "Could not read its channels"),
        })
    teams.sort(key=lambda row: row["name"].lower())
    return teams, ""


def fetch_account(alias, args):
    account = read_json(state_path(alias))
    if not account:
        raise AccountError("auth_required", "Not signed in")
    token, account = access_token(alias, account)

    result = {
        "ok": True,
        "alias": alias,
        "username": account.get("username", ""),
        "displayName": account.get("displayName", ""),
        "userId": account.get("userId", ""),
        "channels": has_channels(account),
        "chats": [],
        "teams": [],
        "unreadCount": 0,
        "warnings": [],
    }

    chats, chat_error = chat_rows(token, account.get("userId", ""), max(1, min(args.chats, CHAT_CAP)))
    result["chats"] = chats
    result["unreadCount"] = sum(1 for row in chats if row["unread"])
    if chat_error:
        result["warnings"].append({"scope": "chats", "message": chat_error})

    if has_channels(account) and getattr(args, "channels", True):
        teams, team_error = team_rows(token)
        result["teams"] = teams
        if team_error:
            result["warnings"].append({"scope": "teams", "message": team_error})
        for team in teams:
            if team["problem"]:
                result["warnings"].append(
                    {"scope": "teams", "message": "%s: %s" % (team["name"], team["problem"])})

    return result


def cmd_fetch(args):
    aliases = args.account or []
    snapshot = {
        "ok": True,
        "fetchedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "accounts": [],
    }
    if args.demo:
        snapshot["accounts"] = [demo_account(alias) for alias in (aliases or ["demo"])]
        out(snapshot)

    for alias in aliases:
        try:
            snapshot["accounts"].append(fetch_account(alias, args))
        except AccountError as error:
            snapshot["accounts"].append(
                {"ok": False, "alias": alias, "error": {"code": error.code, "message": error.message}})
    out(snapshot)


def cmd_messages(args):
    """One conversation's recent messages, oldest last."""
    if args.demo:
        out(demo_messages(args.chat or args.channel or "demo"))

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    if args.chat:
        path = "/me/chats/%s/messages" % urllib.parse.quote(args.chat, safe="")
    elif args.team and args.channel:
        path = "/teams/%s/channels/%s/messages" % (
            urllib.parse.quote(args.team, safe=""), urllib.parse.quote(args.channel, safe=""))
    else:
        fail("bad_target", "Give either --chat, or --team with --channel")

    status, payload = graph_get(token, path, {"$top": str(max(1, min(args.top, MESSAGE_CAP)))})
    if status == 403:
        fail("permission_required",
             graph_error(payload, "This sign-in may not read that conversation"))
    if status != 200:
        fail("messages_failed", graph_error(payload, "Could not read this conversation"))

    rows = [message_row(message) for message in payload.get("value", [])]
    # Graph returns newest first; a transcript reads the other way.
    rows.reverse()
    out({"ok": True, "messages": rows})


def cmd_send(args):
    text = str(args.text or "").strip()
    if not text:
        fail("empty", "Nothing to send")

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    if args.chat:
        path = "/me/chats/%s/messages" % urllib.parse.quote(args.chat, safe="")
    elif args.team and args.channel:
        path = "/teams/%s/channels/%s/messages" % (
            urllib.parse.quote(args.team, safe=""), urllib.parse.quote(args.channel, safe=""))
    else:
        fail("bad_target", "Give either --chat, or --team with --channel")

    # Sent as text, not HTML: what the user typed is what gets posted, and a
    # stray < in a message should not become markup on everyone else's screen.
    status, payload = http(
        GRAPH + path, method="POST",
        json_body={"body": {"contentType": "text", "content": text}},
        headers={"Authorization": "Bearer " + token},
    )
    if status == 403:
        fail("permission_required",
             graph_error(payload, "This sign-in may not post there. Sign in again to allow it."))
    if status not in (200, 201):
        fail("send_failed", graph_error(payload, "Could not send that message"))
    out({"ok": True, "id": (payload or {}).get("id", "")})


def cmd_list(_args):
    accounts = []
    if os.path.isdir(STATE_DIR):
        for name in sorted(os.listdir(STATE_DIR)):
            if not name.endswith(".json") or name.endswith(".pending.json"):
                continue
            data = read_json(os.path.join(STATE_DIR, name)) or {}
            accounts.append({
                "alias": name[:-5],
                "username": data.get("username", ""),
                "channels": has_channels(data),
            })
    out({"ok": True, "accounts": accounts})


def cmd_remove(args):
    removed = False
    for kind in ("account", "pending"):
        path = state_path(args.account, kind)
        if os.path.exists(path):
            os.remove(path)
            removed = True
    out({"ok": True, "removed": removed})


# --------------------------------------------------------------------------
# demo data, so the layout can be built without anyone signing in
# --------------------------------------------------------------------------

DEMO_CHATS = [
    ("Priya Raman", "oneOnOne", "Priya Raman", "Can you look at the deploy before standup?", True),
    ("Platform team", "group", "Tomás Lindqvist", "Rolling back the 14:02 release.", True),
    ("Dana Okafor", "oneOnOne", "you", "Sent - thanks!", False),
    ("Sprint 24 planning", "group", "Ana Beltrán", "Moved the retro to Thursday.", False),
]


def demo_account(alias):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    chats = []
    for index, (title, kind, who, text, unread) in enumerate(DEMO_CHATS):
        chats.append({
            "id": "demo-chat-%d" % index,
            "kind": "chat",
            "title": title,
            "chatType": kind,
            "lastFrom": who,
            "lastText": text,
            "when": now.isoformat().replace("+00:00", "Z"),
            "unread": unread,
        })
    teams = [{
        "id": "demo-team-0",
        "name": "Engineering",
        "problem": "",
        "channels": [
            {"id": "demo-ch-0", "teamId": "demo-team-0", "name": "General", "description": ""},
            {"id": "demo-ch-1", "teamId": "demo-team-0", "name": "Releases", "description": ""},
        ],
    }]
    return {
        "ok": True, "alias": alias, "username": "%s@example.com" % alias,
        "displayName": alias.capitalize(), "userId": "demo-me", "channels": True,
        "chats": chats, "teams": teams,
        "unreadCount": sum(1 for row in chats if row["unread"]), "warnings": [],
    }


def demo_messages(_target):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    return {"ok": True, "messages": [
        {"id": "d1", "from": "Priya Raman", "fromId": "p", "when": now.isoformat().replace("+00:00", "Z"),
         "text": "Can you look at the deploy before standup?", "edited": False, "system": False},
        {"id": "d2", "from": "You", "fromId": "demo-me", "when": now.isoformat().replace("+00:00", "Z"),
         "text": "Looking now.", "edited": False, "system": False},
    ]}


# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def with_account(name, help_text):
        item = sub.add_parser(name, help=help_text)
        item.add_argument("--account", required=True, help="account alias, e.g. work")
        return item

    start = with_account("login-start", "begin a device-code sign-in")
    start.add_argument("--client-id", default="", help="your Azure app registration's client id")
    start.add_argument("--authority", default="", help="common, organizations, or a tenant id")
    start.add_argument("--channels", action="store_true",
                       help="also ask for team and channel access (needs admin consent)")
    start.set_defaults(func=cmd_login_start)

    with_account("login-poll", "poll a pending sign-in").set_defaults(func=cmd_login_poll)

    fetch = sub.add_parser("fetch", help="chats, and teams when allowed")
    fetch.add_argument("--account", action="append", required=True, help="account alias; repeat for more")
    fetch.add_argument("--chats", type=int, default=25, help="how many chats to list")
    fetch.add_argument("--channels", dest="channels", action="store_true", default=True)
    fetch.add_argument("--no-channels", dest="channels", action="store_false",
                       help="skip teams even when the sign-in allows them")
    fetch.add_argument("--demo", action="store_true", help="synthetic data, for building the layout")
    fetch.set_defaults(func=cmd_fetch)

    messages = with_account("messages", "one conversation's recent messages")
    messages.add_argument("--chat", default="", help="chat id from a fetch")
    messages.add_argument("--team", default="", help="team id, with --channel")
    messages.add_argument("--channel", default="", help="channel id, with --team")
    messages.add_argument("--top", type=int, default=30)
    messages.add_argument("--demo", action="store_true")
    messages.set_defaults(func=cmd_messages)

    send = with_account("send", "post a message to a chat or channel")
    send.add_argument("--chat", default="")
    send.add_argument("--team", default="")
    send.add_argument("--channel", default="")
    send.add_argument("--text", required=True)
    send.set_defaults(func=cmd_send)

    sub.add_parser("list", help="list configured accounts").set_defaults(func=cmd_list)
    with_account("remove", "forget an account").set_defaults(func=cmd_remove)

    args = parser.parse_args()
    try:
        args.func(args)
    except AccountError as error:
        fail(error.code, error.message)


if __name__ == "__main__":
    main()
