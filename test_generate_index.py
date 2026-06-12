"""Tests for generate_index.py (stdlib unittest, no external deps).

Run from the repo root:  python3 -m unittest test_generate_index -v

Covers the audited fixes: deterministic ordering (H1), UTC timestamps (H2),
HTML escaping (M2), and the deny-dir exclusion that applies to both the JSON
index and the browsable HTML listing (M1).
"""

import os
import json
import shutil
import subprocess
import tempfile
import unittest

import generate_index as gi


def _write(relpath, content=b"x"):
    parent = os.path.dirname(relpath)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(relpath, "wb") as f:
        f.write(content)


class TempCwd(unittest.TestCase):
    """Each test runs inside a throwaway working directory."""

    def setUp(self):
        self._cwd = os.getcwd()
        self._tmp = tempfile.TemporaryDirectory()
        os.chdir(self._tmp.name)

    def tearDown(self):
        os.chdir(self._cwd)
        self._tmp.cleanup()


class MediaIndexTests(TempCwd):
    def test_whitelist_and_exclusions(self):
        _write("assets/img/b.png")
        _write("assets/img/a.png")
        _write("assets/img/doc.pdf")          # non-media extension -> excluded
        _write("assets/img/.hidden.png")       # hidden -> excluded
        _write("assets/secrets/leak.png")      # deny dir -> excluded
        _write("random/x.png")                 # non-whitelisted top -> excluded

        gi.generate_media_index()
        with open("media-index.json", encoding="utf-8") as f:
            index = json.load(f)

        paths = [e["path"] for e in index["files"]]
        self.assertEqual(paths, ["assets/img/a.png", "assets/img/b.png"])
        self.assertEqual(index["totalFiles"], 2)
        self.assertTrue(all(e["type"] == "image/png" for e in index["files"]))


class HtmlListingTests(TempCwd):
    def test_deny_dirs_not_listed(self):
        _write("assets/img/a.png")
        _write("assets/secrets/leak.png")
        gi.generate_index_html(".")
        with open(os.path.join("assets", "index.html"), encoding="utf-8") as f:
            html = f.read()
        self.assertIn("img/", html)
        self.assertNotIn("secrets/", html)

    def test_names_are_html_escaped(self):
        _write(os.path.join("assets", "t<x>.txt"))
        gi.generate_index_html(".")
        with open(os.path.join("assets", "index.html"), encoding="utf-8") as f:
            html = f.read()
        self.assertIn("t&lt;x&gt;.txt", html)
        self.assertNotIn("t<x>.txt", html)

    def test_directory_order_is_sorted(self):
        for name in ("zzz", "aaa", "mmm"):
            _write(os.path.join("assets", name, "f.png"))
        gi.generate_index_html(".")
        with open(os.path.join("assets", "index.html"), encoding="utf-8") as f:
            html = f.read()
        self.assertLess(html.index("aaa/"), html.index("mmm/"))
        self.assertLess(html.index("mmm/"), html.index("zzz/"))

    def test_breadcrumb_has_clickable_ancestors(self):
        _write(os.path.join("assets", "img", "a.png"))
        gi.generate_index_html(".")
        with open(os.path.join("assets", "img", "index.html"), encoding="utf-8") as f:
            html = f.read()
        self.assertIn('href="../index.html"', html)       # parent: assets/
        self.assertIn('href="../../index.html"', html)    # root
        self.assertIn("crumb-current", html)              # current folder, not a link
        self.assertNotIn("Go Back", html)                 # old button removed


@unittest.skipUnless(shutil.which("git"), "git not available")
class GitDateTests(TempCwd):
    def _git(self, *args, **env):
        e = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
        e.update(env)
        subprocess.run(["git", *args], check=True, capture_output=True, text=True, env=e)

    def test_listing_uses_git_commit_date(self):
        self._git("init", "-q")
        self._git("config", "user.email", "t@example.com")
        self._git("config", "user.name", "Tester")
        _write(os.path.join("assets", "img", "a.png"))
        when = "2020-02-02T03:04:05+00:00"
        self._git("add", "-A")
        self._git("commit", "-qm", "init", GIT_AUTHOR_DATE=when, GIT_COMMITTER_DATE=when)

        gi.generate_index_html(".")
        with open(os.path.join("assets", "img", "index.html"), encoding="utf-8") as f:
            file_listing = f.read()
        with open("index.html", encoding="utf-8") as f:
            root_listing = f.read()
        # File row shows the commit date (not the checkout mtime)...
        self.assertIn("2020-02-02 03:04 UTC", file_listing)
        # ...and the parent listing's folder row aggregates its newest child date.
        self.assertIn("2020-02-02 03:04 UTC", root_listing)


class FormatDateTests(unittest.TestCase):
    def test_utc_suffix_and_value(self):
        # Epoch 0 is 1970-01-01 00:00 UTC regardless of the machine timezone.
        self.assertEqual(gi.format_date(0), "1970-01-01 00:00 UTC")


if __name__ == "__main__":
    unittest.main()
