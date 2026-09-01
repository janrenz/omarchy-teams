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
from datetime import datetime, timedelta, timezone

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
    "People.Read User.ReadBasic.All Presence.Read.All"
)
SCOPES_CHANNELS = (
    SCOPES_CHATS
    + " Team.ReadBasic.All Channel.ReadBasic.All ChannelMessage.Read.All ChannelMessage.Send"
)
# Sending a file is a third tier, and opt-in for a reason that is not about
# consent: an app registration declares which permissions it may *request*, so
# asking for one it does not declare fails the whole sign-in rather than that
# one scope. A user whose registration predates this feature must add the
# permission and tick the setting; until then can_upload() reads false off the
# granted scopes and no button appears. Files.ReadWrite is ordinary user
# consent - it is the user's own OneDrive, which is where Teams itself puts the
# files people send in a chat.
SCOPES_FILES = " Files.ReadWrite"

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


def scopes_for(channels, files=False):
    scopes = SCOPES_CHANNELS if channels else SCOPES_CHATS
    return scopes + (SCOPES_FILES if files else "")


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


def http(url, *, method="GET", data=None, json_body=None, raw=None, headers=None, timeout=20):
    """Return (status, parsed_json). Non-2xx comes back with its body parsed.

    `raw` is for the one request that is not JSON in either direction: the
    bytes of a file being uploaded. It still comes back as JSON, because Graph
    answers a content PUT with the driveItem it made.
    """
    body = None
    request_headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        request_headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif raw is not None:
        body = raw
        request_headers["Content-Type"] = "application/octet-stream"
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
        data={"client_id": client_id, "scope": scopes_for(args.channels, args.files)},
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


# A link somebody put in a message. Teams writes one whenever a URL is pasted
# and whenever the composer's link button is used, and in the second case the
# address appears nowhere but the href - "our roadmap" with the URL behind it.
# Stripping the tag threw that away and left words nobody could follow.
ANCHOR_TAG = re.compile(
    r'<\s*a\b([^>]*)>(.*?)<\s*/\s*a\s*>', re.I | re.S)

# Only somewhere to go, never something to run. A javascript:, vbscript: or
# data: href is dropped and its words are left as the words they were.
LINK_SCHEMES = ("http://", "https://", "mailto:")

# Where a link sat, carried through the tag stripping so the offsets that come
# out are offsets into the finished text. These three are C0 controls: Teams
# does not send them, and anything that arrives holding one gets it removed
# before this starts, so a message cannot forge a span of its own.
LINK_OPEN, LINK_SEP, LINK_CLOSE = "\x00", "\x01", "\x02"
LINK_MARKS = re.compile(r"[\x00\x01\x02]")


def link_href(attrs):
    """The address an anchor goes to, or "" if it is not one to follow."""
    href = attr(attrs, "href").strip()
    if not href:
        return ""
    # Written before the entities are decoded, so the ampersands in a query
    # string are still `&amp;` here; decode the few that matter, in the same
    # order plain_text does.
    href = (href.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
                .replace("&quot;", '"').replace("&#39;", "'"))
    lowered = href.lower()
    return href if lowered.startswith(LINK_SCHEMES) else ""


def take_marks(text):
    """The marked-up text split back into plain text and the spans in it."""
    parts = []
    links = []
    at = 0
    seen = 0
    while True:
        start = text.find(LINK_OPEN, at)
        if start == -1:
            break
        sep = text.find(LINK_SEP, start)
        end = text.find(LINK_CLOSE, start)
        if sep == -1 or end == -1 or sep > end:
            # A mark without its partner - drop the mark, keep the words.
            parts.append(text[at:start])
            seen += start - at
            at = start + 1
            continue
        href = text[start + 1:sep]
        label = text[sep + 1:end]
        parts.append(text[at:start])
        seen += start - at
        parts.append(label)
        if label and href:
            links.append({"href": href, "start": seen, "end": seen + len(label)})
        seen += len(label)
        at = end + 1
    parts.append(text[at:])
    return "".join(parts), links


def text_and_links(html):
    """A chat message as text, and where the links in it are.

    Teams messages are HTML even when someone typed one word. Nothing here
    renders markup, so it comes out as text: the emoji and images become their
    alt text or nothing, and what is left is what was said. The links are the
    exception - they are kept, as offsets into that text rather than as tags,
    so the side that draws them builds the only markup there is.
    """
    text = LINK_MARKS.sub("", str(html or ""))
    text = EMOJI_TAG.sub(lambda m: m.group(1), text)
    text = EMOJI_CLOSE.sub("", text)
    text = re.sub(r"<\s*(script|style)\b[^>]*>.*?<\s*/\s*\1\s*>", "", text, flags=re.I | re.S)
    # Marked before the tags come off, so the offsets survive the stripping.
    # The label keeps going through the rest of this - the bold inside a link
    # is stripped like any other tag, its entities decoded like any other text.
    text = ANCHOR_TAG.sub(
        lambda m: (LINK_OPEN + link_href(m.group(1)) + LINK_SEP + m.group(2) + LINK_CLOSE
                   if link_href(m.group(1)) else m.group(2)),
        text)
    text = re.sub(r"<\s*br\s*/?\s*>", "\n", text, flags=re.I)
    text = re.sub(r"<\s*/\s*(p|div|li)\s*>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = (text.replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<")
                .replace("&gt;", ">").replace("&quot;", '"').replace("&#39;", "'"))
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return take_marks(text)


def plain_text(html):
    """A chat message as one line of text, links flattened to their words.

    What a preview, a notification and the bar widget want: no markup, no
    addresses, just what was said.
    """
    return text_and_links(html)[0]


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


def message_row(message, me_id=""):
    sender = ((message.get("from") or {}).get("user") or {})
    body = (message.get("body") or {})
    text, links = text_and_links(body.get("content"))
    return {
        "id": message.get("id", ""),
        "from": sender.get("displayName") or "",
        "fromId": sender.get("id") or "",
        "when": message.get("createdDateTime", ""),
        "text": text,
        # Where the links are, rather than the links themselves: the transcript
        # builds the anchors out of escaped text, so nothing a sender wrote can
        # arrive already being markup.
        "links": links,
        "edited": bool(message.get("lastEditedDateTime")),
        "images": message_images(body.get("content")),
        "reactions": reaction_summary(message, me_id),
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
        # The other person in a one-to-one, which is who a presence dot is
        # about. A group chat has no single "them", so it gets none.
        others = [str(m.get("userId") or "") for m in (chat.get("members") or [])
                  if str(m.get("userId") or "") and str(m.get("userId")) != str(me_id)]
        rows.append({
            "id": chat.get("id", ""),
            "kind": "chat",
            "withUserId": others[0] if len(others) == 1 else "",
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
        "canUpload": can_upload(account),
        "canStartChat": can_create_chat(account) and can_find_people(account),
        "presence": can_see_presence(account),
        "chats": [],
        "teams": [],
        "unreadCount": 0,
        "warnings": [],
    }

    chats, chat_error = chat_rows(token, account.get("userId", ""), max(1, min(args.chats, CHAT_CAP)))
    result["chats"] = chats

    # One batched request for everybody in the list, and only when the sign-in
    # is allowed to ask.
    if can_see_presence(account):
        presences, presence_error = fetch_presences(
            token, [row.get("withUserId") for row in chats])
        for row in chats:
            row["presence"] = presences.get(row.get("withUserId") or "", None)
        if presence_error:
            result["warnings"].append({"scope": "presence", "message": presence_error})
    else:
        for row in chats:
            row["presence"] = None
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

    me_id = token_claims(token).get("oid") or account.get("userId") or ""
    rows = [message_row(message, me_id) for message in payload.get("value", [])]
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


# Graph answers some refusals with an internal code and no sentence. Passing
# that straight to the user tells them nothing they can act on.
GRAPH_PLAIN_ENGLISH = {
    "aclcheckfailed": "Your organisation does not allow starting a chat with that person.",
    "authorization_requestdenied": "This sign-in is not allowed to do that.",
    "unauthenticated": "That sign-in has expired - sign in again.",
    "requestthrottled": "Microsoft is rate-limiting this account; try again shortly.",
}


def friendly(message):
    """Graph's message, or a sentence when all it gave was a code."""
    text = str(message or "").strip()
    known = GRAPH_PLAIN_ENGLISH.get(text.lower())
    if known:
        return known
    for code, sentence in GRAPH_PLAIN_ENGLISH.items():
        if code in text.lower().replace(" ", ""):
            return sentence + "  (" + text + ")"
    return text or "Something went wrong"


# What Teams offers on the reaction bar. reactionType is the character itself,
# not a name - which is also how it comes back on a message, so the same value
# round-trips. Anything outside this set is refused by Graph with "Unicode ...
# is not supported", so the picker offers exactly these.
REACTIONS = [
    ("\U0001F44D", "Like"),
    ("\u2764\uFE0F", "Heart"),
    ("\U0001F602", "Laugh"),
    ("\U0001F62E", "Surprised"),
    ("\U0001F622", "Sad"),
    ("\U0001F621", "Angry"),
]
REACTION_EMOJI = [emoji for emoji, _ in REACTIONS]


def reaction_summary(message, me_id):
    """A message's reactions as one row per emoji.

    Graph lists them one per person; a transcript wants them counted, and
    wants to know whether you are one of the people counted - that is what
    makes the chip a toggle rather than a label.
    """
    counts = {}
    for reaction in message.get("reactions") or []:
        emoji = str(reaction.get("reactionType") or "").strip()
        if not emoji:
            continue
        who = (((reaction.get("user") or {}).get("user") or {}).get("id") or "")
        row = counts.setdefault(emoji, {"emoji": emoji, "count": 0, "mine": False,
                                        "name": reaction.get("displayName") or ""})
        row["count"] += 1
        if me_id and str(who) == str(me_id):
            row["mine"] = True
    # Most-reacted first, then by the character, so the order is stable between
    # fetches rather than shuffling as people react.
    return sorted(counts.values(), key=lambda row: (-row["count"], row["emoji"]))


PALETTE_PATH = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "omarchy", "current", "theme", "colors.toml",
)
PALETTE_NAMES = ("red", "orange", "yellow", "green", "cyan", "blue", "magenta",
                 "accent", "foreground", "muted")


def cmd_palette(_args):
    """The active theme's named colours.

    So a presence dot and a link are tinted in hues that belong to whatever
    theme is running, rather than in hardcoded hex that fights it. The mail
    plugin reads the same file for the same reason.
    """
    try:
        import tomllib

        with open(PALETTE_PATH, "rb") as handle:
            parsed = tomllib.load(handle)
    except (OSError, ValueError, ImportError) as error:
        out({"ok": False, "colors": {}, "error": {"code": "no_palette", "message": str(error)}})

    colors = {name: parsed[name] for name in PALETTE_NAMES
              if isinstance(parsed.get(name), str) and parsed[name].startswith("#")}
    out({"ok": True, "mode": parsed.get("mode", "dark"), "colors": colors})


def can_upload(account):
    """Whether this sign-in may put a file in the user's OneDrive.

    Read back off the granted scopes like every other capability here: a
    registration that gained the permission after the fact starts working at
    the next sign-in without anything being assumed in between.
    """
    return "files.readwrite" in str((account or {}).get("scopes", "")).lower()


def can_see_presence(account):
    """Whether this sign-in may read other people's presence."""
    return "presence.read.all" in str((account or {}).get("scopes", "")).lower()


# Graph's availability values, grouped down to the four states worth drawing.
# The strings are Microsoft's; the grouping is ours, because "AvailableIdle"
# and "Available" are the same dot to a reader.
PRESENCE_STATES = {
    "available": "available", "availableidle": "available",
    "busy": "busy", "busyidle": "busy", "donotdisturb": "busy",
    "away": "away", "berightback": "away",
    "offline": "offline", "presenceunknown": "unknown", "": "unknown",
}


def presence_state(availability):
    return PRESENCE_STATES.get(str(availability or "").lower(), "unknown")


def fetch_presences(token, user_ids):
    """Presence for a batch of people, as {user id: {state, availability, activity}}.

    One request for the lot rather than one each: Graph takes up to 650 ids at
    a time, and a sidebar of twenty-five chats should not cost twenty-five
    round trips.
    """
    ids = [uid for uid in dict.fromkeys(user_ids) if uid]
    if not ids:
        return {}, ""
    status, payload = http(
        GRAPH + "/communications/getPresencesByUserId",
        method="POST", json_body={"ids": ids[:650]},
        headers={"Authorization": "Bearer " + token},
    )
    if status != 200:
        return {}, graph_error(payload, "Could not read presence")

    found = {}
    for row in payload.get("value", []):
        found[str(row.get("id") or "")] = {
            "state": presence_state(row.get("availability")),
            "availability": row.get("availability") or "",
            "activity": row.get("activity") or "",
        }
    return found, ""


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
    problems = []

    status, payload = graph_get(token, "/me/people", {"$search": query, "$top": "15"})
    if status != 200:
        problems.append(graph_error(payload, "Could not search the people you talk to"))
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
        if status != 200:
            problems.append(graph_error(payload, "Could not search the directory"))
        if status == 200:
            for person in payload.get("value", []):
                row = person_row(person, "directory")
                if row["id"] and row["id"] not in seen:
                    seen.add(row["id"])
                    found.append(row)

    # Nothing found because nothing matched is a different thing from nothing
    # found because both searches were refused, and they looked identical.
    if not found and problems:
        fail("people_search_failed", friendly(problems[0]))
    out({"ok": True, "people": found[:20]})


def cmd_new_chat(args):
    """Start a chat with one person, or a group with several."""
    people = [p for p in (args.user or []) if str(p).strip()]
    if not people:
        fail("no_people", "A chat needs somebody to be with")

    # Demo mode answers as if the chat were made. It has to short-circuit here,
    # above the token, because the showcase script drives the window with
    # synthetic keystrokes and a stray Return must never reach a real tenant.
    if args.demo:
        out({"ok": True, "id": "demo-chat-0", "chatType": "oneOnOne"})

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
        fail("create_failed", friendly(graph_error(payload, "Could not start that chat")))
    out({"ok": True, "id": (payload or {}).get("id", ""), "chatType": (payload or {}).get("chatType", "")})


def conversation_path(args):
    """The chat or channel a message lives in.

    /chats and not /me/chats: the reaction endpoints are not published under
    /me at all - that path answers 404 "Requested API is not supported" while
    the same call under /chats works.
    """
    if args.chat:
        return "/chats/%s" % urllib.parse.quote(args.chat, safe="")
    if args.team and args.channel:
        return "/teams/%s/channels/%s" % (urllib.parse.quote(args.team, safe=""),
                                          urllib.parse.quote(args.channel, safe=""))
    fail("bad_target", "Give either --chat, or --team with --channel")


def cmd_react(args):
    """Add or remove one of your reactions on a message."""
    emoji = str(args.emoji or "").strip()
    if emoji not in REACTION_EMOJI:
        fail("bad_reaction", "Teams does not take that as a reaction")

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    verb = "unsetReaction" if args.remove else "setReaction"
    url = "%s%s/messages/%s/%s" % (GRAPH, conversation_path(args),
                                   urllib.parse.quote(args.message, safe=""), verb)
    status, payload = http(url, method="POST", json_body={"reactionType": emoji},
                           headers={"Authorization": "Bearer " + token})
    if status == 403:
        fail("react_permission_required",
             friendly(graph_error(payload, "This sign-in may not react to messages")))
    if status not in (200, 201, 204):
        fail("react_failed", friendly(graph_error(payload, "Could not change that reaction")))
    out({"ok": True, "emoji": emoji, "removed": bool(args.remove)})


def cmd_reactions(_args):
    """The reactions this plugin can send, for the picker."""
    out({"ok": True, "reactions": [{"emoji": e, "name": n} for e, n in REACTIONS]})


def cmd_mark_read(args):
    """Mark one chat read, the way opening it in Teams would."""
    if args.demo:
        out({"ok": True, "chat": args.chat})

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


# --------------------------------------------------------------------------
# sending a file
#
# Graph has no "post a file to a chat". A file lives in a drive and a message
# points at it, which is what Teams itself does: the file goes to the sender's
# OneDrive, into the same "Microsoft Teams Chat Files" folder Teams uses, and
# the message carries a reference attachment to it. So this is three requests -
# upload, share, post - and only the last one puts anything in front of anybody.
#
# A simple content PUT is capped by Graph at 4 MB. Past that the documented
# route is an upload session, whose URL is on a *.sharepoint.com host - and this
# plugin talks to graph.microsoft.com and nothing else, which is the rule that
# keeps a crafted message from being able to send anything anywhere. Keeping
# that rule is worth more than the megabytes, so the cap is the PUT's own limit
# and the refusal says why.
# --------------------------------------------------------------------------

UPLOAD_CAP = 4 * 1024 * 1024
CHAT_FILES_FOLDER = "Microsoft Teams Chat Files"


def read_stdin_json():
    """One JSON object, on one line, from whoever started this.

    The path to send comes in this way rather than as an argument. Anyone on
    this machine can read /proc/<pid>/cmdline; nobody can read another
    process's stdin - and where a file is can be as telling as what is in it.
    """
    try:
        line = sys.stdin.readline()
    except (OSError, ValueError):
        return {}
    try:
        parsed = json.loads(line or "{}")
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def read_upload(path):
    """The bytes to send, or a refusal a person can act on."""
    if not path:
        fail("no_file", "No file to send")
    if not os.path.isfile(path):
        fail("no_file", "There is no file at %s" % path)
    try:
        size = os.path.getsize(path)
    except OSError as error:
        fail("unreadable", "Could not read %s: %s" % (path, error))
    if size == 0:
        fail("empty_file", "That file is empty")
    if size > UPLOAD_CAP:
        fail("too_large",
             "That file is %.1f MB. Graph takes up to %d MB in one request; more than that "
             "needs an upload session on a SharePoint host, and this plugin only ever talks "
             "to graph.microsoft.com." % (size / 1048576.0, UPLOAD_CAP // 1048576))
    try:
        with open(path, "rb") as handle:
            return handle.read(UPLOAD_CAP + 1)
    except OSError as error:
        fail("unreadable", "Could not read %s: %s" % (path, error))


def attachment_guid(item):
    """The id a Teams attachment is keyed by.

    Teams uses the driveItem's eTag, which arrives as '"{GUID},1"'. Anything
    else and the message posts with an attachment nobody's client can resolve,
    so a missing eTag is worth failing on rather than inventing a GUID for.
    """
    etag = str((item or {}).get("eTag") or "")
    start = etag.find("{")
    end = etag.find("}", start + 1)
    if start == -1 or end == -1:
        return ""
    return etag[start + 1:end]


def cmd_upload(args):
    """Send a file into a chat: upload, share, post."""
    path = str(args.file or "")
    comment = str(args.comment or "")
    if args.stdin:
        payload = read_stdin_json()
        path = str(payload.get("file") or path)
        comment = str(payload.get("comment") or comment)
    path = os.path.expanduser(path.strip())
    name = os.path.basename(path)

    if not args.chat:
        # A channel's files live in the team's SharePoint library, not in the
        # sender's OneDrive, and writing there needs Files.ReadWrite.All - a
        # permission most tenants gate behind an administrator. Saying so is
        # better than a 403 from a request nobody expected to make.
        fail("channel_files_unsupported",
             "Files can be sent into a chat, not into a channel: a channel's files live in "
             "the team's SharePoint library, which needs Files.ReadWrite.All and usually an "
             "administrator. Send it in a chat, or share a link in the channel instead.")

    # Every check that does not need the network runs before the demo bail-out,
    # so demo refuses exactly what the real thing refuses. Anything below this
    # line reaches Graph.
    body = read_upload(path)
    if args.demo:
        out({"ok": True, "id": "demo-file", "name": name, "bytes": len(body)})

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_upload(account):
        fail("permission_required",
             "This sign-in cannot send files. Add Files.ReadWrite to your app registration, "
             "turn on \"Send files\" in this widget's settings, and sign in again.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    headers = {"Authorization": "Bearer " + token}

    # conflictBehavior=rename, so sending two screenshots called Screenshot.png
    # does not quietly replace the first one in the user's own drive.
    target = "/me/drive/root:/%s/%s:/content?@microsoft.graph.conflictBehavior=rename" % (
        urllib.parse.quote(CHAT_FILES_FOLDER), urllib.parse.quote(name))
    status, item = http(GRAPH + target, method="PUT", raw=body, headers=headers, timeout=120)
    if status not in (200, 201):
        fail("upload_failed", graph_error(item, "Could not put that file in your OneDrive"))

    item_id = str(item.get("id") or "")
    guid = attachment_guid(item)
    if not item_id or not guid:
        fail("upload_failed", "OneDrive took the file but did not say enough about it to share")

    # A link, so the people in the chat can open it. Organisation scope first
    # because that is what Teams does; a tenant that forbids it gets whatever
    # its default is, and failing that the item's own URL, which at least works
    # for anybody who already has access.
    url = ""
    for wanted in ({"type": "view", "scope": "organization"}, {"type": "view"}):
        status, link = http(
            GRAPH + "/me/drive/items/%s/createLink" % urllib.parse.quote(item_id, safe=""),
            method="POST", json_body=wanted, headers=headers)
        if status in (200, 201):
            url = str((link.get("link") or {}).get("webUrl") or "")
            if url:
                break
    if not url:
        url = str(item.get("webUrl") or "")
    if not url:
        fail("share_failed",
             "The file is in your OneDrive but could not be shared, so nothing was posted")

    # contentType html, because an attachment is referenced by markup - which
    # means a comment has to be escaped here. Text sent as text elsewhere in
    # this helper for exactly the reason it has to be escaped here.
    escaped = comment.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    content = ("%s<br><attachment id=\"%s\"></attachment>" % (escaped, guid)) if escaped \
        else ("<attachment id=\"%s\"></attachment>" % guid)
    status, posted = http(
        GRAPH + "/me/chats/%s/messages" % urllib.parse.quote(args.chat, safe=""),
        method="POST",
        json_body={
            "body": {"contentType": "html", "content": content},
            "attachments": [{
                "id": guid,
                "contentType": "reference",
                "contentUrl": url,
                "name": name,
            }],
        },
        headers=headers)
    if status not in (200, 201):
        # The file is in the user's OneDrive and in no conversation. Say that,
        # rather than "failed" - it is in a different place than before.
        fail("post_failed",
             "That file is in your OneDrive but could not be posted: %s"
             % graph_error(posted, "Teams refused the message"))

    out({"ok": True, "id": str(posted.get("id") or ""), "name": name,
         "bytes": len(body), "url": url})


def cmd_send(args):
    text = str(args.text or "").strip()
    if not text:
        fail("empty", "Nothing to send")

    # The empty check runs first so demo behaves like the real thing, then the
    # message goes nowhere. Anything below this line would post to Graph.
    if args.demo:
        out({"ok": True, "id": "demo-sent"})

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

def iso_z(when):
    """UTC as Graph writes it, so the fixtures parse the same way real data does."""
    return when.isoformat().replace("+00:00", "Z")


DEMO_CHATS = [
    ("Priya Raman", "oneOnOne", "Priya Raman", "Can you look at the deploy before standup?", True, 3),
    ("Platform team", "group", "Tomás Lindqvist", "Rolling back the 14:02 release.", True, 11),
    ("Dana Okafor", "oneOnOne", "you", "Sent - thanks!", False, 47),
    ("Sprint 24 planning", "group", "Ana Beltrán", "Moved the retro to Thursday.", False, 96),
    ("Mikael Sørensen", "oneOnOne", "Mikael Sørensen", "The staging certificate expires on Friday.", False, 210),
    ("Design review", "group", "Yuki Tanaka", "New mockups are in the channel.", False, 1500),
]


def demo_account(alias):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    chats = []
    for index, (title, kind, who, text, unread, ago) in enumerate(DEMO_CHATS):
        # Staggered rather than all "now": a list where every row carries the
        # same timestamp reads as broken, and the showcase images are the first
        # thing anyone sees of this plugin.
        chats.append({
            "id": "demo-chat-%d" % index,
            "kind": "chat",
            "title": title,
            "chatType": kind,
            "lastFrom": who,
            "lastText": text,
            "when": iso_z(now - timedelta(minutes=ago)),
            "unread": unread,
        })
    teams = [{"id": "demo-team-0", "name": "Engineering", "description": ""},
             {"id": "demo-team-1", "name": "Platform", "description": ""}]
    return {
        "ok": True, "alias": alias, "username": "%s@example.com" % alias,
        "displayName": alias.capitalize(), "userId": "demo-me", "channels": True,
        "canMarkRead": True,
        # On in the demo, so the harness and the showcase show the Attach
        # button. A real account gets this from its granted scopes.
        "canUpload": True,
        "canStartChat": True,
        "chats": chats, "teams": teams,
        "unreadCount": sum(1 for row in chats if row["unread"]), "warnings": [],
    }


# The transcripts the demo hands back, keyed by the chat that asked. A showcase
# image of a chat window wants a conversation with some shape to it - turns of
# different lengths, both sides of the thread, one that was edited - which two
# lines of "Looking now." does not have.
DEMO_TRANSCRIPTS = {
    "demo-chat-0": [
        ("Priya Raman", "p1", 34, "Morning! Can you look at the deploy before standup?", False),
        ("Priya Raman", "p1", 33, "The 14:02 build is red on staging but green locally, which is the "
                                  "annoying combination.", False),
        ("You", "demo-me", 21, "Looking now.", False),
        ("You", "demo-me", 12, "Found it - the migration ran twice because the job was queued from "
                               "both the tag and the branch push.", True),
        ("Priya Raman", "p1", 8, "Ah, that would do it.", False),
        ("Priya Raman", "p1", 3, 'Can you put that in '
                                 '<a href="https://example.com/releases/14-02">the release notes</a> '
                                 'so the next person does not spend an hour on it?', False),
    ],
    "demo-chat-1": [
        ("Tomás Lindqvist", "t1", 26, "Rolling back the 14:02 release.", False),
        ("Ana Beltrán", "a1", 24, "Ack. Anything for me to do?", False),
        ("Tomás Lindqvist", "t1", 18, "No - the rollback is clean. I will write it up after standup.", False),
        ("You", "demo-me", 11, "Thanks both.", False),
    ],
}

DEMO_FALLBACK_TRANSCRIPT = [
    ("Yuki Tanaka", "y1", 90, "New mockups are in the channel.", False),
    ("You", "demo-me", 62, "Looks good to me - shipping the spacing change with it.", False),
]


def demo_messages(target):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    turns = DEMO_TRANSCRIPTS.get(str(target or ""), DEMO_FALLBACK_TRANSCRIPT)
    messages = []
    for index, (who, who_id, ago, body, edited) in enumerate(turns):
        # Through the same reader the real thing goes through, so a demo line
        # with a link in it comes out the way a message with one does.
        text, links = text_and_links(body)
        messages.append({
            "id": "d%d" % (index + 1),
            "from": who,
            "fromId": who_id,
            "when": iso_z(now - timedelta(minutes=ago)),
            "text": text,
            "links": links,
            "edited": edited,
            "system": False,
            "images": [],
            # One of them carries a reaction so the chip can be laid out
            # without anybody having to react to anything.
            "reactions": ([{"emoji": "\U0001F44D", "count": 2, "mine": index == 1, "name": "Like"}]
                          if index == 1 else []),
        })
    return {"ok": True, "messages": messages}


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
    start.add_argument("--files", action="store_true",
                       help="also ask for Files.ReadWrite, for sending a file into a chat")
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
    new_chat.add_argument("--demo", action="store_true")
    new_chat.set_defaults(func=cmd_new_chat)

    react = with_account("react", "add or remove your reaction on a message")
    react.add_argument("--message", required=True, help="message id from `messages`")
    react.add_argument("--emoji", required=True, help="one of the reactions Teams takes")
    react.add_argument("--chat", default="")
    react.add_argument("--team", default="")
    react.add_argument("--channel", default="")
    react.add_argument("--remove", action="store_true", help="take yours off instead")
    react.set_defaults(func=cmd_react)

    sub.add_parser("reactions", help="the reactions that can be sent").set_defaults(func=cmd_reactions)

    mark = with_account("mark-read", "mark one chat read")
    mark.add_argument("--chat", required=True, help="chat id from a fetch")
    mark.add_argument("--demo", action="store_true")
    mark.set_defaults(func=cmd_mark_read)

    image = with_account("image", "download one inline image, and say where it is")
    image.add_argument("--url", required=True, help="a graph.microsoft.com hostedContents URL from a message")
    image.set_defaults(func=cmd_image)

    send = with_account("send", "post a message to a chat or channel")
    send.add_argument("--chat", default="")
    send.add_argument("--team", default="")
    send.add_argument("--channel", default="")
    send.add_argument("--text", required=True)
    send.add_argument("--demo", action="store_true")
    send.set_defaults(func=cmd_send)

    upload = with_account("upload", "send a file into a chat")
    upload.add_argument("--chat", default="")
    upload.add_argument("--file", default="", help="path to send; --stdin is what the window uses")
    upload.add_argument("--comment", default="", help="a message to go with it")
    upload.add_argument("--stdin", action="store_true",
                        help='read {"file": "...", "comment": "..."} from stdin')
    upload.add_argument("--demo", action="store_true")
    upload.set_defaults(func=cmd_upload)

    sub.add_parser("palette", help="the active theme's named colours").set_defaults(func=cmd_palette)

    sub.add_parser("list", help="list configured accounts").set_defaults(func=cmd_list)
    with_account("remove", "forget an account").set_defaults(func=cmd_remove)

    args = parser.parse_args()
    try:
        args.func(args)
    except AccountError as error:
        fail(error.code, error.message)


if __name__ == "__main__":
    main()
