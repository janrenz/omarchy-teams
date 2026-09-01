#!/usr/bin/env python3
"""Tests for teams.py: the parsing, and the rules about what may be fetched.

Run with `python3 dev/test-teams.py`. No network and no account: everything
here is either a pure function or the real code with the network answering to
order, the way the Office 365 plugin tests its own helper.

What is deliberately covered: the shapes Teams actually sends (which are not
the shapes the documentation suggests), and every place a decision is made
about permission or about which host gets the token. Those are the two classes
of bug that are invisible until they matter.
"""

import base64
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))
import teams  # noqa: E402


class Emitted(Exception):
    """teams.out() reached, carrying what it was about to print."""

    def __init__(self, payload):
        super().__init__("emitted")
        self.payload = payload


def capture(function, *args, **kwargs):
    """Run a cmd_* function and return the JSON it tried to print."""
    original = teams.out
    teams.out = lambda payload: (_ for _ in ()).throw(Emitted(payload))
    try:
        function(*args, **kwargs)
    except Emitted as emitted:
        return emitted.payload
    finally:
        teams.out = original
    raise AssertionError("nothing was emitted")


class Args:
    account = "work"
    demo = False


# --------------------------------------------------------------------------


class PlainText(unittest.TestCase):
    """Turning a Teams message body into the words in it."""

    def test_an_emoji_becomes_the_character_its_alt_already_holds(self):
        # This is the shape Teams really sends. There is no id-to-emoji table
        # to keep because the character is right there in the alt.
        body = '<p>Cake <emoji id="smile" alt="\U0001F642" title="Grinsen"></emoji> today</p>'
        self.assertEqual(teams.plain_text(body), "Cake \U0001F642 today")

    def test_several_emoji_in_one_line_all_survive(self):
        body = ('<p><emoji id="a" alt="\U0001F60B"></emoji>'
                'and<emoji id="b" alt="\U0001F60A"></emoji></p>')
        self.assertEqual(teams.plain_text(body), "\U0001F60Band\U0001F60A")

    def test_an_emoji_with_no_alt_does_not_leave_a_tag_behind(self):
        self.assertEqual(teams.plain_text('<p>hi <emoji id="x"></emoji></p>'), "hi")

    def test_paragraphs_and_breaks_become_lines(self):
        self.assertEqual(teams.plain_text("<p>one</p><p>two</p>"), "one\ntwo")
        self.assertEqual(teams.plain_text("a<br>b"), "a\nb")

    def test_entities_are_decoded(self):
        self.assertEqual(teams.plain_text("a&nbsp;&amp;&nbsp;b"), "a & b")
        self.assertEqual(teams.plain_text("&lt;script&gt;"), "<script>")

    def test_script_and_style_go_with_their_contents(self):
        self.assertEqual(teams.plain_text("a<script>steal()</script>b"), "ab")
        self.assertEqual(teams.plain_text("a<style>p{}</style>b"), "ab")

    def test_nothing_in_nothing_out(self):
        self.assertEqual(teams.plain_text(None), "")
        self.assertEqual(teams.plain_text(""), "")

    def test_a_link_keeps_its_words_and_loses_its_tag(self):
        body = '<p>see <a href="https://x.y/plan">our roadmap</a> today</p>'
        self.assertEqual(teams.plain_text(body), "see our roadmap today")


class MessageLinks(unittest.TestCase):
    """Where the links in a message are, once it is text.

    The composer's link button puts the address in the href and nowhere in the
    words, so stripping the tag left "our roadmap" with nothing behind it.
    """

    def spans(self, body):
        text, links = teams.text_and_links(body)
        return text, [(text[l["start"]:l["end"]], l["href"]) for l in links]

    def test_the_span_covers_the_words_that_were_the_link(self):
        text, spans = self.spans('<p>see <a href="https://x.y/plan">our roadmap</a> today</p>')
        self.assertEqual(text, "see our roadmap today")
        self.assertEqual(spans, [("our roadmap", "https://x.y/plan")])

    def test_offsets_survive_the_paragraphs_and_the_entities(self):
        # Everything before the link changes length on the way through: the
        # entity shrinks, the paragraph becomes a newline, the tag goes.
        text, spans = self.spans(
            '<p>a&nbsp;&amp;&nbsp;b</p><p><b>x</b> <a href="https://x.y">go</a></p>')
        self.assertEqual(text, "a & b\nx go")
        self.assertEqual(spans, [("go", "https://x.y")])

    def test_a_pasted_url_is_its_own_words(self):
        text, spans = self.spans('<p><a href="https://x.y/a">https://x.y/a</a></p>')
        self.assertEqual(text, "https://x.y/a")
        self.assertEqual(spans, [("https://x.y/a", "https://x.y/a")])

    def test_a_mailto_is_kept(self):
        text, spans = self.spans('<div>ask <a href="mailto:jan@x.de">Jan</a></div>')
        self.assertEqual(spans, [("Jan", "mailto:jan@x.de")])

    def test_something_that_runs_is_not_a_link_and_keeps_its_words(self):
        for href in ("javascript:alert(1)", "data:text/html,x", "vbscript:x", "file:///etc/passwd"):
            text, spans = self.spans('<p><a href="%s">click me</a></p>' % href)
            self.assertEqual(text, "click me")
            self.assertEqual(spans, [])

    def test_an_ampersand_in_the_query_is_decoded_like_the_rest(self):
        _, spans = self.spans('<a href="https://x.y?a=1&amp;b=2">q</a>')
        self.assertEqual(spans, [("q", "https://x.y?a=1&b=2")])

    def test_markup_inside_the_words_is_stripped_like_any_other(self):
        text, spans = self.spans('<a href="https://x.y"><b>bold</b> link</a>')
        self.assertEqual(text, "bold link")
        self.assertEqual(spans, [("bold link", "https://x.y")])

    def test_an_emoji_inside_a_link_survives_and_the_span_still_fits(self):
        text, spans = self.spans(
            '<a href="https://x.y">go <emoji id="s" alt="\U0001F642"></emoji></a>')
        self.assertEqual(text, "go \U0001F642")
        self.assertEqual(spans, [("go \U0001F642", "https://x.y")])

    def test_several_links_come_back_in_order(self):
        text, spans = self.spans(
            '<p><a href="https://a.b">one</a> and <a href="https://c.d">two</a></p>')
        self.assertEqual(text, "one and two")
        self.assertEqual(spans, [("one", "https://a.b"), ("two", "https://c.d")])

    def test_a_message_cannot_forge_a_span_of_its_own(self):
        # The marks are C0 controls that Teams does not send; one that arrives
        # anyway is removed before the anchors are marked, so it cannot make
        # words into a link that was never one.
        text, spans = self.spans("\x00https://evil.example\x01trusted\x02")
        self.assertEqual(text, "https://evil.exampletrusted")
        self.assertEqual(spans, [])

    def test_a_link_with_no_href_is_only_words(self):
        text, spans = self.spans("<p>a <a>b</a> c</p>")
        self.assertEqual(text, "a b c")
        self.assertEqual(spans, [])

    def test_a_message_with_no_links_says_so(self):
        self.assertEqual(teams.text_and_links("<p>nothing here</p>"), ("nothing here", []))

    def test_a_message_row_carries_its_links(self):
        row = teams.message_row({
            "id": "1", "createdDateTime": "2026-09-01T08:00:00Z",
            "from": {"user": {"id": "u", "displayName": "Jan"}},
            "body": {"content": '<p>see <a href="https://x.y">this</a></p>'},
        })
        self.assertEqual(row["text"], "see this")
        self.assertEqual(row["links"], [{"href": "https://x.y", "start": 4, "end": 8}])


class MessageImages(unittest.TestCase):
    """Which pictures in a message are ours to fetch."""

    GRAPH_IMG = ('<img alt="Media" src="https://graph.microsoft.com/v1.0/chats/x/messages/1'
                 '/hostedContents/abc/$value" width="187.5" height="250">')

    def test_a_graph_hosted_image_is_kept_with_its_size(self):
        images = teams.message_images(self.GRAPH_IMG)
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0]["width"], 187)   # 187.5 truncated, not crashed on
        self.assertEqual(images[0]["height"], 250)
        self.assertEqual(images[0]["alt"], "Media")

    def test_dimensions_may_arrive_in_a_style_instead(self):
        # The other shape Teams sends, seen on the same account as the above.
        markup = ('<div><img src="https://graph.microsoft.com/v1.0/chats/x/messages/1'
                  '/hostedContents/abc/$value" style="width:1448px; height:2573px"></div>')
        images = teams.message_images(markup)
        self.assertEqual((images[0]["width"], images[0]["height"]), (1448, 2573))

    def test_an_image_from_anywhere_else_is_dropped(self):
        # Not merely unfetched - never offered. A remote image in a message is
        # a tracking pixel, and this plugin does not load one.
        self.assertEqual(teams.message_images('<img src="https://evil.example/pixel.gif">'), [])

    def test_a_lookalike_host_is_not_graph(self):
        for host in ("https://graph.microsoft.com.evil.example/x",
                     "https://notgraph.microsoft.com/x",
                     "http://graph.microsoft.com/x"):
            self.assertEqual(teams.message_images('<img src="%s">' % host), [],
                             "%s should not pass as Graph" % host)

    def test_a_missing_size_is_zero_rather_than_a_crash(self):
        images = teams.message_images(
            '<img src="https://graph.microsoft.com/v1.0/a/$value">')
        self.assertEqual((images[0]["width"], images[0]["height"]), (0, 0))

    def test_the_aria_label_stands_in_for_a_missing_alt(self):
        images = teams.message_images(
            '<img aria-label="hat Kontextmenü" src="https://graph.microsoft.com/v1.0/a/$value">')
        self.assertEqual(images[0]["alt"], "hat Kontextmenü")


class ImageHostGuard(unittest.TestCase):
    """The token goes to Graph and nowhere else.

    The URL being fetched comes out of a message somebody else wrote. Sending
    an Authorization header to an origin they chose would hand them a token
    that can read this account, so the host is checked rather than trusted.
    """

    def test_a_foreign_host_is_refused_before_any_request(self):
        reached = []
        original = teams.urllib.request.urlopen
        teams.urllib.request.urlopen = lambda *a, **k: reached.append(a) or None
        try:
            with self.assertRaises(teams.AccountError) as caught:
                teams.fetch_bytes("https://evil.example/steal", "TOKEN")
        finally:
            teams.urllib.request.urlopen = original
        self.assertEqual(caught.exception.code, "bad_image_host")
        self.assertEqual(reached, [], "a request was made to a host that should have been refused")

    def test_plain_http_is_refused_even_on_the_right_host(self):
        with self.assertRaises(teams.AccountError):
            teams.fetch_bytes("http://graph.microsoft.com/v1.0/a/$value", "TOKEN")


class Scopes(unittest.TestCase):
    """What a sign-in is allowed to do is read from what was granted."""

    def test_channels_need_their_own_grant(self):
        self.assertTrue(teams.has_channels({"scopes": "Chat.Read ChannelMessage.Read.All"}))
        self.assertFalse(teams.has_channels({"scopes": "Chat.Read ChatMessage.Send"}))

    def test_marking_read_needs_readwrite(self):
        # markChatReadForUser refuses Chat.Read: marking read is a write.
        self.assertTrue(teams.can_mark_read({"scopes": "Chat.ReadWrite"}))
        self.assertFalse(teams.can_mark_read({"scopes": "Chat.Read ChatMessage.Send"}))

    def test_a_sign_in_from_before_scopes_were_recorded_may_do_neither(self):
        # Unknown has to mean no: offering a button that 403s is worse than
        # not offering it, and the window says which sign-in would fix it.
        for account in ({}, None, {"scopes": ""}):
            self.assertFalse(teams.has_channels(account))
            self.assertFalse(teams.can_mark_read(account))

    def test_the_asked_for_scopes_differ_only_by_the_channel_ones(self):
        chats = set(teams.SCOPES_CHATS.split())
        channels = set(teams.SCOPES_CHANNELS.split())
        self.assertTrue(chats < channels)
        self.assertIn("Chat.ReadWrite", chats)
        self.assertEqual(channels - chats, {
            "Team.ReadBasic.All", "Channel.ReadBasic.All",
            "ChannelMessage.Read.All", "ChannelMessage.Send",
        })


class TokenClaims(unittest.TestCase):
    def make(self, payload):
        raw = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
        return "header." + raw + ".signature"

    def test_the_ids_graph_wants_echoed_back_are_read_out(self):
        token = self.make({"oid": "user-1", "tid": "tenant-1"})
        self.assertEqual(teams.token_claims(token).get("oid"), "user-1")
        self.assertEqual(teams.token_claims(token).get("tid"), "tenant-1")

    def test_padding_that_base64_needs_is_added(self):
        # JWT segments arrive without it; decoding must not depend on luck.
        for payload in ({"a": 1}, {"ab": 2}, {"abc": 3}, {"abcd": 4}):
            self.assertEqual(teams.token_claims(self.make(payload)), payload)

    def test_rubbish_is_empty_rather_than_an_exception(self):
        for bad in ("", "not-a-token", "a.b", "a.!!!.c"):
            self.assertEqual(teams.token_claims(bad), {})


class MarkRead(unittest.TestCase):
    def run_mark(self, scopes, responses=None):
        self.calls = []
        queue = list(responses or [(204, {})])

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return queue.pop(0) if queue else (204, {})

        token = "h." + base64.urlsafe_b64encode(
            json.dumps({"oid": "user-1", "tid": "tenant-1"}).encode()).decode().rstrip("=") + ".s"

        args = Args()
        args.chat = "19:abc@thread.v2"
        patched = {
            "read_json": lambda *a, **k: {"scopes": scopes},
            "access_token": lambda alias, account: (token, account),
            "http": http,
        }
        original = {name: getattr(teams, name) for name in patched}
        for name, stub in patched.items():
            setattr(teams, name, stub)
        try:
            return capture(teams.cmd_mark_read, args)
        finally:
            for name, value in original.items():
                setattr(teams, name, value)

    def test_it_posts_to_the_chat_being_read(self):
        result = self.run_mark("Chat.ReadWrite")
        self.assertTrue(result["ok"])
        self.assertTrue(self.calls[0]["url"].endswith("/markChatReadForUser"))
        self.assertEqual(self.calls[0]["body"], {"user": {"id": "user-1", "tenantId": "tenant-1"}})

    def test_the_chat_id_is_escaped_into_the_path(self):
        self.run_mark("Chat.ReadWrite")
        self.assertIn("19%3Aabc%40thread.v2", self.calls[0]["url"])

    def test_without_the_write_scope_nothing_is_attempted(self):
        result = self.run_mark("Chat.Read ChatMessage.Send")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "mark_read_permission_required")
        self.assertEqual(self.calls, [], "a request was made that was known to be refused")

    def test_a_403_from_the_server_says_the_same_thing(self):
        # The tenant can withhold a scope the token claims to carry.
        result = self.run_mark("Chat.ReadWrite",
                               responses=[(403, {"error": {"message": "Missing scope"}})])
        self.assertEqual(result["error"]["code"], "mark_read_permission_required")


class PendingSignIn(unittest.TestCase):
    """A sign-in left in flight, and one that was overtaken."""

    def run_status(self, pending, account=None):
        import types
        args = types.SimpleNamespace(account="work")

        def read_json(path, default=None):
            return pending if path.endswith(".pending.json") else account

        removed = []
        original = (teams.read_json, teams.os.remove)
        teams.read_json = read_json
        teams.os.remove = lambda path: removed.append(path)
        try:
            return capture(teams.cmd_login_status, args), removed
        finally:
            teams.read_json, teams.os.remove = original

    def test_nothing_in_flight_is_reported_as_nothing(self):
        result, _ = self.run_status(None)
        self.assertFalse(result["pending"])

    def test_one_in_flight_hands_back_the_code_to_show(self):
        # What makes resuming possible at all: Microsoft gives the user code
        # once, so it has to have been kept.
        result, _ = self.run_status(
            {"expires_at": teams.time.time() + 600, "user_code": "ABC-123",
             "verification_uri": "https://microsoft.com/devicelogin"})
        self.assertTrue(result["pending"])
        self.assertEqual(result["userCode"], "ABC-123")

    def test_an_expired_one_is_not_in_flight(self):
        result, _ = self.run_status({"expires_at": teams.time.time() - 1, "user_code": "OLD"})
        self.assertFalse(result["pending"])

    def test_one_overtaken_by_a_sign_in_elsewhere_is_cleared(self):
        # This shipped: a pending file outlived a sign-in finished by another
        # route, and the window put "still waiting, enter this code" over a
        # mailbox that was already signed in.
        result, removed = self.run_status(
            {"expires_at": teams.time.time() + 600, "user_code": "STALE"},
            account={"refresh_token": "r", "scopes": "Chat.ReadWrite"})
        self.assertFalse(result["pending"])
        self.assertTrue(result.get("superseded"))
        self.assertEqual(len(removed), 1, "the stale pending file should have been removed")


class ChatTitles(unittest.TestCase):
    def test_a_topic_wins(self):
        self.assertEqual(teams.chat_title({"topic": "Platform team", "members": []}, "me"),
                         "Platform team")

    def test_a_one_to_one_is_named_after_the_other_person(self):
        chat = {"topic": "", "members": [
            {"userId": "me", "displayName": "Jan"},
            {"userId": "p", "displayName": "Priya"}]}
        self.assertEqual(teams.chat_title(chat, "me"), "Priya")

    def test_a_group_lists_a_few_and_counts_the_rest(self):
        members = [{"userId": "me", "displayName": "Jan"}]
        members += [{"userId": str(n), "displayName": "P%d" % n} for n in range(5)]
        self.assertEqual(teams.chat_title({"topic": "", "members": members}, "me"),
                         "P0, P1, P2 and 2 others")

    def test_a_chat_with_only_you_says_so_rather_than_your_own_name(self):
        chat = {"topic": "", "members": [{"userId": "me", "displayName": "Jan"}]}
        self.assertEqual(teams.chat_title(chat, "me"), "(no one else here)")


class SavingSettings(unittest.TestCase):
    """Writing the widget's entry back into shell.json.

    This one edits the file the whole shell reads, so the tests are about what
    it must refuse as much as what it must do.
    """

    def setUp(self):
        import tempfile, importlib.util
        spec = importlib.util.spec_from_file_location(
            "teamsconfig",
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "config.py"))
        self.config = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.config)
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "shell.json")

    def write(self, layout):
        with open(self.path, "w", encoding="utf-8") as handle:
            json.dump({"version": 1, "bar": {"layout": layout}}, handle)

    def save(self, updates, plugin_id="janrenz.omarchy.teams"):
        import types
        args = types.SimpleNamespace(plugin_id=plugin_id, updates=json.dumps(updates),
                                     shell_json=self.path, listing=False)
        original = self.config.out
        self.config.out = lambda payload: (_ for _ in ()).throw(Emitted(payload))
        try:
            self.config.save_settings(args)
        except Emitted as emitted:
            return emitted.payload
        finally:
            self.config.out = original
        raise AssertionError("nothing was emitted")

    def read_back(self):
        with open(self.path, encoding="utf-8") as handle:
            return json.load(handle)

    def test_a_value_is_written_into_the_entry(self):
        self.write({"right": [{"id": "janrenz.omarchy.teams", "account": "work"}]})
        result = self.save({"density": "roomy"})
        self.assertTrue(result["ok"])
        self.assertEqual(self.read_back()["bar"]["layout"]["right"][0]["density"], "roomy")

    def test_the_rest_of_the_file_is_left_alone(self):
        # It is the whole shell's config, not this plugin's.
        self.write({"left": [{"id": "omarchy.clock", "format": "HH:mm"}],
                    "right": [{"id": "janrenz.omarchy.teams"}]})
        self.save({"chats": 30})
        after = self.read_back()
        self.assertEqual(after["bar"]["layout"]["left"][0], {"id": "omarchy.clock", "format": "HH:mm"})
        self.assertEqual(after["version"], 1)

    def test_an_empty_string_removes_the_key(self):
        # Clearing a field puts the plugin's default back rather than pinning
        # an empty value that would read as a deliberate choice.
        self.write({"right": [{"id": "janrenz.omarchy.teams", "density": "roomy"}]})
        self.save({"density": ""})
        self.assertNotIn("density", self.read_back()["bar"]["layout"]["right"][0])

    def test_the_id_can_never_be_rewritten(self):
        self.write({"right": [{"id": "janrenz.omarchy.teams"}]})
        self.save({"id": "something.else", "chats": 5})
        self.assertEqual(self.read_back()["bar"]["layout"]["right"][0]["id"],
                         "janrenz.omarchy.teams")

    def test_a_widget_that_is_not_there_is_refused(self):
        self.write({"right": [{"id": "omarchy.clock"}]})
        result = self.save({"chats": 5})
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "not_found")

    def test_two_of_them_is_refused_rather_than_guessed_at(self):
        self.write({"left": [{"id": "janrenz.omarchy.teams"}],
                    "right": [{"id": "janrenz.omarchy.teams"}]})
        result = self.save({"chats": 5})
        self.assertEqual(result["error"]["code"], "ambiguous")

    def test_a_broken_config_is_not_overwritten(self):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        result = self.save({"chats": 5})
        self.assertEqual(result["error"]["code"], "bad_config")
        with open(self.path, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "{not json", "the file should be untouched")

    def test_nonsense_in_the_patch_is_refused_before_the_file_is_opened(self):
        self.write({"right": [{"id": "janrenz.omarchy.teams"}]})
        import types
        args = types.SimpleNamespace(plugin_id="janrenz.omarchy.teams", updates="{not json",
                                     shell_json=self.path, listing=False)
        original = self.config.out
        self.config.out = lambda payload: (_ for _ in ()).throw(Emitted(payload))
        try:
            self.config.save_settings(args)
        except Emitted as emitted:
            self.assertEqual(emitted.payload["error"]["code"], "bad_json")
        finally:
            self.config.out = original


class FriendlyErrors(unittest.TestCase):
    """Graph answers some refusals with a code and no sentence."""

    def test_a_bare_code_becomes_a_sentence(self):
        # This is what a real refusal looked like on screen: "AclCheckFailed",
        # which tells the reader nothing they can do anything about.
        self.assertIn("does not allow", teams.friendly("AclCheckFailed"))

    def test_a_code_inside_a_longer_message_is_still_recognised(self):
        said = teams.friendly("Failed with AclCheckFailed for the request")
        self.assertIn("does not allow", said)
        # ...and the original is kept, because it is what to search for.
        self.assertIn("AclCheckFailed", said)

    def test_a_message_that_is_already_a_sentence_is_left_alone(self):
        self.assertEqual(teams.friendly("The mailbox is full."), "The mailbox is full.")

    def test_nothing_still_says_something(self):
        self.assertEqual(teams.friendly(""), "Something went wrong")
        self.assertEqual(teams.friendly(None), "Something went wrong")


class Reactions(unittest.TestCase):
    """Counting them for display, and sending one."""

    def message(self, *pairs):
        return {"reactions": [
            {"reactionType": emoji, "displayName": "Like",
             "user": {"user": {"id": who}}}
            for emoji, who in pairs]}

    def test_the_same_emoji_from_several_people_is_one_chip(self):
        rows = teams.reaction_summary(self.message(("👍", "a"), ("👍", "b")), "me")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["count"], 2)

    def test_it_knows_whether_you_are_one_of_them(self):
        # This is what makes the chip a toggle rather than a label.
        mine = teams.reaction_summary(self.message(("👍", "me")), "me")
        self.assertTrue(mine[0]["mine"])
        theirs = teams.reaction_summary(self.message(("👍", "someone")), "me")
        self.assertFalse(theirs[0]["mine"])

    def test_the_busiest_reaction_comes_first(self):
        rows = teams.reaction_summary(
            self.message(("😂", "a"), ("👍", "b"), ("👍", "c")), "me")
        self.assertEqual(rows[0]["emoji"], "👍")
        self.assertEqual([r["count"] for r in rows], [2, 1])

    def test_a_tie_is_ordered_the_same_way_every_time(self):
        # Otherwise chips shuffle between fetches while nothing has changed.
        first = teams.reaction_summary(self.message(("😂", "a"), ("👍", "b")), "me")
        second = teams.reaction_summary(self.message(("👍", "b"), ("😂", "a")), "me")
        self.assertEqual([r["emoji"] for r in first], [r["emoji"] for r in second])

    def test_no_reactions_is_an_empty_list(self):
        self.assertEqual(teams.reaction_summary({}, "me"), [])
        self.assertEqual(teams.reaction_summary({"reactions": None}, "me"), [])

    def test_an_unknown_user_does_not_count_as_you(self):
        rows = teams.reaction_summary(self.message(("👍", "")), "")
        self.assertFalse(rows[0]["mine"])


class Reacting(unittest.TestCase):
    def run_react(self, emoji="👍", remove=False, chat="19:abc", team="", channel="",
                  responses=None):
        import types
        self.calls = []
        queue = list(responses or [(204, {})])

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return queue.pop(0) if queue else (204, {})

        args = types.SimpleNamespace(account="work", message="msg-1", emoji=emoji,
                                     chat=chat, team=team, channel=channel, remove=remove)
        patched = {
            "read_json": lambda *a, **k: {"scopes": "Chat.ReadWrite"},
            "access_token": lambda alias, account: ("token", account),
            "http": http,
        }
        original = {name: getattr(teams, name) for name in patched}
        for name, stub in patched.items():
            setattr(teams, name, stub)
        try:
            return capture(teams.cmd_react, args)
        finally:
            for name, value in original.items():
                setattr(teams, name, value)

    def test_it_posts_to_setReaction_under_chats_not_me_chats(self):
        # /me/chats answers 404 "Requested API is not supported" for this;
        # /chats works. Getting this wrong is silent until someone reacts.
        result = self.run_react()
        self.assertTrue(result["ok"])
        url = self.calls[0]["url"]
        self.assertIn("/chats/", url)
        self.assertNotIn("/me/chats/", url)
        self.assertTrue(url.endswith("/setReaction"))

    def test_removing_posts_to_unsetReaction(self):
        self.run_react(remove=True)
        self.assertTrue(self.calls[0]["url"].endswith("/unsetReaction"))

    def test_the_emoji_itself_is_the_reaction_type(self):
        # Graph takes the character, not a name, and hands the same back.
        self.run_react()
        self.assertEqual(self.calls[0]["body"], {"reactionType": "👍"})

    def test_a_channel_message_goes_to_its_team_and_channel(self):
        self.run_react(chat="", team="t1", channel="c1")
        self.assertIn("/teams/t1/channels/c1/messages/", self.calls[0]["url"])

    def test_an_emoji_teams_does_not_take_is_refused_before_the_request(self):
        result = self.run_react(emoji="🦄")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "bad_reaction")
        self.assertEqual(self.calls, [], "nothing should have been sent")

    def test_every_offered_reaction_is_one_the_sender_accepts(self):
        # The picker and the sender must agree, or a chip does nothing.
        for emoji, _ in teams.REACTIONS:
            self.assertIn(emoji, teams.REACTION_EMOJI)
            result = self.run_react(emoji=emoji)
            self.assertTrue(result["ok"], "%s should be sendable" % emoji)


class Aliases(unittest.TestCase):
    """An account name becomes a filename, so it is checked."""

    def test_ordinary_names_are_fine(self):
        for alias in ("work", "german-uds", "a.b_c", "A1"):
            self.assertIsNone(teams.alias_problem(alias))

    def test_anything_that_could_escape_the_directory_is_refused(self):
        for alias in ("", "..", ".", "a/b", "../etc/passwd", "a b", "a\x00b"):
            self.assertIsNotNone(teams.alias_problem(alias), "%r should be refused" % alias)

    def test_state_path_refuses_rather_than_building_the_path(self):
        with self.assertRaises(teams.AccountError):
            teams.state_path("../escape")


if __name__ == "__main__":
    unittest.main(verbosity=2)
