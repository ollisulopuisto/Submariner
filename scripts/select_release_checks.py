"""Skip packaging for credential-only pushes; tags/manual and app changes still build."""

import os
import subprocess

SAFE = {
    ".github/workflows/build.yml",
    "scripts/macos_ci_credentials.py",
    "scripts/select_release_checks.py",
    "tests/manual/test_macos_keychain_transport.py",
    ".github/workflows/credential-transport.yml",
    "docs/release-credential-transport.md",
    "scripts/tests/test_release_credentials.py",
}


def needs_package(paths):
    return not paths or any(path not in SAFE for path in paths)


if __name__ == "__main__":
    before = os.environ.get("BEFORE", "")
    if (
        os.environ.get("GITHUB_EVENT_NAME") != "push"
        or os.environ.get("GITHUB_REF", "").startswith("refs/tags/")
        or not before
        or set(before) == {"0"}
    ):
        print("package=true")
    else:
        paths = subprocess.check_output(
            ["git", "diff", "--name-only", before, "HEAD"], text=True
        ).splitlines()
        print("package=" + str(needs_package(paths)).lower())
