"""Packaging scope must never hide unclassified application/build changes."""

import importlib.util
import os
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "scope", ROOT / "scripts/select_release_checks.py"
)
SCOPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCOPE)


class ScopeTests(unittest.TestCase):
    def test_reviewed_credential_paths_skip(self):
        self.assertFalse(SCOPE.needs_package(list(SCOPE.SAFE)))
        for workflow in SCOPE.REVIEWED_WORKFLOWS:
            self.assertFalse(SCOPE.needs_package([workflow]))

    def test_future_workflow_edit_builds(self):
        for workflow in SCOPE.REVIEWED_WORKFLOWS:
            with patch.object(
                Path, "read_bytes", return_value=b"changed DMG build command"
            ):
                self.assertTrue(SCOPE.needs_package([workflow]))

    def test_app_and_empty_diff_build(self):
        self.assertTrue(SCOPE.needs_package(["app/source.swift"]))
        self.assertTrue(SCOPE.needs_package([]))

    def test_missing_force_push_base_builds(self):
        with patch.dict(
            os.environ,
            {
                "GITHUB_EVENT_NAME": "push",
                "GITHUB_REF": "refs/heads/main",
                "BEFORE": "old-tip",
            },
        ), patch.object(
            SCOPE.subprocess,
            "check_output",
            side_effect=subprocess.CalledProcessError(128, "git"),
        ):
            self.assertTrue(SCOPE.select_package())


if __name__ == "__main__":
    unittest.main()
