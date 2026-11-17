import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_appcast_branch_uses_latest_main_after_signing_tag_checkout(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Commit Updated Appcast\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("        env:\n", 1)[0])
        preparation = script.split("python3 -m venv", 1)[0]

        with tempfile.TemporaryDirectory(prefix="seven-island-release-test-") as folder:
            folder = Path(folder)
            remote = folder / "origin.git"
            checkout = folder / "checkout"
            checkout.mkdir()

            def git(*arguments):
                return subprocess.check_output(
                    ["git", *arguments], cwd=checkout, text=True, stderr=subprocess.PIPE
                ).strip()

            git("init", "--bare", "--initial-branch=main", str(remote))
            git("init", "--initial-branch=main")
            git("config", "user.name", "Release Workflow Test")
            git("config", "user.email", "release-test@example.invalid")
            git("config", "commit.gpgsign", "false")
            git("remote", "add", "origin", str(remote))
            appcast = checkout / "updater/appcast.xml"
            appcast.parent.mkdir()
            appcast.write_text("<rss><channel><item><title>1.2.0</title></item></channel></rss>\n")
            git("add", ".")
            git("commit", "-m", "Tag source appcast")
            git("tag", "v1.3.0")
            git("push", "origin", "main")

            latest_appcast = "<rss><channel><item><title>1.2.1</title></item></channel></rss>\n"
            appcast.write_text(latest_appcast)
            git("commit", "-am", "Publish previous version appcast")
            git("push", "origin", "main")
            git("checkout", "--detach", "v1.3.0")
            appcast.write_text("<rss><channel><item><title>1.3.0</title></item></channel></rss>\n")

            result = subprocess.run(
                ["bash", "-e", "-c", preparation], cwd=checkout, text=True, capture_output=True
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(git("branch", "--show-current"), "appcast-update")
            self.assertEqual(appcast.read_text(), latest_appcast)
            self.assertEqual(git("status", "--porcelain"), "")


if __name__ == "__main__":
    unittest.main()
