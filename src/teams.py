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
import base64
import hashlib
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
# Chat.ReadWrite rather than Chat.Read: marking a chat read is a write, and
# markChatReadForUser refuses anything less. It is still ordinary user consent
# - nobody needs an administrator to let them read their own chats - so this
# costs a re-sign-in and nothing more.
# Chat.Create is listed separately from Chat.ReadWrite because POST /chats
# asks for it by name. People.Read ranks the people you actually talk to;
# User.ReadBasic.All is the fallback for everyone else in the directory. All
# of these are ordinary user consent - no administrator involved - so they
# cost one re-sign-in between them.
SCOPES_CHATS = (
    "openid profile offline_access User.Read Chat.ReadWrite Chat.Create ChatMessage.Send "
    "People.Read User.ReadBasic.All"
)
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


def can_mark_read(account):
    """Whether this sign-in may mark a chat read.

    A mailbox signed in before Chat.ReadWrite was asked for keeps working -
    everything else needs only Chat.Read - so this is checked rather than
    assumed, and opening a chat simply does not mark it read until the user
    signs in again.
    """
    return "chat.readwrite" in str((account or {}).get("scopes", "")).lower()


def can_create_chat(account):
    """Whether this sign-in may start a chat with somebody."""
    scopes = str((account or {}).get("scopes", "")).lower()
    return "chat.create" in scopes or "chat.readwrite" in scopes


def can_find_people(account):
    """Whether this sign-in may look people up to start a chat with."""
    scopes = str((account or {}).get("scopes", "")).lower()
    return "people.read" in scopes or "user.readbasic.all" in scopes


def token_claims(token):
    """The claims inside an access token we were handed.

    Not verified, and not trusted for anything: this is our own token, read
    only for the two ids Graph wants echoed back at it. markChatReadForUser
    wants the user's object id and tenant id, and no Graph call hands those
    over as plainly as the token already does.
    """
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError, TypeError):
        return {}


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
            # Kept so a sign-in can be picked up again. Microsoft hands the
            # user code back once; without it here, closing the window or
            # reloading the plugin between "here is your code" and the user
            # finishing in the browser loses the sign-in silently - the code
            # they are typing stays valid for minutes with nothing left
            # redeeming it.
            "user_code": payload.get("user_code", ""),
            "verification_uri": payload.get("verification_uri", "https://microsoft.com/devicelogin"),
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


def cmd_login_status(args):
    """Whether a sign-in is in flight, and the code it is waiting on.

    What makes resuming possible: the shell can ask this on startup and pick up
    a device-code flow somebody began before the window was closed.
    """
    pending = read_json(state_path(args.account, "pending"))
    if not pending:
        out({"ok": True, "pending": False})
    # A sign-in that finished by some other route leaves this behind. Reporting
    # it as in-flight would put a "still waiting for this code" prompt over an
    # account that is already signed in, so it is cleared instead.
    if read_json(state_path(args.account)):
        try:
            os.remove(state_path(args.account, "pending"))
        except OSError:
            pass
        out({"ok": True, "pending": False, "superseded": True})
    remaining = int(pending.get("expires_at", 0) - time.time())
    if remaining <= 0:
        out({"ok": True, "pending": False, "expired": True})
    out({
        "ok": True,
        "pending": True,
        "userCode": pending.get("user_code", ""),
        "verificationUri": pending.get("verification_uri", "https://microsoft.com/devicelogin"),
        "channels": bool(pending.get("channels")),
        "expiresIn": remaining,
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


# Teams writes an emoji as a tag carrying the real character in its alt:
#   <emoji id="smile" alt="\U0001F642" title="Grinsen"></emoji>
# so the character is already there to be used - no id-to-emoji table to keep,
# and no guessing at ids this tenant's client happens to send.
EMOJI_TAG = re.compile(r'<\s*emoji\b[^>]*?\balt="([^"]*)"[^>]*?>', re.I)
EMOJI_CLOSE = re.compile(r'<\s*/\s*emoji\s*>', re.I)

IMG_TAG = re.compile(r'<\s*img\b([^>]*)>', re.I)
CSS_WIDTH = re.compile(r'width\s*:\s*([0-9.]+)\s*px', re.I)
CSS_HEIGHT = re.compile(r'height\s*:\s*([0-9.]+)\s*px', re.I)

# Inline images live behind the Graph API and need the bearer token to read.
# That token must never be sent anywhere else, and the URL being fetched comes
# out of a message somebody else wrote - so the host is checked rather than
# trusted. A crafted <img src="https://evil/"> would otherwise hand the
# attacker a token with read access to this mailbox.
GRAPH_HOST = "graph.microsoft.com"
IMAGE_CAP = 12 * 1024 * 1024
IMAGE_CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "omarchy", "teams", "images",
)
IMAGE_TYPES = {
    "image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg",
    "image/gif": ".gif", "image/webp": ".webp", "image/bmp": ".bmp",
}


def attr(attrs, name):
    found = re.search(r'\b%s\s*=\s*"([^"]*)"' % name, attrs, re.I)
    return found.group(1) if found else ""


def message_images(html):
    """Inline images in a message body, as {url, alt, width, height}.

    Only Graph-hosted ones. Anything else in an <img> is either a tracking
    pixel or something this plugin has no business fetching.
    """
    images = []
    for match in IMG_TAG.finditer(str(html or "")):
        attrs = match.group(1)
        src = attr(attrs, "src")
        if not src.lower().startswith("https://" + GRAPH_HOST + "/"):
            continue
        style = attr(attrs, "style")
        width = attr(attrs, "width") or (CSS_WIDTH.search(style).group(1) if CSS_WIDTH.search(style) else "")
        height = attr(attrs, "height") or (CSS_HEIGHT.search(style).group(1) if CSS_HEIGHT.search(style) else "")

        def number(value):
            try:
                return int(float(value))
            except (TypeError, ValueError):
                return 0

        images.append({
            "url": src,
            "alt": attr(attrs, "alt") or attr(attrs, "aria-label"),
            "width": number(width),
            "height": number(height),
        })
    return images


def plain_text(html):
    """A chat message as one line of text.

    Teams messages are HTML even when someone typed one word. Nothing here
    renders markup, so it comes out as text: the emoji and images become their
    alt text or nothing, and what is left is what was said.
    """
    text = str(html or "")
    text = EMOJI_TAG.sub(lambda m: m.group(1), text)
    text = EMOJI_CLOSE.sub("", text)
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
        "images": message_images(body.get("content")),
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
    """The teams this user has joined. Names only.

    Not their channels. Channels are one request per team, this account is in
    28 of them, and a sidebar that lists every channel of every team is two
    hundred rows nobody scrolls. They are fetched when a team is opened - see
    cmd_channels - which makes the first paint one request instead of 29.
    """
    status, payload = graph_get(token, "/me/joinedTeams")
    if status != 200:
        return [], graph_error(payload, "Could not read your teams")

    teams = [{
        "id": team.get("id", ""),
        "name": team.get("displayName", ""),
        "description": (team.get("description") or "").strip(),
    } for team in payload.get("value", [])[:TEAM_CAP]]
    teams.sort(key=lambda row: row["name"].lower())
    return teams, ""


def cmd_channels(args):
    """One team's channels, fetched when somebody opens that team."""
    if args.demo:
        out({"ok": True, "teamId": args.team, "channels": [
            {"id": "demo-ch-0", "teamId": args.team, "name": "General", "description": ""},
            {"id": "demo-ch-1", "teamId": args.team, "name": "Releases", "description": ""},
        ]})

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    status, payload = graph_get(
        token, "/teams/%s/channels" % urllib.parse.quote(args.team, safe=""))
    if status == 403:
        fail("permission_required", graph_error(payload, "This sign-in may not read that team"))
    if status != 200:
        fail("channels_failed", graph_error(payload, "Could not read this team's channels"))

    channels = [{
        "id": channel.get("id", ""),
        "teamId": args.team,
        "name": channel.get("displayName", ""),
        "description": (channel.get("description") or "").strip(),
    } for channel in payload.get("value", [])[:CHANNEL_CAP]]
    channels.sort(key=lambda row: row["name"].lower())
    out({"ok": True, "teamId": args.team, "channels": channels})


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
        "canMarkRead": can_mark_read(account),
        "canStartChat": can_create_chat(account) and can_find_people(account),
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

    if has_channels(account) and getattr(args, "teams", True):
        teams, team_error = team_rows(token)
        result["teams"] = teams
        if team_error:
            result["warnings"].append({"scope": "teams", "message": team_error})

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


def fetch_bytes(url, token, limit=IMAGE_CAP):
    """Binary content from Graph, with the token attached only for Graph.

    The URL comes out of a message somebody else wrote, so the host is
    verified rather than trusted: sending an Authorization header to an
    attacker-chosen origin would hand them a token that can read this account.
    """
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname != GRAPH_HOST:
        raise AccountError("bad_image_host",
                           "Refusing to fetch an image from %s" % (parsed.hostname or "nowhere"))

    request = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Authorization": "Bearer " + token,
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read(limit + 1)
            if len(body) > limit:
                raise AccountError("image_too_large", "That image is larger than this plugin will read")
            return body, response.headers.get("Content-Type", "").split(";")[0].strip().lower()
    except urllib.error.HTTPError as error:
        raise AccountError("image_failed", "Could not read that image (HTTP %d)" % error.code)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise AccountError("image_failed", "Could not read that image: %s" % error)


def cmd_image(args):
    """Download one inline image and report where it landed.

    Cached by the URL's digest, because the window asks for the same picture
    every time a conversation is reopened and these run to several megabytes.
    """
    digest = hashlib.sha256(args.url.encode("utf-8")).hexdigest()[:32]
    os.makedirs(IMAGE_CACHE, exist_ok=True)
    for extension in set(IMAGE_TYPES.values()) | {".bin"}:
        cached = os.path.join(IMAGE_CACHE, digest + extension)
        if os.path.exists(cached) and os.path.getsize(cached) > 0:
            out({"ok": True, "path": cached, "cached": True})

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    try:
        token, account = access_token(args.account, account)
        body, content_type = fetch_bytes(args.url, token)
    except AccountError as error:
        fail(error.code, error.message)

    if not content_type.startswith("image/"):
        fail("not_an_image", "That link is %s, not an image" % (content_type or "of unknown type"))

    path = os.path.join(IMAGE_CACHE, digest + IMAGE_TYPES.get(content_type, ".bin"))
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(body)
    os.replace(tmp, path)
    out({"ok": True, "path": path, "cached": False, "bytes": len(body), "contentType": content_type})


def person_row(person, kind):
    """One searchable person, however Graph happened to describe them."""
    address = ""
    for entry in person.get("scoredEmailAddresses") or []:
        address = entry.get("address") or ""
        if address:
            break
    if not address:
        address = person.get("userPrincipalName") or person.get("mail") or ""
    return {
        "id": person.get("id", ""),
        "name": (person.get("displayName") or address or "").strip(),
        "address": address,
        "subtitle": (person.get("jobTitle") or person.get("officeLocation") or "").strip(),
        "source": kind,
    }


def cmd_people(args):
    """People to start a chat with, best guesses first.

    /me/people first: it ranks by who this user actually talks to, which is
    almost always the person being looked for. The directory is the fallback
    for everyone else, and needs the eventual-consistency header to be
    searchable at all.
    """
    if args.demo:
        out({"ok": True, "people": [
            {"id": "demo-p1", "name": "Priya Raman", "address": "priya@example.com",
             "subtitle": "Engineering", "source": "people"},
            {"id": "demo-p2", "name": "Dana Okafor", "address": "dana@example.com",
             "subtitle": "Design", "source": "people"},
        ]})

    query = str(args.query or "").strip()
    if not query:
        fail("empty_query", "Type a name to search for")

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_find_people(account):
        fail("people_permission_required",
             "This sign-in cannot look people up. Sign in again to allow it.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    found = []
    seen = set()

    status, payload = graph_get(token, "/me/people", {"$search": query, "$top": "15"})
    if status == 200:
        for person in payload.get("value", []):
            # Rooms, groups and the like are not people you can open a chat
            # with; only persons have a usable id here.
            if person.get("personType", {}).get("class") not in (None, "Person"):
                continue
            row = person_row(person, "people")
            if row["id"] and row["id"] not in seen:
                seen.add(row["id"])
                found.append(row)

    if len(found) < 5:
        status, payload = graph_get(
            token, "/users",
            {"$search": '"displayName:%s" OR "mail:%s"' % (query, query),
             "$top": "15", "$select": "id,displayName,mail,userPrincipalName,jobTitle"},
            {"ConsistencyLevel": "eventual"},
        )
        if status == 200:
            for person in payload.get("value", []):
                row = person_row(person, "directory")
                if row["id"] and row["id"] not in seen:
                    seen.add(row["id"])
                    found.append(row)

    out({"ok": True, "people": found[:20]})


def cmd_new_chat(args):
    """Start a chat with one person, or a group with several."""
    people = [p for p in (args.user or []) if str(p).strip()]
    if not people:
        fail("no_people", "A chat needs somebody to be with")

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_create_chat(account):
        fail("create_permission_required",
             "This sign-in cannot start chats. Sign in again to allow it.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    claims = token_claims(token)
    me = claims.get("oid") or account.get("userId") or ""
    if not me:
        fail("no_user_id", "Could not tell Graph who is starting the chat")
    if me in people:
        people.remove(me)
    if not people:
        fail("no_people", "A chat needs somebody other than yourself")

    def member(user_id):
        return {
            "@odata.type": "#microsoft.graph.aadUserConversationMember",
            "roles": ["owner"],
            "user@odata.bind": "https://%s/v1.0/users('%s')" % (GRAPH_HOST, user_id),
        }

    # A two-person chat is oneOnOne, which Graph will hand back the existing
    # one for rather than making a second - starting a chat with someone you
    # already talk to should reopen that conversation, not split it in two.
    group = len(people) > 1
    body = {
        "chatType": "group" if group else "oneOnOne",
        "members": [member(me)] + [member(user_id) for user_id in people],
    }
    topic = str(getattr(args, "topic", "") or "").strip()
    if group and topic:
        body["topic"] = topic

    status, payload = http(GRAPH + "/chats", method="POST", json_body=body,
                           headers={"Authorization": "Bearer " + token})
    if status == 403:
        fail("create_permission_required",
             graph_error(payload, "This sign-in cannot start chats. Sign in again to allow it."))
    if status not in (200, 201):
        fail("create_failed", graph_error(payload, "Could not start that chat"))
    out({"ok": True, "id": (payload or {}).get("id", ""), "chatType": (payload or {}).get("chatType", "")})


def cmd_mark_read(args):
    """Mark one chat read, the way opening it in Teams would."""
    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_mark_read(account):
        fail("mark_read_permission_required",
             "This sign-in cannot mark chats read. Sign in again to allow it.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    claims = token_claims(token)
    user_id = claims.get("oid") or account.get("userId") or ""
    tenant_id = claims.get("tid") or ""
    if not user_id:
        fail("no_user_id", "Could not tell Graph which user is reading")

    body = {"user": {"id": user_id}}
    if tenant_id:
        body["user"]["tenantId"] = tenant_id

    status, payload = http(
        GRAPH + "/chats/%s/markChatReadForUser" % urllib.parse.quote(args.chat, safe=""),
        method="POST", json_body=body,
        headers={"Authorization": "Bearer " + token},
    )
    if status == 403:
        fail("mark_read_permission_required",
             graph_error(payload, "This sign-in cannot mark chats read. Sign in again to allow it."))
    if status not in (200, 204):
        fail("mark_read_failed", graph_error(payload, "Could not mark this chat read"))
    out({"ok": True, "chat": args.chat})


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
    teams = [{"id": "demo-team-0", "name": "Engineering", "description": ""},
             {"id": "demo-team-1", "name": "Platform", "description": ""}]
    return {
        "ok": True, "alias": alias, "username": "%s@example.com" % alias,
        "displayName": alias.capitalize(), "userId": "demo-me", "channels": True,
        "canMarkRead": True,
        "canStartChat": True,
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
    with_account("login-status", "report a sign-in left in flight").set_defaults(func=cmd_login_status)

    fetch = sub.add_parser("fetch", help="chats, and teams when allowed")
    fetch.add_argument("--account", action="append", required=True, help="account alias; repeat for more")
    fetch.add_argument("--chats", type=int, default=25, help="how many chats to list")
    fetch.add_argument("--teams", dest="teams", action="store_true", default=True)
    fetch.add_argument("--no-teams", dest="teams", action="store_false",
                       help="skip the team list entirely - what the bar widget wants, since it "
                            "only ever draws an unread chat count")
    fetch.add_argument("--demo", action="store_true", help="synthetic data, for building the layout")
    fetch.set_defaults(func=cmd_fetch)

    messages = with_account("messages", "one conversation's recent messages")
    messages.add_argument("--chat", default="", help="chat id from a fetch")
    messages.add_argument("--team", default="", help="team id, with --channel")
    messages.add_argument("--channel", default="", help="channel id, with --team")
    messages.add_argument("--top", type=int, default=30)
    messages.add_argument("--demo", action="store_true")
    messages.set_defaults(func=cmd_messages)

    channels = with_account("channels", "one team's channels")
    channels.add_argument("--team", required=True, help="team id from a fetch")
    channels.add_argument("--demo", action="store_true")
    channels.set_defaults(func=cmd_channels)

    people = with_account("people", "find somebody to chat with")
    people.add_argument("--query", required=True, help="part of a name or address")
    people.add_argument("--demo", action="store_true")
    people.set_defaults(func=cmd_people)

    new_chat = with_account("new-chat", "start a chat")
    new_chat.add_argument("--user", action="append", required=True,
                          metavar="ID", help="a person's id; repeat for a group chat")
    new_chat.add_argument("--topic", default="", help="a name, for a group chat")
    new_chat.set_defaults(func=cmd_new_chat)

    mark = with_account("mark-read", "mark one chat read")
    mark.add_argument("--chat", required=True, help="chat id from a fetch")
    mark.set_defaults(func=cmd_mark_read)

    image = with_account("image", "download one inline image, and say where it is")
    image.add_argument("--url", required=True, help="a graph.microsoft.com hostedContents URL from a message")
    image.set_defaults(func=cmd_image)

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
