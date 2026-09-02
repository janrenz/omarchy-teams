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
import tempfile
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


class MessageAttachments(unittest.TestCase):
    """A file on a message, which is the whole message when nothing was typed."""

    FILE = {"id": "e545b93a", "contentType": "reference", "name": "memo.pdf",
            "contentUrl": "https://buds365-my.sharepoint.com/personal/x/memo.pdf"}

    def test_a_sent_file_is_the_only_thing_the_message_says(self):
        # The shape Teams posts and this helper writes: an <attachment> tag,
        # which strips to nothing, and the file itself alongside it.
        row = teams.message_row({
            "id": "1", "createdDateTime": "2026-09-02T09:31:48Z",
            "from": {"user": {"id": "u", "displayName": "Jan"}},
            "body": {"content": '<attachment id="e545b93a"></attachment>'},
            "attachments": [self.FILE],
        })
        self.assertEqual(row["text"], "")
        self.assertEqual(row["attachments"],
                         [{"id": "e545b93a", "name": "memo.pdf", "url": self.FILE["contentUrl"]}])

    def test_a_comment_sent_with_a_file_keeps_both(self):
        row = teams.message_row({
            "id": "1",
            "body": {"content": 'here<br><attachment id="e545b93a"></attachment>'},
            "attachments": [self.FILE],
        })
        self.assertEqual(row["text"], "here")
        self.assertEqual(len(row["attachments"]), 1)

    def test_an_attachment_with_nowhere_to_go_is_dropped(self):
        # A card is an attachment too, and has no file behind it. So is a
        # quoted reply. Neither is something this window can open.
        for attachment in ({"contentType": "application/vnd.microsoft.card.adaptive",
                            "content": "{}"},
                           {"contentType": "messageReference", "contentUrl": None},
                           {"contentUrl": "file:///etc/passwd"},
                           {"contentUrl": "javascript:alert(1)"}):
            self.assertEqual(teams.message_attachments({"attachments": [attachment]}), [])

    def test_a_file_with_no_name_is_still_openable(self):
        rows = teams.message_attachments(
            {"attachments": [{"contentUrl": "https://x.y/z"}]})
        self.assertEqual(rows[0]["name"], "a file")

    def test_no_more_than_the_cap(self):
        many = [{"contentUrl": "https://x.y/%d" % i} for i in range(teams.ATTACHMENT_CAP + 5)]
        self.assertEqual(len(teams.message_attachments({"attachments": many})),
                         teams.ATTACHMENT_CAP)

    def test_a_chat_whose_last_message_is_a_file_does_not_preview_as_empty(self):
        # Graph hands back an empty body for one, and no attachments with it.
        self.assertEqual(teams.preview_text({"createdDateTime": "2026-09-02T09:31:48Z",
                                             "body": {"content": ""}}), "a file or a picture")
        self.assertEqual(teams.preview_text({"body": {"content": "<p>said something</p>"}}),
                         "said something")

    def test_an_empty_preview_that_is_not_a_message_says_nothing(self):
        # "X added Y to the chat" is an event, and a deleted message is a
        # deletion. Both are empty, and neither is a file.
        when = "2026-09-02T09:31:48Z"
        self.assertEqual(teams.preview_text({"createdDateTime": when,
                                             "messageType": "systemEventMessage"}), "")
        self.assertEqual(teams.preview_text({"createdDateTime": when, "isDeleted": True}), "")
        # And a chat nobody has said anything in has no preview at all.
        self.assertEqual(teams.preview_text(None), "")
        self.assertEqual(teams.preview_text({}), "")


class MessageQuotes(unittest.TestCase):
    """What a message is answering or forwarding, which Teams keeps out of the body.

    Both shapes here are the ones Graph actually sends, keys and all: the
    quoted message never appears in `body`, only an <attachment> placeholder
    that strips to nothing - so before this the reply arrived on its own.
    """

    def reply(self, preview="the thing being answered", name="Jan Renz"):
        return {"contentType": "messageReference", "contentUrl": None,
                "content": json.dumps({
                    "messageId": "1788346025582",
                    "messagePreview": preview,
                    "messageSender": {"application": None, "device": None,
                                      "user": {"userIdentityType": "aadUser",
                                               "id": "8d6ba48e", "displayName": name}}})}

    def forward(self, content="<p>the original</p>", name="Mike"):
        return {"contentType": "forwardedMessageReference", "contentUrl": None,
                "content": json.dumps({
                    "originalMessageId": "1788350393420",
                    "originalMessageContent": content,
                    "originalSentDateTime": "2026-09-02T11:59:53.42+00:00",
                    "originalMessageSender": {"user": {"id": "0de1edf6", "displayName": name}}})}

    def test_a_quote_reply_carries_who_said_it_and_what(self):
        row = teams.message_row({
            "id": "1",
            "body": {"content": '<attachment id="1788346025582"></attachment>\n<p>Already on it&nbsp;</p>'},
            "attachments": [self.reply()],
        })
        # The reply is still just the reply: the placeholder strips as before.
        self.assertEqual(row["text"], "Already on it")
        self.assertEqual(row["quotes"], [{"id": "1788346025582", "from": "Jan Renz",
                                          "text": "the thing being answered",
                                          "when": "", "forwarded": False}])

    def test_a_forward_is_flattened_the_way_a_body_is(self):
        quotes = teams.message_quotes({"attachments": [
            self.forward("<p>one</p><table><tbody><tr><td>two</td></tr></tbody></table>")]})
        self.assertEqual(len(quotes), 1)
        self.assertTrue(quotes[0]["forwarded"])
        self.assertEqual(quotes[0]["from"], "Mike")
        self.assertEqual(quotes[0]["when"], "2026-09-02T11:59:53.42+00:00")
        # Tags off, and no markup left for anything downstream to render.
        self.assertNotIn("<", quotes[0]["text"])
        self.assertIn("one", quotes[0]["text"])
        self.assertIn("two", quotes[0]["text"])

    def test_a_null_display_name_keeps_the_quote(self):
        # Graph returns displayName: null often enough to matter - on the
        # message and on the reference both. The text is the part that carries
        # the meaning, so an unnamed quote is still worth drawing.
        quotes = teams.message_quotes({"attachments": [self.reply(name=None)]})
        self.assertEqual(quotes[0]["from"], "")
        self.assertEqual(quotes[0]["text"], "the thing being answered")

    def test_a_reference_saying_nothing_at_all_is_dropped(self):
        # Neither text nor sender: a reference to something this account cannot
        # see. A row saying nothing is worse than no row.
        self.assertEqual(teams.message_quotes({"attachments": [
            {"contentType": "messageReference",
             "content": json.dumps({"messageId": "x", "messagePreview": ""})}]}), [])

    def test_content_that_is_not_json_is_skipped_rather_than_raised(self):
        for bad in ("not json at all", "", "[1, 2, 3]", None):
            self.assertEqual(teams.message_quotes({"attachments": [
                {"contentType": "messageReference", "content": bad}]}), [])

    def test_a_file_is_not_a_quote_and_a_quote_is_not_a_file(self):
        both = {"attachments": [MessageAttachments.FILE, self.reply()]}
        self.assertEqual(len(teams.message_quotes(both)), 1)
        self.assertEqual(len(teams.message_attachments(both)), 1)
        self.assertEqual(teams.message_attachments(both)[0]["name"], "memo.pdf")

    def test_a_card_is_neither(self):
        cards = {"attachments": [{"contentType": "application/vnd.microsoft.card.adaptive",
                                  "content": "{}"}]}
        self.assertEqual(teams.message_quotes(cards), [])

    def test_a_very_long_quote_is_cut_to_context(self):
        quotes = teams.message_quotes({"attachments": [self.reply("x" * 5000)]})
        self.assertEqual(len(quotes[0]["text"]), teams.QUOTE_CHARS)

    def test_no_more_than_the_cap(self):
        many = [self.reply("q%d" % i) for i in range(teams.QUOTE_CAP + 3)]
        self.assertEqual(len(teams.message_quotes({"attachments": many})), teams.QUOTE_CAP)


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

        class Reached:
            def open(self, *a, **k):
                reached.append(a)

        original = teams.IMAGE_OPENER
        teams.IMAGE_OPENER = Reached()
        try:
            with self.assertRaises(teams.AccountError) as caught:
                teams.fetch_bytes("https://evil.example/steal", "TOKEN")
        finally:
            teams.IMAGE_OPENER = original
        self.assertEqual(caught.exception.code, "bad_image_host")
        self.assertEqual(reached, [], "a request was made to a host that should have been refused")

    def test_plain_http_is_refused_even_on_the_right_host(self):
        with self.assertRaises(teams.AccountError):
            teams.fetch_bytes("http://graph.microsoft.com/v1.0/a/$value", "TOKEN")


class Redirects(unittest.TestCase):
    """The address that was checked, and the address that is fetched.

    Every host check above looks at the URL it was handed. A redirect is the
    one way that URL stops being where the request lands, and urllib follows
    one by copying the headers - Authorization included - onto the new request
    without comparing hosts.
    """

    def guard_of(self, opener):
        """The GuardedRedirects in one opener. build_opener orders its own."""
        for handler in opener.handlers:
            if isinstance(handler, teams.GuardedRedirects):
                return handler
        raise AssertionError("that opener follows redirects unguarded")

    def redirect(self, opener, from_url, to_url, method="GET"):
        request = teams.urllib.request.Request(from_url, method=method, headers={
            "User-Agent": teams.USER_AGENT,
            "Authorization": "Bearer TOKEN",
        })
        return self.guard_of(opener).redirect_request(
            request, None, 302, "Found", {}, to_url)

    def test_a_redirect_that_stays_on_graph_keeps_the_token(self):
        new = self.redirect(teams.API_OPENER,
                            "https://graph.microsoft.com/v1.0/me",
                            "https://graph.microsoft.com/v1.0/me/profile")
        self.assertEqual(new.get_header("Authorization"), "Bearer TOKEN")

    def test_a_redirect_between_the_two_known_hosts_drops_the_token(self):
        # Both are hosts this plugin addresses; only one of them is the host
        # this token was issued for. Moving between them is still moving.
        new = self.redirect(teams.API_OPENER,
                            "https://graph.microsoft.com/v1.0/me",
                            "https://login.microsoftonline.com/common")
        self.assertIsNone(new.get_header("Authorization"))

    def test_a_redirect_off_graph_is_refused(self):
        # The whole point: Graph answering "302 -> https://evil/" would
        # otherwise hand over a token that can read this mailbox.
        with self.assertRaises(teams.AccountError) as caught:
            self.redirect(teams.API_OPENER,
                          "https://graph.microsoft.com/v1.0/me",
                          "https://evil.example/steal")
        self.assertEqual(caught.exception.code, "bad_redirect")

    def test_a_redirect_down_to_http_is_refused(self):
        with self.assertRaises(teams.AccountError) as caught:
            self.redirect(teams.API_OPENER,
                          "https://graph.microsoft.com/v1.0/me",
                          "http://graph.microsoft.com/v1.0/me")
        self.assertEqual(caught.exception.code, "bad_redirect")

    def test_an_image_may_not_be_redirected_off_graph_either(self):
        with self.assertRaises(teams.AccountError) as caught:
            self.redirect(teams.IMAGE_OPENER,
                          "https://graph.microsoft.com/v1.0/a/$value",
                          "https://evil.example/pixel.png")
        self.assertEqual(caught.exception.code, "bad_redirect")

    def test_the_upload_follows_no_redirect_at_all(self):
        # This is the request that sends the user's own file.
        with self.assertRaises(teams.AccountError) as caught:
            self.redirect(teams.UPLOAD_OPENER,
                          "https://graph.microsoft.com/v1.0/me/drive/root:/x:/content",
                          "https://graph.microsoft.com/v1.0/elsewhere",
                          method="POST")
        self.assertEqual(caught.exception.code, "redirect_refused")

    def test_an_upload_goes_through_the_opener_that_refuses_them(self):
        # http() picks the opener by whether there are raw bytes to send, so
        # this is the line that decides it, tested rather than assumed.
        sent = {}

        class Fake:
            def __init__(self, name):
                self.name = name

            def open(self, request, timeout=None):
                sent["opener"] = self.name
                raise teams.urllib.error.URLError("stop here")

        api, upload = teams.API_OPENER, teams.UPLOAD_OPENER
        teams.API_OPENER, teams.UPLOAD_OPENER = Fake("api"), Fake("upload")
        try:
            teams.http(teams.GRAPH + "/me/drive/root:/x:/content", method="PUT", raw=b"x")
            self.assertEqual(sent["opener"], "upload")
            teams.http(teams.GRAPH + "/me")
            self.assertEqual(sent["opener"], "api")
        finally:
            teams.API_OPENER, teams.UPLOAD_OPENER = api, upload

    def test_the_helper_never_calls_urlopen_behind_the_openers_back(self):
        # urlopen uses the default redirect handler, which compares no hosts.
        # One call site that slips back to it undoes all of the above.
        source = open(os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "src", "teams.py"),
            encoding="utf-8").read()
        self.assertNotIn("urllib.request.urlopen(", source)


class LocalFiles(unittest.TestCase):
    """Reading the file that is about to be sent, exactly once."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.cap = teams.UPLOAD_CAP
        teams.UPLOAD_CAP = 64

    def tearDown(self):
        teams.UPLOAD_CAP = self.cap

    def write(self, name, body):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as handle:
            handle.write(body)
        return path

    def test_an_ordinary_file_is_read(self):
        self.assertEqual(teams.read_upload(self.write("a.txt", b"hello")), b"hello")

    def test_a_symlink_to_a_real_file_is_still_followed(self):
        target = self.write("real.txt", b"hello")
        link = os.path.join(self.dir, "link.txt")
        os.symlink(target, link)
        self.assertEqual(teams.read_upload(link), b"hello")

    def test_a_folder_is_not_a_file_to_send(self):
        payload = capture(lambda: teams.read_upload(self.dir))
        self.assertEqual(payload["error"]["code"], "no_file")

    def test_a_fifo_is_not_a_file_to_send(self):
        # It has a path and it is not a directory, so opening it first and
        # asking afterwards is only safe because the open cannot block.
        path = os.path.join(self.dir, "pipe")
        os.mkfifo(path)
        payload = capture(lambda: teams.read_upload(path))
        self.assertEqual(payload["error"]["code"], "no_file")

    def test_a_missing_file_says_so(self):
        payload = capture(lambda: teams.read_upload(os.path.join(self.dir, "nope")))
        self.assertEqual(payload["error"]["code"], "no_file")

    def test_an_empty_file_is_refused(self):
        payload = capture(lambda: teams.read_upload(self.write("empty", b"")))
        self.assertEqual(payload["error"]["code"], "empty_file")

    def test_a_file_over_the_cap_is_refused(self):
        payload = capture(lambda: teams.read_upload(self.write("big", b"x" * 65)))
        self.assertEqual(payload["error"]["code"], "too_large")

    def test_the_cap_is_enforced_on_what_was_read_not_on_what_was_measured(self):
        # One descriptor, but a writer elsewhere is not waiting for us.
        path = self.write("grows", b"x" * 8)
        real_fstat = os.fstat

        def small(fd):
            info = real_fstat(fd)
            with open(path, "ab") as handle:
                handle.write(b"y" * 100)
            return info

        os.fstat = small
        try:
            payload = capture(lambda: teams.read_upload(path))
        finally:
            os.fstat = real_fstat
        self.assertEqual(payload["error"]["code"], "too_large")


class Scopes(unittest.TestCase):
    """What a sign-in is allowed to do is read from what was granted."""

    def test_channels_need_their_own_grant(self):
        self.assertTrue(teams.has_channels({"scopes": "Chat.Read ChannelMessage.Read.All"}))
        self.assertFalse(teams.has_channels({"scopes": "Chat.Read ChatMessage.Send"}))

    def test_marking_read_needs_readwrite(self):
        # markChatReadForUser refuses Chat.Read: marking read is a write.
        self.assertTrue(teams.can_mark_read({"scopes": "Chat.ReadWrite"}))
        self.assertFalse(teams.can_mark_read({"scopes": "Chat.Read ChatMessage.Send"}))

    def test_setting_a_presence_needs_its_own_grant(self):
        # Reading everybody's presence is ordinary user consent; writing your
        # own is admin consent, so the two are not the same question.
        self.assertTrue(teams.can_set_presence({"scopes": "Chat.ReadWrite Presence.ReadWrite"}))
        self.assertFalse(teams.can_set_presence({"scopes": "Chat.ReadWrite Presence.Read.All"}))
        self.assertTrue(teams.can_see_presence({"scopes": "Presence.Read.All"}))
        self.assertFalse(teams.can_see_presence({"scopes": "Presence.ReadWrite"}))

    def test_presence_write_is_a_tier_asked_for_only_when_wanted(self):
        self.assertNotIn("Presence.ReadWrite", teams.scopes_for(False))
        self.assertNotIn("Presence.ReadWrite", teams.scopes_for(True, True))
        self.assertIn("Presence.ReadWrite", teams.scopes_for(False, False, True))

    def test_a_refresh_asks_for_what_this_sign_in_was_actually_granted(self):
        # Not for what the settings currently want, and not for less than was
        # granted: the refreshed token comes back with whatever was asked for,
        # and store_tokens records that as this sign-in's scopes. Asking for
        # the base set would have the file and presence tiers fall off an
        # account an hour after it signed in.
        held = "Chat.ReadWrite Files.ReadWrite Presence.ReadWrite ChannelMessage.Read.All"
        asked = teams.scopes_held_by({"scopes": held})
        for scope in ("Files.ReadWrite", "Presence.ReadWrite", "ChannelMessage.Read.All"):
            self.assertIn(scope, asked)
        # And nothing is asked for that this sign-in never had.
        self.assertNotIn("Presence.ReadWrite", teams.scopes_held_by({"scopes": "Chat.ReadWrite"}))

    def test_a_sign_in_from_before_scopes_were_recorded_may_do_neither(self):
        # Unknown has to mean no: offering a button that 403s is worse than
        # not offering it, and the window says which sign-in would fix it.
        for account in ({}, None, {"scopes": ""}):
            self.assertFalse(teams.has_channels(account))
            self.assertFalse(teams.can_mark_read(account))
            self.assertFalse(teams.can_set_presence(account))

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


class SettingYourPresence(unittest.TestCase):
    """The status menu, written through Graph."""

    def run_presence(self, command=None, scopes="Chat.ReadWrite Presence.ReadWrite",
                     responses=None, **kwargs):
        self.calls = []
        queue = list(responses or [(200, {})])

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return queue.pop(0) if queue else (200, {})

        token = "h." + base64.urlsafe_b64encode(
            json.dumps({"oid": "user-1", "tid": "tenant-1"}).encode()).decode().rstrip("=") + ".s"

        args = Args()
        args.state = "dnd"
        args.duration = ""
        for name, value in kwargs.items():
            setattr(args, name, value)
        patched = {
            "read_json": lambda *a, **k: {"scopes": scopes, "client_id": "app-1"},
            "access_token": lambda alias, account: (token, account),
            "http": http,
        }
        original = {name: getattr(teams, name) for name in patched}
        for name, stub in patched.items():
            setattr(teams, name, stub)
        try:
            return capture(command or teams.cmd_presence, args)
        finally:
            for name, value in original.items():
                setattr(teams, name, value)

    def test_a_preferred_presence_is_posted_for_the_signed_in_user(self):
        result = self.run_presence()
        self.assertTrue(result["ok"])
        self.assertEqual(self.calls[0]["url"],
                         teams.GRAPH + "/users/user-1/presence/setUserPreferredPresence")
        self.assertEqual(self.calls[0]["body"],
                         {"availability": "DoNotDisturb", "activity": "DoNotDisturb"})

    def test_auto_clears_it_rather_than_setting_a_state(self):
        result = self.run_presence(state="auto")
        self.assertEqual(result["state"], "auto")
        self.assertTrue(self.calls[0]["url"].endswith("/clearUserPreferredPresence"))
        self.assertEqual(self.calls[0]["body"], {})

    def test_an_expiry_is_passed_on_only_when_one_was_asked_for(self):
        self.run_presence(duration="PT8H")
        self.assertEqual(self.calls[0]["body"].get("expirationDuration"), "PT8H")
        self.run_presence()
        self.assertNotIn("expirationDuration", self.calls[0]["body"])

    def test_a_state_graph_would_refuse_is_refused_here_first(self):
        # Graph takes six availability/activity pairs and nothing else, so a
        # state that is not one of them costs no round trip to find out about.
        result = self.run_presence(state="lunch")
        self.assertEqual(result["error"]["code"], "bad_presence")
        self.assertEqual(self.calls, [])

    def test_without_the_write_scope_nothing_is_attempted(self):
        result = self.run_presence(scopes="Chat.ReadWrite Presence.Read.All")
        self.assertEqual(result["error"]["code"], "presence_permission_required")
        self.assertEqual(self.calls, [], "a request was made that was known to be refused")

    def test_a_403_says_the_permission_rather_than_the_failure(self):
        result = self.run_presence(responses=[(403, {"error": {"message": "Missing scope"}})])
        self.assertEqual(result["error"]["code"], "presence_permission_required")

    def test_every_pair_offered_is_one_graph_takes(self):
        # The picker's rows and the sender's table are the same list, so a row
        # that would fail cannot be offered.
        states = capture(teams.cmd_presence_states, Args())["states"]
        self.assertEqual([row["state"] for row in states],
                         ["available", "busy", "dnd", "brb", "away", "offline"])
        for row in states:
            self.assertEqual(teams.preferred_pair(row["state"]),
                             (row["availability"], row["activity"]))
            self.assertIn(row["dot"], ("available", "busy", "away", "offline"))
        # Appear offline is the one pair whose two halves differ, and getting
        # it wrong is a 400 rather than a silent no-op.
        offline = [row for row in states if row["state"] == "offline"][0]
        self.assertEqual((offline["availability"], offline["activity"]), ("Offline", "OffWork"))


class HoldingAPresenceSession(unittest.TestCase):
    """The session that makes a preferred presence visible at all."""

    def run_hold(self, **kwargs):
        helper = SettingYourPresence()
        kwargs.setdefault("state", "available")
        kwargs.setdefault("duration", "PT1H")
        result = helper.run_presence(command=teams.cmd_hold_presence, **kwargs)
        self.calls = helper.calls
        return result

    def test_the_session_is_named_after_the_application(self):
        # Graph's own requirement: "Provide the ID of the application as
        # sessionId". Anything else opens a session nothing can renew.
        result = self.run_hold()
        self.assertTrue(result["ok"])
        self.assertTrue(self.calls[0]["url"].endswith("/presence/setPresence"))
        self.assertEqual(self.calls[0]["body"], {
            "sessionId": "app-1", "availability": "Available",
            "activity": "Available", "expirationDuration": "PT1H",
        })

    def test_away_is_the_other_thing_a_desktop_can_honestly_say(self):
        self.run_hold(state="away")
        self.assertEqual(self.calls[0]["body"]["availability"], "Away")

    def test_it_will_not_claim_to_be_in_a_call(self):
        # setPresence takes Busy only as InACall or InAConferenceCall, and the
        # plugin knows about neither.
        result = self.run_hold(state="busy")
        self.assertEqual(result["error"]["code"], "bad_presence")
        self.assertEqual(self.calls, [])

    def test_letting_go_clears_the_session_by_id(self):
        result = self.run_hold(state="none")
        self.assertTrue(result["ok"])
        self.assertTrue(self.calls[0]["url"].endswith("/presence/clearPresence"))
        self.assertEqual(self.calls[0]["body"], {"sessionId": "app-1"})

    def test_letting_go_of_a_session_that_already_expired_is_not_a_failure(self):
        # Graph answers 404, and that is the state being asked for.
        result = self.run_hold(state="none", responses=[(404, {})])
        self.assertTrue(result["ok"])
        self.assertTrue(result["alreadyGone"])


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

    def test_who_reacted_is_named_for_the_line_a_chip_shows(self):
        # Graph lists them one per person, so the names are already here.
        message = {"reactions": [
            {"reactionType": "👍", "displayName": "Like",
             "user": {"user": {"id": "a", "displayName": "Ana Beltr\u00e1n"}}},
            {"reactionType": "👍", "displayName": "Like",
             "user": {"user": {"id": "me", "displayName": "Jan Renz"}}},
        ]}
        rows = teams.reaction_summary(message, "me")
        self.assertEqual(rows[0]["who"], ["You", "Ana Beltr\u00e1n"])

    def test_a_reactor_with_no_name_is_left_out_but_still_counted(self):
        rows = teams.reaction_summary(self.message(("👍", "a")), "me")
        self.assertEqual(rows[0]["count"], 1)
        self.assertEqual(rows[0]["who"], [])


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


class SendingAFile(unittest.TestCase):
    """Upload, share, post - and what happens when one of the three fails."""

    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()
        self.file = os.path.join(self.dir, "shot.png")
        with open(self.file, "wb") as handle:
            handle.write(b"\x89PNG\r\n" + b"x" * 40)

    ITEM = {"id": "01ITEM", "eTag": '"{5B33B0FF-1111-2222-3333-44444455DDEE},1"',
            "webUrl": "https://x-my.sharepoint.com/personal/item"}
    LINK = {"link": {"webUrl": "https://x-my.sharepoint.com/:i:/g/shared"}}

    def run_upload(self, responses=None, scopes="Chat.ReadWrite Files.ReadWrite",
                   chat="19:abc", comment="", file=None):
        import types
        self.calls = []
        queue = list(responses if responses is not None
                     else [(201, self.ITEM), (201, self.LINK), (201, {"id": "msg-9"})])

        def http(url, method="GET", data=None, json_body=None, raw=None,
                 headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body,
                               "raw": raw, "headers": headers})
            return queue.pop(0) if queue else (200, {})

        args = types.SimpleNamespace(account="work", chat=chat,
                                     file=self.file if file is None else file,
                                     comment=comment, stdin=False, demo=False)
        patched = {
            "read_json": lambda *a, **k: {"scopes": scopes},
            "access_token": lambda alias, account: ("token", account),
            "http": http,
        }
        original = {name: getattr(teams, name) for name in patched}
        for name, stub in patched.items():
            setattr(teams, name, stub)
        try:
            return capture(teams.cmd_upload, args)
        finally:
            for name, value in original.items():
                setattr(teams, name, value)

    def test_the_file_goes_to_the_folder_teams_itself_uses(self):
        result = self.run_upload()
        self.assertTrue(result["ok"])
        put = self.calls[0]
        self.assertEqual(put["method"], "PUT")
        self.assertIn("Microsoft%20Teams%20Chat%20Files/shot.png:/content", put["url"])
        # rename, so a second Screenshot.png does not replace the first.
        self.assertIn("conflictBehavior=rename", put["url"])
        self.assertEqual(put["raw"][:4], b"\x89PNG")

    def test_the_message_carries_the_attachment_keyed_by_the_items_etag(self):
        self.run_upload()
        post = self.calls[-1]
        self.assertIn("/me/chats/19:abc/messages", post["url"].replace("%3A", ":"))
        attachment = post["body"]["attachments"][0]
        self.assertEqual(attachment["id"], "5B33B0FF-1111-2222-3333-44444455DDEE")
        self.assertEqual(attachment["contentType"], "reference")
        self.assertEqual(attachment["contentUrl"], self.LINK["link"]["webUrl"])
        self.assertIn('<attachment id="5B33B0FF-1111-2222-3333-44444455DDEE">',
                      post["body"]["body"]["content"])

    def test_a_comment_is_escaped_because_the_body_has_to_be_html(self):
        self.run_upload(comment="a < b & c")
        content = self.calls[-1]["body"]["body"]["content"]
        self.assertTrue(content.startswith("a &lt; b &amp; c<br><attachment"))

    def test_organisation_scope_is_asked_for_first_and_a_refusal_falls_back(self):
        result = self.run_upload(responses=[
            (201, self.ITEM), (403, {"error": {"message": "no"}}),
            (201, self.LINK), (201, {"id": "msg-9"})])
        self.assertTrue(result["ok"])
        self.assertEqual(self.calls[1]["body"], {"type": "view", "scope": "organization"})
        self.assertEqual(self.calls[2]["body"], {"type": "view"})

    def test_a_file_in_the_drive_that_could_not_be_posted_says_where_it_is(self):
        result = self.run_upload(responses=[
            (201, self.ITEM), (201, self.LINK), (403, {"error": {"message": "nope"}})])
        self.assertEqual(result["error"]["code"], "post_failed")
        self.assertIn("in your OneDrive", result["error"]["message"])

    def test_a_sign_in_without_the_permission_refuses_before_any_request(self):
        result = self.run_upload(scopes="Chat.ReadWrite")
        self.assertEqual(result["error"]["code"], "permission_required")
        self.assertEqual(self.calls, [])

    def test_a_channel_is_refused_with_the_reason_rather_than_attempted(self):
        result = self.run_upload(chat="")
        self.assertEqual(result["error"]["code"], "channel_files_unsupported")
        self.assertEqual(self.calls, [])

    def test_an_item_without_an_etag_is_not_guessed_a_guid_for(self):
        item = dict(self.ITEM)
        del item["eTag"]
        result = self.run_upload(responses=[(201, item)])
        self.assertEqual(result["error"]["code"], "upload_failed")

    def test_the_cap_is_the_one_request_limit_and_says_so(self):
        big = os.path.join(self.dir, "big.bin")
        with open(big, "wb") as handle:
            handle.truncate(teams.UPLOAD_CAP + 1)
        result = self.run_upload(file=big)
        self.assertEqual(result["error"]["code"], "too_large")
        self.assertIn("graph.microsoft.com", result["error"]["message"])

    def test_files_are_a_third_tier_of_scopes_asked_for_only_when_wanted(self):
        # A registration that does not declare a permission fails the whole
        # sign-in when it is requested, so this one is opt-in.
        self.assertNotIn("Files.ReadWrite", teams.scopes_for(False))
        self.assertNotIn("Files.ReadWrite", teams.scopes_for(True))
        self.assertIn("Files.ReadWrite", teams.scopes_for(False, True))
        self.assertIn("Chat.ReadWrite", teams.scopes_for(False, True))


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
