import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "prepare_fork_release.sh"


class ReleaseTagTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.run_git("init", "-q", "-b", "main")
        self.run_git("config", "user.name", "Release Test")
        self.run_git("config", "user.email", "release@example.invalid")
        (self.repository / "source").write_text("first")
        self.run_git("add", "source")
        self.run_git("commit", "-qm", "first")
        self.sha = self.run_git("rev-parse", "HEAD")
        self.remote = self.root / "remote.git"
        self.run_git("init", "--bare", "-q", str(self.remote))
        self.run_git("remote", "add", "origin", str(self.remote))
        self.run_git("push", "-q", "origin", "main")
        binary = self.root / "bin"
        binary.mkdir()
        gh = binary / "gh"
        gh.write_text('''#!/usr/bin/env bash
if [[ "$1" == api ]]; then
  printf '%s\\n' "$MOCK_HEAD"
elif [[ "$MOCK_DRAFT" == absent ]]; then
  exit 1
else
  printf '%s\\n' "$MOCK_DRAFT"
fi
''')
        gh.chmod(0o755)
        self.output = self.root / "output"
        self.environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                                RELEASE_TAG="v1.3.1-1", GITHUB_SHA=self.sha,
                                GITHUB_REPOSITORY="owner/repository", GITHUB_OUTPUT=str(self.output),
                                GITHUB_STEP_SUMMARY=str(self.root / "summary"), RUNNER_TEMP=str(self.root),
                                MOCK_HEAD=self.sha, MOCK_DRAFT="absent")

    def run_git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repository, text=True, stderr=subprocess.DEVNULL).strip()

    def prepare(self):
        return subprocess.run(["bash", str(SCRIPT)], cwd=self.repository, env=self.environment, capture_output=True, text=True)

    def test_reserves_remote_tag_before_build(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text().strip(), "skip=false")
        self.assertEqual(self.run_git("ls-remote", "origin", "refs/tags/v1.3.1-1").split()[0], self.sha)

    def test_obsolete_commit_is_skipped_without_tag(self):
        self.environment["MOCK_HEAD"] = "newer-commit"
        self.assertEqual(self.prepare().returncode, 0)
        self.assertEqual(self.output.read_text().strip(), "skip=true")
        self.assertEqual(self.run_git("tag", "--list"), "")

    def test_existing_tag_allows_draft_retry_after_main_advances(self):
        self.run_git("tag", "v1.3.1-1")
        self.environment.update(MOCK_HEAD="newer-commit", MOCK_DRAFT="true")
        self.assertEqual(self.prepare().returncode, 0)
        self.assertEqual(self.output.read_text().strip(), "skip=false")

    def test_published_build_is_skipped(self):
        self.run_git("tag", "v1.3.1-1")
        self.environment["MOCK_DRAFT"] = "false"
        self.assertEqual(self.prepare().returncode, 0)
        self.assertEqual(self.output.read_text().strip(), "skip=true")

    def test_existing_tag_for_another_commit_is_rejected(self):
        self.run_git("tag", "v1.3.1-1")
        (self.repository / "source").write_text("second")
        self.run_git("commit", "-qam", "second")
        self.environment["GITHUB_SHA"] = self.run_git("rev-parse", "HEAD")
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(self.run_git("rev-parse", "v1.3.1-1"), self.sha)
