#!/usr/bin/env bash
# Publish before and after screenshots for a PR to jithin-sabu/purge-screenshots.
#
# Usage: scripts/publish-screenshots.sh <issue> <shot.png>...
#        scripts/publish-screenshots.sh <branch-name> <shot.png>...
# Example: scripts/publish-screenshots.sh 403 hero-before-dark.png hero-after-dark.png
#
# Screenshots never go into this repo (#403): 991 of them made every clone
# 163 MB heavier. This converts each PNG to lossless WebP (about 74% smaller,
# text stays exact), commits it to <issue>/ or misc/<branch-name>/ in the
# screenshots repo, pushes, and prints Markdown links pinned to that commit.
# Paste the links into the PR description. The links never move, because
# files there are never overwritten or deleted.
#
# The screenshots repo is kept at ~/Developer/purge-screenshots, or at
# $PURGE_SCREENSHOTS_DIR, and cloned there on first use.
set -euo pipefail

REMOTE="https://github.com/jithin-sabu/purge-screenshots.git"
WEB="https://github.com/jithin-sabu/purge-screenshots"
REPO="${PURGE_SCREENSHOTS_DIR:-$HOME/Developer/purge-screenshots}"

usage() {
  echo "Usage: scripts/publish-screenshots.sh <issue or branch-name> <shot.png>..." >&2
  exit 1
}

[ $# -ge 2 ] || usage
TARGET="$1"
shift

if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  FOLDER="$TARGET"
  WHAT="#$TARGET"
elif [[ "$TARGET" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ "$TARGET" != *..* ]]; then
  FOLDER="misc/$TARGET"
  WHAT="$TARGET"
else
  echo "Not an issue number or a branch name: $TARGET" >&2
  exit 1
fi

command -v cwebp >/dev/null || { echo "cwebp not found. Install it with: brew install webp" >&2; exit 1; }

# Check every file before touching the screenshots repo, so a bad name
# leaves nothing half published.
NAMES=()
for shot in "$@"; do
  [ -f "$shot" ] || { echo "No such file: $shot" >&2; exit 1; }
  base="$(basename "$shot")"
  case "$base" in
    *.png | *.PNG) name="${base%.*}.webp" ;;
    *.webp) name="$base" ;;
    *) echo "Not a PNG or WebP: $shot" >&2; exit 1 ;;
  esac
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Use only letters, digits, dots, dashes and underscores in the name: $base" >&2; exit 1; }
  [[ "$name" == *-dark* ]] || { echo "Shots are dark mode only, and the name says so with -dark: $base" >&2; exit 1; }
  for seen in "${NAMES[@]+"${NAMES[@]}"}"; do
    [ "$seen" != "$name" ] || { echo "Two files would both become $name" >&2; exit 1; }
  done
  NAMES+=("$name")
done

if [ -d "$REPO/.git" ]; then
  [ -z "$(git -C "$REPO" status --porcelain)" ] || { echo "$REPO has uncommitted changes. Sort them out first." >&2; exit 1; }
  git -C "$REPO" checkout -q main
  git -C "$REPO" pull -q --ff-only origin main
else
  git clone -q "$REMOTE" "$REPO"
fi

mkdir -p "$REPO/$FOLDER"
for name in "${NAMES[@]}"; do
  if [ -e "$REPO/$FOLDER/$name" ]; then
    echo "$FOLDER/$name already exists, and merged PRs may link to it. Pick another name." >&2
    exit 1
  fi
done

i=0
for shot in "$@"; do
  name="${NAMES[$i]}"
  i=$((i + 1))
  case "$shot" in
    *.webp) cp "$shot" "$REPO/$FOLDER/$name" ;;
    # Keep the colour profile: macOS tags screenshots Display P3.
    *) cwebp -quiet -lossless -z 6 -metadata icc "$shot" -o "$REPO/$FOLDER/$name" ;;
  esac
  echo "$FOLDER/$name: $(wc -c <"$shot" | tr -d ' ') bytes -> $(wc -c <"$REPO/$FOLDER/$name" | tr -d ' ') bytes" >&2
done

git -C "$REPO" add -- "$FOLDER"
git -C "$REPO" commit -q -m "Add shots for $WHAT"
if ! git -C "$REPO" push -q origin main; then
  # Another session pushed first. Our files are new names, so a rebase is clean.
  git -C "$REPO" pull -q --rebase origin main
  git -C "$REPO" push -q origin main
fi

SHA="$(git -C "$REPO" rev-parse HEAD)"
echo >&2
for name in "${NAMES[@]}"; do
  echo "![${name%.webp}]($WEB/blob/$SHA/$FOLDER/$name?raw=true)"
done
