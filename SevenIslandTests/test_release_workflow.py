import base64
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except ImportError:
    Ed25519PrivateKey = None


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / ".github/workflows/scripts"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "example/seven-island"
TAG = "v9.9.0"
DMG_NAME = "Seven-Island-9.9.0.dmg"
APPCAST = Path("updater/appcast.xml")


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def workflow_shell(step_name):
    workflow = (ROOT / ".github/workflows/release.yml").read_text()
    step = workflow.split(f"      - name: {step_name}\n", 1)[1]
    body = step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
    return textwrap.dedent(body)


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self):
        self.release = load_script("find-release-dmg")

    def lookup(self):
        return self.release.find_release_dmg("https://api.github.test", REPOSITORY, TAG, "test-token")

    def test_published_dmg_is_reused(self):
        data = {"assets": [{"name": DMG_NAME, "state": "uploaded", "size": 123}]}
        with patch.object(self.release, "urlopen", return_value=io.BytesIO(json.dumps(data).encode())):
            self.assertEqual(self.lookup(), DMG_NAME)

    def test_missing_release_and_release_without_dmg_allow_build(self):
        missing = HTTPError("https://api.github.test", 404, "Not Found", {}, None)
        with patch.object(self.release, "urlopen", side_effect=missing):
            self.assertIsNone(self.lookup())
        data = {"assets": [{"name": "checksums.txt", "state": "uploaded", "size": 123}]}
        with patch.object(self.release, "urlopen", return_value=io.BytesIO(json.dumps(data).encode())):
            self.assertIsNone(self.lookup())

    def test_lookup_failure_and_incomplete_upload_propagate(self):
        forbidden = HTTPError("https://api.github.test", 403, "Forbidden", {}, None)
        with patch.object(self.release, "urlopen", side_effect=forbidden):
            with self.assertRaises(HTTPError):
                self.lookup()
        data = {"assets": [{"name": DMG_NAME, "state": "starter", "size": 0}]}
        with patch.object(self.release, "urlopen", return_value=io.BytesIO(json.dumps(data).encode())):
            with self.assertRaisesRegex(ValueError, "incomplete upload"):
                self.lookup()

    def test_workflow_downloads_the_selected_asset(self):
        with tempfile.TemporaryDirectory() as path:
            work = Path(path)
            published = work / DMG_NAME
            published.write_bytes(b"published release")
            gh = work / "gh"
            gh.write_text(textwrap.dedent("""\
                #!/usr/bin/env bash
                set -euo pipefail
                [[ "$*" == "release download --repo $GITHUB_REPOSITORY --pattern $DMG_NAME --output "* ]]
                [[ "${10}" == "$RELEASE_TAG" ]]
                cp "$PUBLISHED_DMG" "$8"
                """))
            gh.chmod(0o755)
            output = work / "output"
            env = {
                **os.environ,
                "PATH": f"{work}:{os.environ['PATH']}",
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_WORKSPACE": str(work),
                "GITHUB_OUTPUT": str(output),
                "DMG_NAME": DMG_NAME,
                "RELEASE_TAG": TAG,
                "PUBLISHED_DMG": str(published),
            }
            subprocess.run(["bash", "-e", "-c", workflow_shell("Download Published DMG")], cwd=work, env=env, check=True)
            downloaded = work / "build/published" / DMG_NAME
            self.assertEqual(downloaded.read_bytes(), published.read_bytes())
            self.assertEqual(output.read_text().strip(), f"path={downloaded}")


@unittest.skipIf(Ed25519PrivateKey is None, "cryptography is required for release signing tests")
class AppcastPublishTests(unittest.TestCase):
    def setUp(self):
        sandbox = tempfile.TemporaryDirectory(prefix="seven-island-release-test-")
        self.addCleanup(sandbox.cleanup)
        self.folder = Path(sandbox.name)
        self.repository = self.folder / "checkout"
        self.repository.mkdir()
        self.remote = self.folder / "origin.git"
        self.dmg = self.folder / DMG_NAME
        self.dmg.write_bytes(b"the downloaded release asset")
        self.key = Ed25519PrivateKey.generate()
        key_bytes = self.key.private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
        self.env = {
            **os.environ,
            "TMPDIR": str(self.folder),
            "GIT_USER": "Release Workflow Test",
            "GIT_EMAIL": "release-test@example.invalid",
            "SPARKLE_PRIVATE_KEY": base64.b64encode(key_bytes).decode("ascii"),
            "PATH": f"{Path(sys.executable).parent}:{os.environ['PATH']}",
        }

        self.git("init", "--bare", "--initial-branch=main", str(self.remote))
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", self.env["GIT_USER"])
        self.git("config", "user.email", self.env["GIT_EMAIL"])
        self.git("config", "commit.gpgsign", "false")
        self.git("remote", "add", "origin", str(self.remote))
        appcast = self.repository / APPCAST
        appcast.parent.mkdir()
        appcast.write_text("<rss><channel><item><title>9.7.0</title></item></channel></rss>\n")
        self.git("add", ".")
        self.git("commit", "-m", "Tag source")
        self.git("tag", TAG)
        appcast.write_text(
            "<rss><channel><item><title>9.8.0</title></item><item><title>9.7.0</title></item></channel></rss>\n"
        )
        self.git("commit", "-am", "Publish earlier tag on main")
        self.git("push", "origin", "main")
        self.git("checkout", "--detach", TAG)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repository, stderr=subprocess.PIPE, text=True).strip()

    def publish(self):
        result = subprocess.run(
            ["bash", SCRIPTS / "publish-appcast.sh", self.dmg, "9.9.0", "990", TAG, REPOSITORY],
            cwd=self.repository,
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def main_appcast(self):
        return self.git("--git-dir", str(self.remote), "show", f"main:{APPCAST}")

    def test_publishes_into_latest_main_and_rerun_has_no_commit(self):
        self.publish()
        revision = self.git("--git-dir", str(self.remote), "rev-parse", "main")
        appcast = self.main_appcast()
        items = ET.fromstring(appcast).findall("./channel/item")
        self.assertEqual([item.findtext("title") for item in items], ["9.9.0", "9.8.0", "9.7.0"])
        enclosure = items[0].find("enclosure")
        self.assertEqual(int(enclosure.get("length")), len(self.dmg.read_bytes()))
        self.assertTrue(enclosure.get("url").endswith(f"/{TAG}/{DMG_NAME}"))
        self.key.public_key().verify(base64.b64decode(enclosure.get(f"{{{NS}}}edSignature")), self.dmg.read_bytes())

        self.assertIn("already contains", self.publish())
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse", "main"), revision)
        self.assertEqual(self.main_appcast(), appcast)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.git("rev-parse", TAG))
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_retries_after_main_advances_during_publish(self):
        parallel = self.folder / "parallel"
        self.git("clone", "--branch", "main", str(self.remote), str(parallel))
        appcast = parallel / APPCAST
        appcast.write_text(appcast.read_text().replace(
            "<channel>", "<channel><item><title>9.8.1</title></item>", 1
        ))
        self.git(
            "-C", str(parallel), "-c", f"user.name={self.env['GIT_USER']}",
            "-c", f"user.email={self.env['GIT_EMAIL']}", "-c", "commit.gpgsign=false",
            "commit", "-am", "Publish another tag",
        )

        git = self.folder / "git"
        git.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ "$1" == "-C" && "${3:-}" == "push" && ! -e "$PUSH_MARKER" ]]; then
                touch "$PUSH_MARKER"
                "$TEST_GIT" -C "$PARALLEL_CHECKOUT" push origin main
            fi
            exec "$TEST_GIT" "$@"
            """))
        git.chmod(0o755)
        marker = self.folder / "parallel-pushed"
        self.env.update({
            "PATH": f"{self.folder}:{self.env['PATH']}",
            "TEST_GIT": shutil.which("git"),
            "PARALLEL_CHECKOUT": str(parallel),
            "PUSH_MARKER": str(marker),
        })

        self.publish()
        self.assertTrue(marker.exists())
        items = ET.fromstring(self.main_appcast()).findall("./channel/item")
        self.assertEqual(
            [item.findtext("title") for item in items], ["9.9.0", "9.8.1", "9.8.0", "9.7.0"]
        )

    def test_updates_existing_tag_in_place_and_preserves_original_date(self):
        writer = load_script("update-appcast")
        old_date = "Thu, 06 Aug 2026 06:17:45 +0000"
        later_date = "Thu, 06 Aug 2026 06:17:48 +0000"
        link = f"https://github.com/{REPOSITORY}/releases/tag/{TAG}"
        appcast = self.folder / "duplicates.xml"
        appcast.write_text(f"""
            <rss><channel>
                <item><title>9.9.1</title></item>
                <item><link>{link}</link><pubDate>{later_date}</pubDate></item>
                <item><link>{link}</link><pubDate>{old_date}</pubDate></item>
                <item><title>9.9.0</title><link>{link}-alternate</link></item>
                <item><title>9.8.0</title></item>
            </channel></rss>
        """.strip())
        signature = writer.update_appcast(appcast, self.dmg, "9.9.0", "990", TAG, REPOSITORY, self.env["SPARKLE_PRIVATE_KEY"])
        items = ET.parse(appcast).findall("./channel/item")
        self.assertEqual([item.findtext("title") for item in items], ["9.9.1", "9.9.0", "9.9.0", "9.8.0"])
        self.assertEqual(items[1].findtext("pubDate"), old_date)
        self.assertEqual(items[1].find("enclosure").get(f"{{{NS}}}edSignature"), signature)
        self.assertEqual(items[2].findtext("link"), f"{link}-alternate")


class AppcastHistoryTests(unittest.TestCase):
    def test_historical_duplicates_retain_earliest_dates(self):
        items = ET.parse(ROOT / APPCAST).findall("./channel/item")
        for version, date in {
            "1.2.0": "Tue, 23 Jun 2026 08:13:20 +0000",
            "1.2.1": "Thu, 06 Aug 2026 06:17:45 +0000",
        }.items():
            matched = [item for item in items if item.findtext("title") == version]
            self.assertEqual(len(matched), 1)
            self.assertEqual(matched[0].findtext("pubDate"), date)


if __name__ == "__main__":
    unittest.main()
