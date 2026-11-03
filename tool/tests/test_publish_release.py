import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tool.ci import publish_release as release


class PublishReleaseTest(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="yggvion release assets ")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.repository = "example/yggvion"
        self.version = "0.1.0+4"
        self.assets = [self.root / settings["installer"] for settings in release.TARGETS.values()]
        for asset in self.assets:
            asset.write_bytes(b"installer-fixture")
        self.pages = [[]]
        self.calls = []
        self.notes = ""
        self.fail_operation = None

    def gh(self, *args):
        self.calls.append(args)
        if args[0] == "api":
            return json.dumps(self.pages)
        if args[1] == self.fail_operation:
            raise subprocess.CalledProcessError(1, ["gh", *map(str, args)])
        if "--notes-file" in args:
            self.notes = Path(args[args.index("--notes-file") + 1]).read_text()
        return ""

    def publish(self):
        with patch.object(release, "gh", side_effect=self.gh):
            return release.publish_release(self.repository, self.version, self.root)

    def existing(self, *, draft=False, prerelease=True):
        return {"tag_name": self.version, "draft": draft, "prerelease": prerelease,
                "assets": [{"name": asset.name, "state": "uploaded"} for asset in self.assets]}

    def test_uploads_all_builds_before_publishing_prerelease_with_store_link(self):
        # Extra workflow artifacts must never become public release assets.
        (self.root / "notarization.json").write_text("private diagnostics fixture")
        url = self.publish()
        self.assertEqual(url, "https://github.com/example/yggvion/releases/tag/0.1.0%2B4")
        self.assertEqual([call[1] for call in self.calls[1:]], ["create", "upload", "edit"])
        create, upload, publish = self.calls[1:]
        self.assertIn("--draft", create)
        self.assertIn("--verify-tag", create)
        self.assertIn("--latest=false", create)
        self.assertEqual([arg for arg in upload if isinstance(arg, Path)], self.assets)
        self.assertIn("--draft=false", publish)
        self.assertIn("--prerelease", publish)
        self.assertIn("--latest=false", publish)
        self.assertIn(release.APP_STORE_URL, self.notes)
        for asset in self.assets:
            self.assertIn(f"/releases/download/0.1.0%2B4/{asset.name}", self.notes)

    def test_missing_empty_or_symlinked_installer_fails_before_any_github_call(self):
        asset = self.assets[0]
        for state in ("missing", "empty", "symlink"):
            asset.unlink(missing_ok=True)
            if state == "empty":
                asset.touch()
            elif state == "symlink":
                asset.symlink_to(self.assets[1])
            with self.subTest(state=state), self.assertRaisesRegex(ValueError, asset.name):
                self.publish()
            self.assertEqual(self.calls, [])

    def test_upload_failure_leaves_draft_unpublished(self):
        self.fail_operation = "upload"
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertEqual([call[1] for call in self.calls[1:]], ["create", "upload"])

    def test_retry_resumes_draft_found_on_later_page(self):
        self.pages = [[{"tag_name": "0.1.0+3"}], [self.existing(draft=True)]]
        self.publish()
        self.assertIn("--paginate", self.calls[0])
        self.assertEqual([call[1] for call in self.calls[1:]], ["edit", "upload", "edit"])
        self.assertIn("--clobber", self.calls[2])
        self.assertIn("--draft=false", self.calls[3])

    def test_rerun_preserves_published_prerelease_or_promoted_release(self):
        for prerelease in (True, False):
            self.pages = [[self.existing(prerelease=prerelease)]]
            self.calls.clear()
            with self.subTest(prerelease=prerelease):
                self.publish()
            self.assertEqual(len(self.calls), 1)

    def test_incomplete_published_release_is_not_silently_accepted_or_overwritten(self):
        existing = self.existing()
        existing["assets"].pop()
        self.pages = [[existing]]
        with self.assertRaisesRegex(ValueError, "missing installers"):
            self.publish()
        self.assertEqual(len(self.calls), 1)

    def test_api_failure_is_not_treated_as_missing_release(self):
        with patch.object(release, "gh", side_effect=subprocess.CalledProcessError(1, ["gh", "api"])) as gh:
            with self.assertRaises(subprocess.CalledProcessError):
                release.publish_release(self.repository, self.version, self.root)
        self.assertEqual(gh.call_count, 1)

    def test_duplicate_drafts_fail_without_modifying_either_release(self):
        self.pages = [[self.existing(draft=True), self.existing(draft=True)]]
        with self.assertRaisesRegex(ValueError, "Multiple releases"):
            self.publish()
        self.assertEqual(len(self.calls), 1)

    def test_invalid_version_or_repository_fails_before_github(self):
        for repository, version in ((self.repository, "0.1.0"), ("", self.version),
                                    ("example/yggvion/other", self.version)):
            with self.subTest(repository=repository, version=version), patch.object(release, "gh") as gh:
                with self.assertRaises(ValueError):
                    release.publish_release(repository, version, self.root)
                gh.assert_not_called()

    def test_branch_manual_or_mismatched_tag_run_cannot_publish(self):
        for event, ref_type, ref_name in (("push", "branch", "main"),
                                          ("workflow_dispatch", "tag", self.version),
                                          ("push", "tag", "0.1.0+3")):
            env = {"GITHUB_EVENT_NAME": event, "GITHUB_REF_TYPE": ref_type, "GITHUB_REF_NAME": ref_name}
            with (self.subTest(event=event, ref_type=ref_type, ref_name=ref_name),
                  patch.dict(release.os.environ, env),
                  patch.object(release.sys, "argv", ["publish_release.py", "--version", self.version]),
                  patch.object(release.sys, "stderr", new_callable=io.StringIO),
                  patch.object(release, "publish_release") as publish):
                with self.assertRaises(SystemExit) as result:
                    release.main()
                self.assertEqual(result.exception.code, 2)
                publish.assert_not_called()


if __name__ == "__main__":
    unittest.main()
