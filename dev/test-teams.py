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
