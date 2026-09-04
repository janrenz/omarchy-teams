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
# The bare host, needed by the redirect guard above the first request and by
# the image host check further down, which is where it is explained.
GRAPH_HOST_NAME = "graph.microsoft.com"
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

# Setting your own presence is a fourth tier, and opt-in for both reasons at
# once. Presence.ReadWrite is admin-consent - unlike Presence.Read.All, which
# reads the whole organisation's presence on ordinary user consent - so a
# tenant that will not consent to it fails the sign-in, and a registration that
# does not declare it fails the sign-in too. Off by default, and
# can_set_presence() reads the answer back off the granted scopes: nothing is
# offered until it is really there.
SCOPES_PRESENCE = " Presence.ReadWrite"

# The calendar is a fifth tier, and it is two of them. Reading your own
# calendar and writing to it are both ordinary user consent - no administrator
# anywhere - but a registration still declares which of the two it may ask
# for, so a plugin that asked for the write scope uninvited would fail the
# sign-in of everybody whose registration lists only the read one. Hence two
# settings and two tiers: the calendar shows up with Calendars.Read, and
# answering an invitation or booking a meeting needs Calendars.ReadWrite.
#
# ReadWrite is sent instead of Read rather than beside it - it contains it,
# and Entra hands back the wider one either way, which is what
# can_see_calendar reads.
SCOPES_CALENDAR = " Calendars.Read"
SCOPES_CALENDAR_WRITE = " Calendars.ReadWrite"

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


def scopes_for(channels, files=False, presence=False, calendar=False, calendar_write=False):
    scopes = SCOPES_CHANNELS if channels else SCOPES_CHATS
    if calendar_write:
        calendar_scope = SCOPES_CALENDAR_WRITE
    elif calendar:
        calendar_scope = SCOPES_CALENDAR
    else:
        calendar_scope = ""
    return (scopes + (SCOPES_FILES if files else "") + (SCOPES_PRESENCE if presence else "")
            + calendar_scope)


def scopes_held_by(account):
    """What a refresh should ask this account for.

    Its own granted scopes, not what the settings currently want. Two reasons,
    and they pull the same way: a tier the settings have just gained is not
    consented yet, and asking for a scope the registration does not declare
    fails the refresh rather than that one scope - while asking for *less* than
    was granted has the token come back with less, and store_tokens records
    that as what this sign-in can do. Either way the opt-in tiers would fall
    off an account at its first refresh, an hour after signing in.
    """
    return scopes_for(has_channels(account), can_upload(account), can_set_presence(account),
                      can_see_calendar(account), can_write_calendar(account))


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


# --------------------------------------------------------------------------
# redirects
#
# The host checks in this file all look at the URL they were handed, and a
# redirect is the one way that URL stops being the address the request arrives
# at. urllib follows one by copying the request's headers onto the new
# request - everything but Content-Length and Content-Type, so `Authorization`
# among them - and compares no hosts on the way. An allowed host answering
# `302 Location: https://evil/` would hand over a token that can read this
# mailbox, having passed every check above.
#
# So the check runs again as the redirect is followed: the token comes off the
# moment the host changes, a redirect off https is refused rather than
# downgraded, and the request that sends a file follows nothing at all. The
# hosts this plugin addresses do not redirect, so the strict list costs
# nothing today and says so out loud on the day one of them starts.
# --------------------------------------------------------------------------

LOGIN_HOST = "login.microsoftonline.com"


class GuardedRedirects(urllib.request.HTTPRedirectHandler):
    """Follow a redirect only as far as it can be followed safely."""

    def __init__(self, allowed=(), refuse=False):
        self.allowed = tuple(allowed)
        self.refuse = refuse

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        if self.refuse:
            raise AccountError(
                "redirect_refused",
                "That request was redirected to %s, which this plugin will not follow"
                % (urllib.parse.urlsplit(newurl).hostname or "nowhere"))

        new = super().redirect_request(request, fp, code, msg, headers, newurl)
        if new is None:
            return None
        # super() may rewrite the URL, so the decision is made about the
        # address that will actually be fetched.
        target = urllib.parse.urlsplit(new.full_url)
        where = target.hostname or "nowhere"
        if target.scheme != "https":
            raise AccountError("bad_redirect",
                               "Refusing to follow a redirect to %s://%s" % (target.scheme, where))
        if self.allowed and where not in self.allowed:
            raise AccountError("bad_redirect", "Refusing to follow a redirect to %s" % where)
        if where != (urllib.parse.urlsplit(request.full_url).hostname or ""):
            new.remove_header("Authorization")
        return new


def guarded_opener(allowed=(), refuse_redirects=False):
    """An opener that re-checks the host every time a redirect moves it."""
    return urllib.request.build_opener(GuardedRedirects(allowed, refuse_redirects))


# Graph and the sign-in endpoint are the only two hosts this plugin addresses.
# Shared between calls, like the global opener `urlopen` uses: the handlers
# hold no per-request state and each open makes its own connection.
API_OPENER = guarded_opener((GRAPH_HOST_NAME, LOGIN_HOST))
# The one request that *sends* the user's file. Bytes addressed to Graph are
# not posted somewhere else because the answer said to.
UPLOAD_OPENER = guarded_opener((GRAPH_HOST_NAME,), refuse_redirects=True)


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
    # A file being sent is the one payload that must not be replayed to an
    # address the answer chose, so it follows no redirect at all.
    opener = UPLOAD_OPENER if raw is not None else API_OPENER
    try:
        with opener.open(request, timeout=timeout) as response:
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
            "scope": scopes_held_by(account),
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
        data={"client_id": client_id,
              "scope": scopes_for(args.channels, args.files, args.presence,
                                  args.calendar or args.calendar_write,
                                  args.calendar_write)},
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
GRAPH_HOST = GRAPH_HOST_NAME
# A redirect may not leave that host either, and the token comes off if it
# somehow does.
IMAGE_OPENER = guarded_opener((GRAPH_HOST,))
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


# A message that carries a file says nothing at all in its body: Teams puts an
# <attachment> tag there and the file itself in `attachments`, so a file sent
# with no comment arrived here as a message with no text - which is what a file
# sent from this window looked like. Nothing had gone wrong; there was just
# nothing drawn.
ATTACHMENT_CAP = 10


def message_attachments(message):
    """The files on a message: what to call each one, and where it is.

    Not the inline images - those arrive as hostedContents and message_images
    draws them where they were written. What is left is Teams' reference
    attachment, a file in somebody's OneDrive with a link to it, and cards,
    which have no file behind them and nothing this window could do with one.
    Having somewhere to go is what separates the two, so that is the test.
    """
    rows = []
    for attachment in (message.get("attachments") or []):
        url = str(attachment.get("contentUrl") or "").strip()
        if not url.lower().startswith(("http://", "https://")):
            continue
        rows.append({
            "id": str(attachment.get("id") or ""),
            "name": str(attachment.get("name") or "").strip() or "a file",
            "url": url,
        })
        if len(rows) >= ATTACHMENT_CAP:
            break
    return rows


# A quote-reply and a forward are not in the body. Teams puts the quoted
# message in `attachments` and leaves an `<attachment id="...">` placeholder in
# the body where it belongs - and that placeholder is stripped along with every
# other tag, so a message that quoted something arrived here as the reply on
# its own, with the thing being replied to silently gone.
#
# Two shapes, because Teams has two, and they carry the quoted text
# differently:
#
#   messageReference           a quote-reply. `messagePreview` is text Teams
#                              has already flattened, and there is no date.
#   forwardedMessageReference  a forwarded message. `originalMessageContent`
#                              is the original's HTML and has to go through the
#                              same reader a body does.
#
# Neither has a contentUrl, which is why message_attachments skips them: that
# function is looking for a file to open, and there is none here.
QUOTE_TYPES = ("messageReference", "forwardedMessageReference")
QUOTE_CAP = 4
# A quote is context for the reply, not the reply. Past a few lines it stops
# being context and starts being the message somebody scrolls past to reach
# what was actually said.
QUOTE_CHARS = 400


def message_quotes(message):
    """What a message is quoting or forwarding: who said it, and what.

    Text only, and flattened the same way a body is - a quote is somebody
    else's markup twice over, and nothing here is going to render it.
    """
    rows = []
    for attachment in (message.get("attachments") or []):
        kind = str(attachment.get("contentType") or "")
        if kind not in QUOTE_TYPES:
            continue
        content = attachment.get("content")
        if isinstance(content, (str, bytes)):
            try:
                content = json.loads(content)
            except ValueError:
                content = None
        if not isinstance(content, dict):
            continue
        forwarded = kind == "forwardedMessageReference"
        if forwarded:
            text = plain_text(content.get("originalMessageContent"))
            sender = content.get("originalMessageSender") or {}
            when = str(content.get("originalSentDateTime") or "")
        else:
            # Through plain_text even though Teams calls it a preview: it is a
            # preview of somebody's HTML, and the entities are still in it.
            text = plain_text(content.get("messagePreview"))
            sender = content.get("messageSender") or {}
            when = ""
        who = str(((sender.get("user") or {}).get("displayName") or "")).strip()
        # A reference with neither is a reference to something this account
        # cannot see - a row saying nothing is worse than no row.
        if not text and not who:
            continue
        rows.append({
            "id": str(content.get("originalMessageId") or content.get("messageId") or ""),
            "from": who,
            # Kept even when the name is there, so one code path fills both -
            # see name_the_nameless, which is the only reason this is here.
            "fromId": str(((sender.get("user") or {}).get("id") or "")),
            "text": text[:QUOTE_CHARS],
            "when": when,
            "forwarded": forwarded,
        })
        if len(rows) >= QUOTE_CAP:
            break
    return rows


def preview_text(preview):
    """One line of a conversation for the sidebar, after the sender's name.

    A message that is only a file came out blank here, and a chat whose newest
    message is a file read as a chat with nothing in it. Graph does not merely
    leave the <attachment> tag in the preview for this to strip - it hands back
    an empty body and no attachments at all, so what the file was called cannot
    be known from here without a request per chat, and there are forty chats.
    Something in the sender's own voice is worth more than a blank line.

    Only for a message somebody sent, though: "X added Y to the chat" is an
    event and a deleted one is a deletion, and both are empty for their own
    reasons.
    """
    row = preview or {}
    text = plain_text((row.get("body") or {}).get("content"))[:160]
    if text:
        return text
    # A chat nobody has said anything in yet has no preview, rather than an
    # empty one, and has never had a file in it either.
    if not str(row.get("createdDateTime") or ""):
        return ""
    if row.get("isDeleted") or str(row.get("messageType") or "message") != "message":
        return ""
    return "a file or a picture"


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
        "attachments": message_attachments(message),
        "quotes": message_quotes(message),
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
            "lastText": preview_text(preview),
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
        "canSetPresence": can_set_presence(account),
        "calendar": can_see_calendar(account),
        "canWriteCalendar": can_write_calendar(account),
        "me": None,
        "chats": [],
        "teams": [],
        "unreadCount": 0,
        "warnings": [],
    }

    chats, chat_error = chat_rows(token, account.get("userId", ""), max(1, min(args.chats, CHAT_CAP)))
    result["chats"] = chats

    # One batched request for everybody in the list, and only when the sign-in
    # is allowed to ask.
    me_id = str(account.get("userId") or "")
    if can_see_presence(account):
        # The user's own id rides along in the same batch. The picker has to
        # say what it is about to change, and this request takes 650 ids, so
        # asking about one more person costs nothing at all.
        presences, presence_error = fetch_presences(
            token, [row.get("withUserId") for row in chats] + [me_id])
        for row in chats:
            row["presence"] = presences.get(row.get("withUserId") or "", None)
        result["me"] = presences.get(me_id, None)
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
    rows = name_the_nameless(token, [message_row(message, me_id)
                                     for message in payload.get("value", [])])
    # Graph returns newest first; a transcript reads the other way.
    rows.reverse()
    out({"ok": True, "messages": rows})


# Graph will hand back `displayName: null` for a sender and give only the id -
# seen on a forwarded message and on the reference inside it, both at once, so
# the message was drawn with no author and the forward it carried with no
# source. The id is the only thing left to go on, and the directory will turn
# ids into names.
#
# Only ever for the ids that came back nameless: a conversation where everybody
# was named costs nothing, which is the point. One request for the lot when
# some were not, the way presence does it.
NAME_LOOKUP_CAP = 20


def fetch_display_names(token, user_ids):
    """Display names for a batch of user ids, as {id: name}.

    Best effort. A tenant that will not answer this is no reason to lose a
    transcript over, so a refusal is an empty answer and the rows keep the
    empty name they already had.
    """
    ids = [uid for uid in dict.fromkeys(user_ids) if uid][:NAME_LOOKUP_CAP]
    if not ids:
        return {}
    # OData string literals escape a quote by doubling it. A user id is a GUID
    # and will not contain one, but this is building a filter out of values
    # that arrived in a message, and that is reason enough not to trust them.
    listed = ",".join("'" + uid.replace("'", "''") + "'" for uid in ids)
    status, payload = graph_get(token, "/users", {
        "$filter": "id in (%s)" % listed,
        "$select": "id,displayName",
    })
    if status != 200:
        return {}
    found = {}
    for row in payload.get("value") or []:
        name = str(row.get("displayName") or "").strip()
        if name:
            found[str(row.get("id") or "")] = name
    return found


def name_the_nameless(token, rows):
    """Fill in the senders Graph left unnamed, in the messages and their quotes.

    In place, and returning the same list: the transcript is already built by
    the time this runs, and this is a repair rather than a step in building it.
    """
    wanted = []
    for row in rows:
        # A system message ("X added Y to the chat") has no sender by nature,
        # and looking one up would find nothing to look up.
        if not row.get("system") and not row.get("from") and row.get("fromId"):
            wanted.append(row["fromId"])
        for quote in row.get("quotes") or []:
            if not quote.get("from") and quote.get("fromId"):
                wanted.append(quote["fromId"])
    if not wanted:
        return rows

    names = fetch_display_names(token, wanted)
    if not names:
        return rows
    for row in rows:
        if not row.get("system") and not row.get("from"):
            row["from"] = names.get(row.get("fromId") or "", "")
        for quote in row.get("quotes") or []:
            if not quote.get("from"):
                quote["from"] = names.get(quote.get("fromId") or "", "")
    return rows


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
        with IMAGE_OPENER.open(request, timeout=30) as response:
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
        identity = ((reaction.get("user") or {}).get("user") or {})
        who = identity.get("id") or ""
        row = counts.setdefault(emoji, {"emoji": emoji, "count": 0, "mine": False,
                                        "name": reaction.get("displayName") or "",
                                        "who": []})
        row["count"] += 1
        mine = bool(me_id) and str(who) == str(me_id)
        if mine:
            row["mine"] = True
        # Named, not just counted: Graph lists reactions one per person, so the
        # names are already here and a chip can say whose they are. Yourself as
        # "You" and first, the way every chat client names you in your own.
        name = "You" if mine else str(identity.get("displayName") or "").strip()
        if name and name not in row["who"]:
            if mine:
                row["who"].insert(0, name)
            else:
                row["who"].append(name)
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


def can_set_presence(account):
    """Whether this sign-in may set the user's own presence.

    A different question from reading everybody else's, and a dearer one:
    Presence.ReadWrite needs an administrator's consent where Presence.Read.All
    does not.
    """
    return "presence.readwrite" in str((account or {}).get("scopes", "")).lower()


def can_see_calendar(account):
    """Whether this sign-in may read the user's calendar.

    True for either calendar tier, and that is not a coincidence:
    "Calendars.ReadWrite" starts with the string being looked for, so the
    wider grant answers the narrower question without a second test.
    """
    return "calendars.read" in str((account or {}).get("scopes", "")).lower()


def can_write_calendar(account):
    """Whether this sign-in may answer an invitation or book a meeting.

    Read back off the granted scopes rather than off the setting: a
    registration that gained the permission after the fact starts working at
    the next sign-in, and until then the window shows a calendar it cannot
    change instead of buttons that 403.
    """
    return "calendars.readwrite" in str((account or {}).get("scopes", "")).lower()


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


# What the picker offers. The pairs are not free choices: Graph refuses an
# activity that does not belong to its availability, so every row here is one
# row of Microsoft's own table rather than a combination that read sensibly.
# Offline is "appear offline" - the user choosing to look away, which is not
# the same as being away, and the two are named so nobody has to guess which.
# [key, availability, activity, what to call it]
PREFERRED_PRESENCE = [
    ("available", "Available", "Available", "Available"),
    ("busy", "Busy", "Busy", "Busy"),
    ("dnd", "DoNotDisturb", "DoNotDisturb", "Do not disturb"),
    ("brb", "BeRightBack", "BeRightBack", "Be right back"),
    ("away", "Away", "Away", "Appear away"),
    ("offline", "Offline", "OffWork", "Appear offline"),
]

# The session this plugin can hold open is a table of its own, and a shorter
# one: setPresence takes five pairs and none of the others. Only the two that
# are true of a desktop are here - the plugin is not in a call, so it will not
# say "Busy, InACall" to get a red dot out of Graph.
SESSION_PRESENCE = {
    "available": ("Available", "Available"),
    "away": ("Away", "Away"),
}

# What `--state auto` and the picker's first row mean: hand presence back to
# Teams. Several spellings, because this is also a command people type.
CLEAR_WORDS = ("auto", "automatic", "clear", "reset")


def preferred_pair(state):
    """(availability, activity) for one of our short state names."""
    for key, availability, activity, _label in PREFERRED_PRESENCE:
        if key == state:
            return availability, activity
    return "", ""


def own_user_id(token, account):
    """The id Graph wants in the path when we are talking about ourselves.

    The token's own claim first, the way markChatReadForUser gets it: it is the
    id of whoever this token is really for, which beats a `userId` written into
    the account file at some earlier sign-in.
    """
    return token_claims(token).get("oid") or account.get("userId") or ""


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


def cmd_presence_states(_args):
    """The presences that can be set, for the picker.

    From here rather than from the QML, for the same reason the reactions are:
    what Graph will take is the helper's business, and a picker that offers
    anything else is a picker with rows that fail.
    """
    out({"ok": True, "states": [
        # `dot` is which of the four drawable states this one belongs to, so
        # the picker's circles and the sidebar's are the same four colours.
        # Grouped here because the grouping is already here.
        {"state": key, "availability": availability, "activity": activity, "label": label,
         "dot": presence_state(availability)}
        for key, availability, activity, label in PREFERRED_PRESENCE
    ]})


def presence_call(args, verb, body):
    """One POST to /users/{me}/presence/<verb>, with the permission checked first."""
    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_set_presence(account):
        fail("presence_permission_required",
             "This sign-in cannot set your presence. It needs Presence.ReadWrite, which an "
             "administrator has to consent to for the tenant - see the plugin's README.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    user_id = own_user_id(token, account)
    if not user_id:
        fail("no_user_id", "Could not tell Graph whose presence this is")

    session_id = str(account.get("client_id") or "")
    if "sessionId" in body:
        # Graph names a presence session after the application, not after the
        # machine: "Provide the ID of the application as sessionId". So there is
        # one session per registration, and a second machine running this plugin
        # renews that same session rather than opening one of its own.
        if not session_id:
            fail("no_client_id", "This account has no client id to name a session with")
        body = dict(body, sessionId=session_id)

    status, payload = http(
        "%s/users/%s/presence/%s" % (GRAPH, urllib.parse.quote(user_id, safe=""), verb),
        method="POST", json_body=body,
        headers={"Authorization": "Bearer " + token},
    )
    if status == 403:
        fail("presence_permission_required",
             friendly(graph_error(payload, "This sign-in may not set your presence")))
    return status, payload


def cmd_presence(args):
    """Set the presence Teams shows for you, or hand it back to Teams.

    This is the client's own status menu, written through Graph: a preferred
    presence overrides whatever the sessions aggregate to until it is cleared,
    which is what makes "Do not disturb" stick while you keep typing.
    """
    state = str(args.state or "").strip().lower()
    clearing = state in CLEAR_WORDS
    availability, activity = preferred_pair(state)
    if not clearing and not availability:
        fail("bad_presence", "Teams does not take %s as a presence" % (state or "that"))

    if args.demo:
        out({"ok": True, "state": "auto" if clearing else state})

    body = {} if clearing else {"availability": availability, "activity": activity}
    # Graph applies an expiry either way - a day for Busy and Do not disturb, a
    # week for the rest - so passing one on is the difference between "until I
    # say otherwise" and "until this evening", not between expiring and not.
    if not clearing and args.duration:
        body["expirationDuration"] = str(args.duration)

    verb = "clearUserPreferredPresence" if clearing else "setUserPreferredPresence"
    status, payload = presence_call(args, verb, body)
    if status not in (200, 201, 204):
        fail("presence_failed", friendly(graph_error(payload, "Could not set your presence")))
    out({"ok": True, "state": "auto" if clearing else state,
         "availability": availability, "activity": activity})


def cmd_hold_presence(args):
    """Keep a presence session open for this machine, or let it go.

    A preferred presence only shows while at least one presence session exists;
    with no Teams client signed in anywhere the user is Offline whatever they
    set, and the picker would look broken. This is that session - the plugin
    saying it is a Teams client at a desktop - which is why it expires and has
    to be renewed rather than being set once and forgotten.
    """
    state = str(args.state or "available").strip().lower()
    clearing = state == "none"
    pair = SESSION_PRESENCE.get(state)
    if not clearing and not pair:
        fail("bad_presence",
             "A presence session can be available or away, not %s" % (state or "that"))

    if args.demo:
        out({"ok": True, "state": state})

    if clearing:
        verb, body = "clearPresence", {"sessionId": ""}
    else:
        verb, body = "setPresence", {
            "sessionId": "",
            "availability": pair[0],
            "activity": pair[1],
            # Graph takes PT5M to PT4H and defaults to five minutes, which
            # would need renewing oftener than this plugin polls.
            "expirationDuration": str(args.duration or "PT1H"),
        }

    status, payload = presence_call(args, verb, body)
    # Letting go of a session that has already expired is a 404, and that is
    # the state being asked for rather than a failure.
    if clearing and status == 404:
        out({"ok": True, "state": state, "alreadyGone": True})
    if status not in (200, 201, 204):
        fail("presence_failed",
             friendly(graph_error(payload, "Could not hold the presence session")))
    out({"ok": True, "state": state})


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
# the calendar
#
# /me/calendarView rather than /me/events, and the difference matters: events
# hands back a recurring meeting once, as the series master with its rule
# attached, and leaves the expanding to whoever asked. calendarView expands
# it - one row per occurrence inside the window asked for - which is what a
# calendar draws and what nothing here would get right by hand.
#
# Times come back in UTC and every consumer of them wants local, so the
# conversion happens here rather than in the QML - the same division as the
# markup flattening: it is the helper's business to hand the window something
# it can draw without arithmetic. Each row carries an ISO timestamp with this
# machine's offset on it and the local date it belongs to, which is what the
# day columns group by. No timezone maths happens above this file at all.
# --------------------------------------------------------------------------

# A month of a busy calendar, which is the widest view there is. Past this the
# window is drawing rows nobody scrolls to and Graph is being asked to page.
CALENDAR_CAP = 250
CALENDAR_DAYS_CAP = 62
# A meeting invitation carries the whole agenda, and Teams shows all of it.
# "Open it elsewhere to read the rest" is not a feature - see the README.
EVENT_BODY_CHARS = 20000
ATTENDEE_CAP = 60

# What a row in a day column needs. Deliberately without `attendees` and
# `body`: an invitation to forty people carries forty addresses and its whole
# agenda, and a month view would fetch two hundred of those to draw a line of
# text each. Both arrive with `event`, when one is opened.
EVENT_LIST_FIELDS = (
    "id,subject,bodyPreview,start,end,isAllDay,isCancelled,isOrganizer,"
    "location,organizer,responseStatus,responseRequested,showAs,type,"
    "seriesMasterId,isOnlineMeeting,onlineMeeting,importance,sensitivity,"
    "categories,hasAttachments"
)
EVENT_DETAIL_FIELDS = EVENT_LIST_FIELDS + ",body,attendees,allowNewTimeProposals"

# Graph's own words for how an invitation stands, in ours. The two it does not
# distinguish are worth distinguishing: `none` is "nobody was invited to this"
# and `notResponded` is "you have not answered yet", and only the second one
# is a question the window can offer to answer.
RESPONSES = {
    "none": "none",
    "organizer": "organizer",
    "accepted": "accepted",
    "tentativelyaccepted": "tentative",
    "declined": "declined",
    "notresponded": "pending",
}

# What may be sent back, and the Graph action each one is. The names are ours
# and the actions are Microsoft's, which is why this is a table rather than a
# string built out of the answer.
RSVP_ACTIONS = {
    "accept": "accept",
    "tentative": "tentativelyAccept",
    "decline": "decline",
}

SHOW_AS = ("free", "tentative", "busy", "oof", "workingelsewhere", "unknown")


def zone_of(name):
    """The timezone Graph named, or UTC.

    Graph answers in UTC unless it is asked otherwise, which this plugin never
    does, so this is a fallback rather than the normal path. A Windows zone
    name ("W. Europe Standard Time") is not an IANA one and has no entry in
    the system database; reading it as UTC is wrong by an hour or two, which
    beats failing to draw the day at all.
    """
    label = str(name or "").strip()
    if not label or label.lower() in ("utc", "gmt", "z"):
        return timezone.utc
    try:
        import zoneinfo

        return zoneinfo.ZoneInfo(label)
    except Exception:
        return timezone.utc


def local_zone_name():
    """This machine's IANA timezone name, or "" when it cannot be told.

    Only writing needs it: an all-day event has to be filed as midnight in a
    named zone, because midnight UTC is the previous evening in half the world
    and Graph would put the day one out. Reading needs none of this - the
    system's own offset is enough to turn an instant into a local one.
    """
    named = str(os.environ.get("TZ") or "").strip().lstrip(":")
    if "/" in named:
        return named
    try:
        link = os.readlink("/etc/localtime")
    except OSError:
        return ""
    parts = link.split("zoneinfo/")
    return parts[1] if len(parts) == 2 else ""


def graph_moment(field):
    """A Graph dateTimeTimeZone as a local aware datetime, or None.

    Graph writes seven fractional digits, which `fromisoformat` refuses on the
    Pythons this has to run on, so the fraction is trimmed to six.
    """
    raw = str((field or {}).get("dateTime") or "").strip()
    if not raw:
        return None
    if "." in raw:
        head, _, fraction = raw.partition(".")
        digits = "".join(ch for ch in fraction if ch.isdigit())[:6]
        raw = head + ("." + digits if digits else "")
    try:
        when = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=zone_of((field or {}).get("timeZone")))
    return when.astimezone()


def day_key(when):
    """The local date a moment belongs to, as the window's own day key."""
    return when.strftime("%Y-%m-%d") if when else ""


def local_iso(when):
    """A local moment as ISO 8601 with its offset, which JavaScript parses."""
    return when.replace(microsecond=0).isoformat() if when else ""


def event_location(event):
    """Where it is, in one line.

    `location` is the one Outlook shows and the one a room booking fills in.
    `locations` is the same thing as a list, and is only richer when several
    rooms are booked - which is not worth a second line in a window this size.
    """
    place = str(((event.get("location") or {}).get("displayName") or "")).strip()
    if place:
        return place
    for entry in event.get("locations") or []:
        name = str((entry or {}).get("displayName") or "").strip()
        if name:
            return name
    return ""


def join_url(event):
    """The link that joins this meeting, if it is one.

    https only, and nothing else is looked at: this URL is handed to xdg-open,
    and xdg-open opens whatever it is handed.
    """
    url = str(((event.get("onlineMeeting") or {}).get("joinUrl") or "")).strip()
    return url if url.lower().startswith("https://") else ""


def attendee_rows(event):
    """Who was invited, and what each of them said."""
    rows = []
    for attendee in (event.get("attendees") or [])[:ATTENDEE_CAP]:
        address = (attendee.get("emailAddress") or {})
        rows.append({
            "name": str(address.get("name") or address.get("address") or "").strip(),
            "address": str(address.get("address") or "").strip(),
            "kind": str(attendee.get("type") or "required").lower(),
            "response": RESPONSES.get(
                str(((attendee.get("status") or {}).get("response") or "")).lower(), "none"),
        })
    return rows


def event_row(event, detailed=False):
    """One event, shaped for a day column.

    The two dates are what the columns group by: `startDate` is the day it
    begins on and `endDate` the last day it touches, both local. `endDate` is
    computed from the last moment the event covers rather than from its end,
    because an end is exclusive - an all-day Friday ends at Saturday midnight
    and a 23:00 call ends at midnight on the next date, and both would
    otherwise be drawn on a day they are not in.
    """
    start = graph_moment(event.get("start"))
    end = graph_moment(event.get("end"))
    if start and not end:
        end = start
    last = (end - timedelta(microseconds=1)) if (start and end and end > start) else start
    all_day = event.get("isAllDay") is True
    minutes = int(round((end - start).total_seconds() / 60.0)) if (start and end) else 0
    organizer = ((event.get("organizer") or {}).get("emailAddress") or {})
    kind = str(event.get("type") or "singleInstance")
    shown = str(event.get("showAs") or "unknown").lower()

    row = {
        "id": str(event.get("id") or ""),
        "subject": str(event.get("subject") or "").strip() or "(no subject)",
        "preview": plain_text(event.get("bodyPreview"))[:200],
        "when": local_iso(start),
        "until": local_iso(end),
        "startDate": day_key(start),
        "endDate": day_key(last),
        "allDay": all_day,
        "minutes": minutes,
        "where": event_location(event),
        "online": event.get("isOnlineMeeting") is True or join_url(event) != "",
        "joinUrl": join_url(event),
        "organizer": {
            "name": str(organizer.get("name") or organizer.get("address") or "").strip(),
            "address": str(organizer.get("address") or "").strip(),
        },
        "isOrganizer": event.get("isOrganizer") is True,
        # Whether this is an invitation at all, and what was said to it. The
        # window offers an answer only where there is a question.
        "response": RESPONSES.get(
            str(((event.get("responseStatus") or {}).get("response") or "")).lower(), "none"),
        "responseRequested": event.get("responseRequested") is not False,
        "showAs": shown if shown in SHOW_AS else "unknown",
        "cancelled": event.get("isCancelled") is True,
        # An occurrence, an edited occurrence, or the series itself - drawn as
        # a mark on the row, the way every calendar marks a repeat.
        "recurring": kind != "singleInstance",
        "seriesId": str(event.get("seriesMasterId") or ""),
        "important": str(event.get("importance") or "").lower() == "high",
        "private": str(event.get("sensitivity") or "normal").lower() in ("private", "confidential"),
        "categories": [str(name) for name in (event.get("categories") or [])][:6],
        "attachments": event.get("hasAttachments") is True,
    }
    if not detailed:
        return row

    text, links = text_and_links((event.get("body") or {}).get("content"))
    row["text"] = text[:EVENT_BODY_CHARS]
    # The same offsets a message carries, and for the same reason: the window
    # builds every tag it draws, and an invitation is HTML somebody else wrote.
    row["links"] = [span for span in links if span["end"] <= EVENT_BODY_CHARS]
    row["truncated"] = len(text) > EVENT_BODY_CHARS
    row["attendees"] = attendee_rows(event)
    row["newTimeProposals"] = event.get("allowNewTimeProposals") is True
    return row


def calendar_window(from_date, days):
    """The range to ask Graph for: the two UTC instants bounding local days.

    Local, and that is the point - a day column starts at midnight where the
    user is, not at midnight UTC. Asking for the UTC day would put an early
    meeting in yesterday's column for anybody east of London.
    """
    try:
        start = datetime.fromisoformat(str(from_date) + "T00:00:00").astimezone()
    except ValueError:
        raise AccountError("bad_date", "A date has to be written as YYYY-MM-DD")
    span = max(1, min(int(days or 1), CALENDAR_DAYS_CAP))
    return start, start + timedelta(days=span), span


def utc_param(when):
    """A local instant as the naive UTC string Graph's query takes."""
    return when.astimezone(timezone.utc).replace(tzinfo=None, microsecond=0).isoformat()


def cmd_calendar(args):
    """Every event touching a range of local days, occurrences expanded."""
    try:
        start, end, span = calendar_window(args.since, args.days)
    except AccountError as error:
        fail(error.code, error.message)

    if args.demo:
        out({"ok": True, "from": day_key(start), "days": span, "canWrite": True,
             "capped": False, "events": demo_events(start, end)})

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_see_calendar(account):
        fail("calendar_permission_required",
             "This sign-in cannot read your calendar. Add Calendars.Read to your app "
             "registration, turn on \"Calendar\" in this widget's settings, and sign in "
             "again - see the plugin's README.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    status, payload = graph_get(token, "/me/calendarView", {
        "startDateTime": utc_param(start),
        "endDateTime": utc_param(end),
        "$select": EVENT_LIST_FIELDS,
        "$orderby": "start/dateTime",
        "$top": str(CALENDAR_CAP),
    })
    if status == 403:
        fail("calendar_permission_required",
             friendly(graph_error(payload, "This sign-in may not read your calendar")))
    if status != 200:
        fail("calendar_failed", friendly(graph_error(payload, "Could not read your calendar")))

    found = payload.get("value") or []
    rows = [event_row(event) for event in found[:CALENDAR_CAP]]
    # By when they start, with an all-day event above the morning's first
    # meeting rather than wherever its UTC midnight happened to sort.
    rows.sort(key=lambda row: (row["startDate"], not row["allDay"], row["when"]))
    out({"ok": True, "from": day_key(start), "days": span, "events": rows,
         "canWrite": can_write_calendar(account),
         # There is no paging here on purpose - a month nobody can scroll past
         # is not worth a second request - so a range that hits the cap says
         # so rather than quietly ending early.
         "capped": len(found) > CALENDAR_CAP})


def cmd_event(args):
    """One event in full: who was invited, what they said, and the agenda."""
    if args.demo:
        out({"ok": True, "canWrite": True, "event": demo_event_detail(args.event)})

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_see_calendar(account):
        fail("calendar_permission_required", "This sign-in cannot read your calendar")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    status, payload = graph_get(
        token, "/me/events/%s" % urllib.parse.quote(args.event, safe=""),
        {"$select": EVENT_DETAIL_FIELDS})
    if status == 404:
        fail("event_gone", "That meeting is no longer on your calendar")
    if status != 200:
        fail("event_failed", friendly(graph_error(payload, "Could not read that meeting")))
    out({"ok": True, "event": event_row(payload, detailed=True),
         "canWrite": can_write_calendar(account)})


def cmd_rsvp(args):
    """Accept, tentatively accept, or decline an invitation.

    The comment arrives on stdin like a message, because that is what it is:
    something the user wrote, which everybody on the invitation will read.
    """
    answer = str(args.response or "").strip().lower()
    action = RSVP_ACTIONS.get(answer)
    if not action:
        fail("bad_response", "An invitation can be accepted, tentative or declined")
    comment = str(args.comment or "")
    if args.stdin:
        comment = str(read_stdin_json().get("comment") or comment)

    if args.demo:
        out({"ok": True, "response": answer, "event": args.event, "replied": not args.silent})

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_write_calendar(account):
        fail("calendar_write_permission_required",
             "This sign-in can read your calendar but not answer invitations. It needs "
             "Calendars.ReadWrite - turn on \"Answer and create meetings\" in this "
             "widget's settings and sign in again.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    body = {"sendResponse": not args.silent}
    if comment.strip():
        body["comment"] = comment.strip()
    status, payload = http(
        "%s/me/events/%s/%s" % (GRAPH, urllib.parse.quote(args.event, safe=""), action),
        method="POST", json_body=body,
        headers={"Authorization": "Bearer " + token})
    if status == 403:
        fail("calendar_write_permission_required",
             friendly(graph_error(payload, "This sign-in may not answer invitations")))
    if status == 404:
        fail("event_gone", "That invitation is no longer on your calendar")
    if status not in (200, 201, 202, 204):
        fail("rsvp_failed", friendly(graph_error(payload, "Could not send that answer")))
    out({"ok": True, "response": answer, "event": args.event, "replied": not args.silent})


def meeting_time(value, all_day, zone):
    """One end of a new meeting, written the way Graph wants it.

    The window sends wall-clock time with no zone on it, which is what
    somebody typing "14:00" means, so this is where it acquires one. With a
    zone name to hand it goes as that zone's wall clock - the only way an
    all-day event lands on the right day, and the only way a meeting booked
    across a daylight-saving change keeps the time it was typed at. Without
    one it becomes a UTC instant, which is exact for a meeting and not good
    enough for a whole day.
    """
    text = str(value or "").strip()
    if not text:
        raise AccountError("bad_time", "A meeting needs a start and an end")
    if all_day:
        text = text[:10] + "T00:00:00"
    try:
        when = datetime.fromisoformat(text)
    except ValueError:
        raise AccountError("bad_time", "A time has to be written as YYYY-MM-DDTHH:MM")
    if when.tzinfo is not None:
        when = when.astimezone()
    if zone:
        return {"dateTime": when.replace(tzinfo=None).isoformat(), "timeZone": zone}
    if all_day:
        raise AccountError(
            "no_timezone",
            "An all-day event has to be filed in a named timezone, and this machine's "
            "could not be read from TZ or /etc/localtime")
    return {"dateTime": when.astimezone(timezone.utc).replace(tzinfo=None).isoformat(),
            "timeZone": "UTC"}


def new_event_body(payload, zone):
    """The event to POST, out of what the window sent. Raises on nonsense."""
    subject = str(payload.get("subject") or "").strip()
    if not subject:
        raise AccountError("no_subject", "A meeting needs a subject")

    all_day = payload.get("allDay") is True
    start = meeting_time(payload.get("start"), all_day, zone)
    end = meeting_time(payload.get("end"), all_day, zone)
    if start["dateTime"] >= end["dateTime"]:
        raise AccountError("bad_range", "A meeting has to end after it starts")

    attendees = []
    for guest in (payload.get("attendees") or [])[:ATTENDEE_CAP]:
        address = str((guest or {}).get("address") or "").strip()
        if not address:
            continue
        attendees.append({
            "emailAddress": {"address": address,
                             "name": str(guest.get("name") or "").strip() or address},
            "type": "optional" if str(guest.get("kind") or "") == "optional" else "required",
        })

    body = {
        "subject": subject,
        "isAllDay": all_day,
        "start": start,
        "end": end,
        # Text, not HTML: what somebody typed is what the invitation should
        # say, and a stray < in an agenda should not become markup on
        # everyone else's screen. The same rule sending a message follows.
        "body": {"contentType": "text", "content": str(payload.get("text") or "")},
        "attendees": attendees,
    }
    where = str(payload.get("where") or "").strip()
    if where:
        body["location"] = {"displayName": where}
    if payload.get("online") is True:
        # This is what makes it a Teams meeting rather than an appointment:
        # Graph books the meeting and fills the join link in, and no separate
        # OnlineMeetings permission is involved.
        body["isOnlineMeeting"] = True
        body["onlineMeetingProvider"] = "teamsForBusiness"
    shown = str(payload.get("showAs") or "").lower()
    if shown in SHOW_AS and shown != "unknown":
        body["showAs"] = {"oof": "oof", "workingelsewhere": "workingElsewhere"}.get(shown, shown)
    reminder = payload.get("reminderMinutes")
    if isinstance(reminder, (int, float)) and 0 <= int(reminder) <= 40320:
        body["reminderMinutesBeforeStart"] = int(reminder)
        body["isReminderOn"] = True
    return body


def cmd_new_event(args):
    """Put a meeting on the calendar, and invite people to it.

    Everything comes in on stdin. A subject, an agenda and a guest list are
    all somebody's words and other people's addresses, and none of that
    belongs on a command line anyone on this machine can read.
    """
    payload = read_stdin_json() if args.stdin else {}
    try:
        body = new_event_body(payload, local_zone_name())
    except AccountError as error:
        fail(error.code, error.message)

    # Everything that does not need the network is settled above, so demo
    # refuses exactly what the real thing refuses.
    if args.demo:
        out({"ok": True, "event": dict(demo_event_detail("demo-event-1"),
                                       id="demo-event-new", subject=body["subject"])})

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_write_calendar(account):
        fail("calendar_write_permission_required",
             "This sign-in can read your calendar but not add to it. It needs "
             "Calendars.ReadWrite - turn on \"Answer and create meetings\" in this "
             "widget's settings and sign in again.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    status, created = http(GRAPH + "/me/events", method="POST", json_body=body,
                           headers={"Authorization": "Bearer " + token})
    if status == 403:
        fail("calendar_write_permission_required",
             friendly(graph_error(created, "This sign-in may not add to your calendar")))
    if status not in (200, 201):
        fail("new_event_failed", friendly(graph_error(created, "Could not create that meeting")))
    out({"ok": True, "event": event_row(created, detailed=True)})


def cmd_cancel_event(args):
    """Call off a meeting you organised, or take one off your own calendar.

    Two different things, and which one this is depends on whose meeting it
    is: an organiser cancelling sends everybody a cancellation, an attendee
    deleting removes only their own copy. Graph has an endpoint for each, so
    the event is read first to find out which - guessing would either mail a
    cancellation to forty people or quietly fail to.
    """
    comment = str(args.comment or "")
    if args.stdin:
        comment = str(read_stdin_json().get("comment") or comment)

    if args.demo:
        out({"ok": True, "event": args.event, "action": "cancelled"})

    account = read_json(state_path(args.account))
    if not account:
        fail("auth_required", "Not signed in")
    if not can_write_calendar(account):
        fail("calendar_write_permission_required",
             "This sign-in can read your calendar but not change it. It needs "
             "Calendars.ReadWrite - turn on \"Answer and create meetings\" in this "
             "widget's settings and sign in again.")
    try:
        token, account = access_token(args.account, account)
    except AccountError as error:
        fail(error.code, error.message)

    path = "/me/events/%s" % urllib.parse.quote(args.event, safe="")
    headers = {"Authorization": "Bearer " + token}
    status, event = graph_get(token, path, {"$select": "isOrganizer,attendees,subject"})
    if status == 404:
        fail("event_gone", "That meeting is no longer on your calendar")
    if status != 200:
        fail("cancel_failed", friendly(graph_error(event, "Could not read that meeting")))

    if event.get("isOrganizer") is True and (event.get("attendees") or []):
        body = {}
        if comment.strip():
            body["comment"] = comment.strip()
        status, payload = http(GRAPH + path + "/cancel", method="POST", json_body=body,
                               headers=headers)
        action = "cancelled"
    else:
        status, payload = http(GRAPH + path, method="DELETE", headers=headers)
        action = "removed"
    if status == 403:
        fail("calendar_write_permission_required",
             friendly(graph_error(payload, "This sign-in may not change your calendar")))
    if status not in (200, 202, 204):
        fail("cancel_failed", friendly(graph_error(payload, "Could not call that meeting off")))
    out({"ok": True, "event": args.event, "action": action})


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


def too_large(size):
    """Why this file is not going, in the terms the cap is set in."""
    fail("too_large",
         "That file is %.1f MB. Graph takes up to %d MB in one request; more than that "
         "needs an upload session on a SharePoint host, and this plugin only ever talks "
         "to graph.microsoft.com." % (size / 1048576.0, UPLOAD_CAP // 1048576))


def read_upload(path):
    """The bytes to send, or a refusal a person can act on.

    The path is resolved once, at `os.open`, and everything after that is
    asked of the descriptor. Asking the name three times - `isfile`, then
    `getsize`, then `open` - is three chances for it to mean a different file
    each time, and the size that was checked is then not the size that is
    read. A symlink is still followed, because somebody dragging a link to
    their own file means the file, but it is followed once and what is on the
    other side still has to be a regular file.
    """
    if not path:
        fail("no_file", "No file to send")
    try:
        # O_NONBLOCK because the open now happens first rather than last: a
        # FIFO with nobody writing to it, or a device waiting on a carrier,
        # would otherwise hang a helper the window is waiting on. It costs
        # nothing on a regular file, which is all that gets past the fstat.
        handle = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)
    except IsADirectoryError:
        fail("no_file", "%s is a folder, not a file" % path)
    except FileNotFoundError:
        fail("no_file", "There is no file at %s" % path)
    except OSError as error:
        fail("unreadable", "Could not read %s: %s" % (path, error))
    try:
        info = os.fstat(handle)
        if not stat.S_ISREG(info.st_mode):
            fail("no_file", "%s is not a file this can send" % path)
        if info.st_size == 0:
            fail("empty_file", "That file is empty")
        if info.st_size > UPLOAD_CAP:
            too_large(info.st_size)
        with os.fdopen(handle, "rb", closefd=False) as stream:
            body = stream.read(UPLOAD_CAP + 1)
    except OSError as error:
        fail("unreadable", "Could not read %s: %s" % (path, error))
    finally:
        os.close(handle)
    # It is one descriptor, but a writer elsewhere is not waiting for us: a
    # file that grew past the cap between the fstat and the read is still
    # refused, so the cap holds on what was actually read.
    if len(body) > UPLOAD_CAP:
        too_large(len(body))
    if not body:
        fail("empty_file", "That file is empty")
    return body


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
    # On stdin, not in argv: anyone on this machine can read another process's
    # command line for as long as it runs, and a message is somebody's words.
    # --text stays for running this by hand, where the shell history is already
    # the bigger leak.
    text = str(args.text or "")
    if args.stdin:
        text = str(read_stdin_json().get("text") or text)
    text = text.strip()
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
        "canSetPresence": True,
        "calendar": True,
        "canWriteCalendar": True,
        "me": {"state": "available", "availability": "Available", "activity": "Available"},
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
            # And one quotes the line before it, so the quote block has
            # something to draw without anybody having to reply to anything.
            "quotes": ([{"id": "d%d" % index, "from": turns[index - 1][0],
                         "fromId": turns[index - 1][1],
                         "text": plain_text(turns[index - 1][3]),
                         "when": "", "forwarded": False}]
                       if index == len(turns) - 1 and index > 0 else []),
            # One of them carries a reaction so the chip can be laid out
            # without anybody having to react to anything.
            "reactions": ([{"emoji": "\U0001F44D", "count": 2, "mine": index == 1, "name": "Like",
                            "who": ["You", "Ana Beltr\u00e1n"]}]
                          if index == 1 else []),
        })
    return {"ok": True, "messages": messages}


# A week of a plausible calendar, so the day, week and month views can all be
# built and photographed without anybody's real meetings being on screen.
# Anchored to today rather than to fixed dates: a screenshot taken next month
# should still show a working day, and the harness should never open on an
# empty grid.
#
# Two of them overlap on purpose - the 11:00 planning and the 11:30 one-to-one
# - because side-by-side columns are the part of a day view that is wrong most
# often and there has to be something to look at while getting them right.
#
# [days from today, start, minutes, subject, where, online, response, showAs, repeats]
DEMO_EVENTS = [
    (0, "09:00", 15, "Daily standup", "", True, "accepted", "busy", True),
    (0, "11:00", 60, "Sprint 24 planning", "", True, "pending", "busy", False),
    (0, "11:30", 30, "1:1 with Priya", "", True, "accepted", "busy", True),
    (0, "14:00", 90, "Release 14.02 go/no-go", "Room 3.14", False, "tentative", "busy", False),
    (0, "16:30", 30, "Retro", "", True, "organizer", "busy", True),
    (1, "09:00", 15, "Daily standup", "", True, "accepted", "busy", True),
    (1, "10:00", 60, "Design review", "", True, "declined", "busy", False),
    (1, "13:00", 45, "Platform sync", "Room 2.02", False, "accepted", "busy", True),
    (2, "09:00", 15, "Daily standup", "", True, "accepted", "busy", True),
    (2, "15:00", 120, "Architecture workshop", "Room 4.01", False, "pending", "busy", False),
    (3, "09:00", 15, "Daily standup", "", True, "accepted", "busy", True),
    (4, "11:00", 30, "Coffee with Dana", "The kitchen", False, "accepted", "free", False),
    (7, "10:00", 60, "Quarterly review", "", True, "pending", "busy", False),
]

# All-day rows, which have their own strip above the grid and their own way of
# going wrong: an end is exclusive, so a one-day event ends at the next
# midnight and a naive reading draws it over two days.
# [days from today, days long, subject, showAs]
DEMO_ALL_DAY = [
    (0, 1, "Dana on leave", "oof"),
    (2, 3, "Accessibility week", "free"),
]

DEMO_ORGANISERS = {
    "Daily standup": ("Tomás Lindqvist", "tomas@example.com"),
    "Sprint 24 planning": ("Ana Beltrán", "ana@example.com"),
    "1:1 with Priya": ("Priya Raman", "priya@example.com"),
    "Release 14.02 go/no-go": ("Ana Beltrán", "ana@example.com"),
    "Design review": ("Yuki Tanaka", "yuki@example.com"),
    "Architecture workshop": ("Mikael Sørensen", "mikael@example.com"),
    "Quarterly review": ("Ana Beltrán", "ana@example.com"),
}

DEMO_AGENDA = (
    "Agenda\n\n"
    "1. What went out on Friday, and what it broke\n"
    "2. The migration that ran twice - see "
    '<a href="https://example.com/releases/14-02">the release notes</a>\n'
    "3. Anything for the retro\n\n"
    "Dial in a couple of minutes early if you can."
)


def demo_midnight():
    return datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)


def demo_graph_time(when):
    """A local moment written the way Graph writes one: UTC, seven digits."""
    return {"dateTime": when.astimezone(timezone.utc)
                            .strftime("%Y-%m-%dT%H:%M:%S.0000000"),
            "timeZone": "UTC"}


def demo_event(index, start, end, subject, where, online, response, shown,
               repeats, all_day=False):
    """One fixture, in the shape Graph sends, so it goes through event_row().

    Built as Graph's own shape rather than as a finished row: the UTC-to-local
    conversion and the exclusive end are exactly the parts worth exercising,
    and a fixture that skipped them would prove the layout works on data the
    real thing never sends.
    """
    who, address = DEMO_ORGANISERS.get(subject, ("Ana Beltrán", "ana@example.com"))
    return {
        "id": "demo-event-%d" % index,
        "subject": subject,
        "bodyPreview": "Agenda 1. What went out on Friday, and what it broke",
        "start": demo_graph_time(start),
        "end": demo_graph_time(end),
        "isAllDay": all_day,
        "isCancelled": False,
        "isOrganizer": response == "organizer",
        "location": {"displayName": where},
        "organizer": {"emailAddress": {"name": who, "address": address}},
        "responseStatus": {"response": {"accepted": "accepted", "pending": "notResponded",
                                        "tentative": "tentativelyAccepted",
                                        "declined": "declined", "organizer": "organizer",
                                        "none": "none"}.get(response, "none")},
        "responseRequested": response != "none",
        "showAs": shown,
        "type": "occurrence" if repeats else "singleInstance",
        "seriesMasterId": "demo-series-%s" % index if repeats else "",
        "isOnlineMeeting": online,
        "onlineMeeting": ({"joinUrl": "https://teams.microsoft.com/l/meetup-join/demo"}
                          if online else None),
        "importance": "normal",
        "sensitivity": "normal",
        "categories": [],
        "hasAttachments": False,
    }


def demo_graph_events():
    """Every fixture, in Graph's shape, keyed by nothing - order is the id."""
    midnight = demo_midnight()
    events = []
    for index, row in enumerate(DEMO_EVENTS):
        day, at, minutes, subject, where, online, response, shown, repeats = row
        hour, minute = (int(part) for part in at.split(":"))
        start = midnight + timedelta(days=day, hours=hour, minutes=minute)
        events.append(demo_event(index, start, start + timedelta(minutes=minutes),
                                 subject, where, online, response, shown, repeats))
    for offset, row in enumerate(DEMO_ALL_DAY):
        day, length, subject, shown = row
        start = midnight + timedelta(days=day)
        events.append(demo_event(len(DEMO_EVENTS) + offset, start,
                                 start + timedelta(days=length), subject, "", False,
                                 "none", shown, False, all_day=True))
    return events


def demo_events(start, end):
    """The fixtures touching a range, shaped and sorted as the real ones are."""
    rows = []
    for event in demo_graph_events():
        began = graph_moment(event["start"])
        ended = graph_moment(event["end"])
        if not began or ended <= start or began >= end:
            continue
        rows.append(event_row(event))
    rows.sort(key=lambda row: (row["startDate"], not row["allDay"], row["when"]))
    return rows


def demo_event_detail(event_id):
    """One fixture in full, with an agenda and a guest list to lay out."""
    wanted = str(event_id or "")
    events = demo_graph_events()
    found = None
    for event in events:
        if event["id"] == wanted:
            found = event
            break
    if not found:
        # Keyed by the id that was asked for, so that a meeting the demo has
        # just "created" opens as itself rather than as whichever fixture
        # happened to stand in for it.
        found = dict(events[1], id=wanted or events[1]["id"])
    return event_row(dict(found, **{
        "body": {"contentType": "html", "content": DEMO_AGENDA},
        "allowNewTimeProposals": True,
        "attendees": [
            {"emailAddress": {"name": "Ana Beltrán", "address": "ana@example.com"},
             "type": "required", "status": {"response": "organizer"}},
            {"emailAddress": {"name": "You", "address": "you@example.com"},
             "type": "required", "status": {"response": "notResponded"}},
            {"emailAddress": {"name": "Priya Raman", "address": "priya@example.com"},
             "type": "required", "status": {"response": "accepted"}},
            {"emailAddress": {"name": "Tomás Lindqvist", "address": "tomas@example.com"},
             "type": "required", "status": {"response": "tentativelyAccepted"}},
            {"emailAddress": {"name": "Yuki Tanaka", "address": "yuki@example.com"},
             "type": "optional", "status": {"response": "declined"}},
            {"emailAddress": {"name": "Room 3.14", "address": "room314@example.com"},
             "type": "resource", "status": {"response": "accepted"}},
        ],
    }), detailed=True)


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
    start.add_argument("--presence", action="store_true",
                       help="also ask for Presence.ReadWrite, for setting your own presence "
                            "(admin consent)")
    start.add_argument("--calendar", action="store_true",
                       help="also ask for Calendars.Read, for the calendar")
    start.add_argument("--calendar-write", action="store_true",
                       help="ask for Calendars.ReadWrite instead, for answering invitations "
                            "and booking meetings")
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

    presence = with_account("presence", "set the presence Teams shows for you")
    presence.add_argument("--state", required=True,
                          help="available, busy, dnd, brb, away, offline - or auto to hand it "
                               "back to Teams")
    presence.add_argument("--for", dest="duration", default="",
                          help="how long, as an ISO 8601 duration: PT8H, P1D. Graph applies its "
                               "own expiry when this is left out")
    presence.add_argument("--demo", action="store_true")
    presence.set_defaults(func=cmd_presence)

    sub.add_parser("presence-states", help="the presences that can be set") \
        .set_defaults(func=cmd_presence_states)

    hold = with_account("hold-presence", "keep a presence session open, so a presence can show")
    hold.add_argument("--state", default="available",
                      help="available, away, or none to let the session go")
    hold.add_argument("--for", dest="duration", default="PT1H",
                      help="how long the session lasts before it needs renewing (PT5M to PT4H)")
    hold.add_argument("--demo", action="store_true")
    hold.set_defaults(func=cmd_hold_presence)

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
    send.add_argument("--text", help="the message; --stdin is what the window uses")
    send.add_argument("--stdin", action="store_true",
                      help='read {"text": "..."} from stdin, keeping it out of argv')
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

    calendar = with_account("calendar", "the events in a range of days")
    calendar.add_argument("--from", dest="since", required=True,
                          help="the first local day, as YYYY-MM-DD")
    calendar.add_argument("--days", type=int, default=1,
                          help="how many days from there (1-%d)" % CALENDAR_DAYS_CAP)
    calendar.add_argument("--demo", action="store_true")
    calendar.set_defaults(func=cmd_calendar)

    event = with_account("event", "one event in full, with its guest list")
    event.add_argument("--event", required=True, help="event id from `calendar`")
    event.add_argument("--demo", action="store_true")
    event.set_defaults(func=cmd_event)

    rsvp = with_account("rsvp", "answer an invitation")
    rsvp.add_argument("--event", required=True, help="event id from `calendar`")
    rsvp.add_argument("--response", required=True, help="accept, tentative or decline")
    rsvp.add_argument("--comment", default="", help="a line for the organiser; --stdin is "
                                                    "what the window uses")
    rsvp.add_argument("--stdin", action="store_true",
                      help='read {"comment": "..."} from stdin, keeping it out of argv')
    rsvp.add_argument("--silent", action="store_true",
                      help="answer without sending the organiser a reply")
    rsvp.add_argument("--demo", action="store_true")
    rsvp.set_defaults(func=cmd_rsvp)

    new_event = with_account("new-event", "put a meeting on the calendar")
    new_event.add_argument("--stdin", action="store_true",
                           help='read {"subject", "start", "end", "allDay", "attendees", '
                                '"text", "where", "online", "showAs"} from stdin')
    new_event.add_argument("--demo", action="store_true")
    new_event.set_defaults(func=cmd_new_event)

    cancel = with_account("cancel-event", "call off a meeting, or take it off your calendar")
    cancel.add_argument("--event", required=True, help="event id from `calendar`")
    cancel.add_argument("--comment", default="", help="what to tell the people invited")
    cancel.add_argument("--stdin", action="store_true",
                        help='read {"comment": "..."} from stdin')
    cancel.add_argument("--demo", action="store_true")
    cancel.set_defaults(func=cmd_cancel_event)

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
