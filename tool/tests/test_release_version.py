import tempfile
from pathlib import Path
import unittest

from tool.ci.release_version import build_matrix, parse_version, resolve_version


class ReleaseVersionTest(unittest.TestCase):
    def test_tag_is_the_source_of_version_and_build_number(self):
        version = resolve_version({"GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "1.2.3+45"}, Path("unused"))
        self.assertEqual(parse_version(version), ("1.2.3", "45"))

    def test_manual_branch_uses_pubspec(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "client").mkdir()
            (root / "client/pubspec.yaml").write_text("name: example\nversion: 0.1.0+1\n")
            self.assertEqual(resolve_version({"GITHUB_REF_TYPE": "branch", "GITHUB_REF_NAME": "main"}, root), "0.1.0+1")
            (root / "client/pubspec.yaml").write_text("name: example\n")
            with self.assertRaises(ValueError):
                resolve_version({}, root)

    def test_invalid_tags_do_not_fall_back_or_inject_workflow_outputs(self):
        for value in ("", "v1.2.3+4", "1.2.3", "1.2.3.4", "1.2.3+0", "01.2.3+4",
                      "1.2.3+01", "1.2.3+10000", "1.2.3+4\nmatrix=malicious", "$(whoami)"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                resolve_version({"GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": value}, Path("unused"))

    def test_manual_target_restricts_the_matrix(self):
        self.assertEqual(len(build_matrix("all")["include"]), 5)
        self.assertEqual([row["target"] for row in build_matrix("ios")["include"]], ["ios"])
        with self.assertRaises(ValueError):
            build_matrix("ios;echo injected")


if __name__ == "__main__":
    unittest.main()
