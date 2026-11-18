#!/usr/bin/env python3
"""Keeps screenshots and oversized files out of the repo (#403).

Every file ever committed stays in the history, so every clone, CI run and
fork downloads it for good. By November 2026, 991 PR screenshots in
docs/screenshots/ had added 163 MB in three months. PR screenshots now go to
jithin-sabu/purge-screenshots through scripts/publish-screenshots.sh.

This reads the git index (what is committed or staged, which is what CI
checks out), not the working tree, and fails on:
- anything under docs/screenshots/;
- an image or video outside the folders that ship in the app or the README;
- an image over 300 KB, or any file over 1 MB, unless ALLOWED_LARGE names it.

Usage: python3 scripts/check-repo-weight.py
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

MEDIA = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".tif", ".tiff", ".mov", ".mp4", ".m4v"}

# Images belong only where the app or the README uses them.
MEDIA_FOLDERS = (
    "Assets/",
    "purge/Assets.xcassets/",
    "purge/Resources/BrandIcons/",
    "purge.icon/",
)

MAX_MEDIA = 300 * 1024
MAX_FILE = 1024 * 1024

# Big files we need, each with the reason. Add one only when it can't be smaller.
ALLOWED_LARGE = {
    "Assets/dmg/VolumeIcon.icns": "the DMG volume icon; an .icns holds every size up to 1024 px",
    "bin/sign_update": "Sparkle's signing tool, run by the release scripts",
}

SCREENSHOT_HINT = "Publish PR shots with scripts/publish-screenshots.sh and link them in the PR."


def tracked_files():
    """Returns [(path, size)] for every blob in the index."""
    listing = subprocess.run(
        ["git", "ls-files", "-s", "-z"], cwd=ROOT, check=True, capture_output=True
    ).stdout.decode()
    entries = []
    for record in filter(None, listing.split("\0")):
        meta, path = record.split("\t", 1)
        mode, sha, _stage = meta.split()
        if mode == "160000":  # a submodule commit, not a file
            continue
        entries.append((path, sha))
    if not entries:
        return []
    sizes = subprocess.run(
        ["git", "cat-file", "--batch-check=%(objectsize)"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        input="\n".join(sha for _, sha in entries).encode(),
    ).stdout.decode().split()
    return [(path, int(size)) for (path, _), size in zip(entries, sizes)]


def kb(size):
    return f"{size / 1024:.0f} KB"


def main():
    problems = []
    files = tracked_files()
    for path, size in files:
        is_media = pathlib.PurePosixPath(path).suffix.lower() in MEDIA
        if path.startswith("docs/screenshots/"):
            problems.append(f"{path}: screenshots don't go in this repo. {SCREENSHOT_HINT}")
        elif is_media and not path.startswith(MEDIA_FOLDERS):
            problems.append(
                f"{path}: images and videos go only in {', '.join(MEDIA_FOLDERS)}. {SCREENSHOT_HINT}"
            )
        elif path in ALLOWED_LARGE:
            continue
        elif is_media and size > MAX_MEDIA:
            problems.append(
                f"{path}: {kb(size)}, over the {kb(MAX_MEDIA)} cap for images. "
                "Size it at 2x the width it is shown at, then compress it (pngquant or cwebp)."
            )
        elif size > MAX_FILE:
            problems.append(
                f"{path}: {kb(size)}, over the {kb(MAX_FILE)} cap. "
                "Keep it out of the repo, or add it to ALLOWED_LARGE with the reason."
            )

    tracked = {path for path, _ in files}
    for path in ALLOWED_LARGE:
        if path not in tracked:
            problems.append(f"{path}: listed in ALLOWED_LARGE but not in the repo. Remove the entry.")

    if problems:
        print("Repo weight check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        sys.exit(1)
    print("Repo weight check passed.")


if __name__ == "__main__":
    main()
