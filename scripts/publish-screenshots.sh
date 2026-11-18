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

RESET_HINT="git -C \"$REPO\" rebase --abort; git -C \"$REPO\" reset --hard origin/main"
NO_ACCESS_HINT="Without write access to jithin-sabu/purge-screenshots, drag the images into the PR description instead."

if [ -d "$REPO/.git" ]; then
  if [ -d "$REPO/.git/rebase-merge" ] || [ -d "$REPO/.git/rebase-apply" ]; then
    echo "$REPO is stuck in a rebase. Clear it with: $RESET_HINT" >&2
    exit 1
  fi
  [ -z "$(git -C "$REPO" status --porcelain)" ] || { echo "$REPO has uncommitted changes. Sort them out first." >&2; exit 1; }
  git -C "$REPO" checkout -q main
  git -C "$REPO" fetch -q origin main || { echo "Can't reach jithin-sabu/purge-screenshots. Nothing was published." >&2; exit 1; }
  git -C "$REPO" merge -q --ff-only origin/main >/dev/null 2>&1 || true
  if [ "$(git -C "$REPO" rev-parse main)" != "$(git -C "$REPO" rev-parse origin/main)" ]; then
    # Most likely a run whose push failed. Those files never reached GitHub.
    echo "Local main in $REPO has commits that are not on GitHub, so nothing in them was published." >&2
    echo "Drop them with: git -C \"$REPO\" reset --hard origin/main" >&2
    exit 1
  fi
else
  git clone -q "$REMOTE" "$REPO" || { echo "Can't clone jithin-sabu/purge-screenshots. Nothing was published." >&2; exit 1; }
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

# Puts the screenshots repo back to GitHub's main, so a failed run leaves
# nothing behind that blocks the next one. The source PNGs are untouched.
give_up() {
  git -C "$REPO" rebase --abort >/dev/null 2>&1 || true
  git -C "$REPO" reset -q --hard origin/main
  echo "$1 Nothing was published." >&2
  exit 1
}

git -C "$REPO" add -- "$FOLDER"
git -C "$REPO" commit -q -m "Add shots for $WHAT"
if ! git -C "$REPO" push -q origin main; then
  # Another session may have pushed first. Different names rebase cleanly.
  git -C "$REPO" fetch -q origin main || give_up "The push failed and GitHub can't be reached."
  git -C "$REPO" rebase -q origin/main >/dev/null 2>&1 || give_up "Someone published a file with the same name meanwhile. Pick another name."
  git -C "$REPO" push -q origin main || give_up "The push to jithin-sabu/purge-screenshots failed. $NO_ACCESS_HINT"
fi

SHA="$(git -C "$REPO" rev-parse HEAD)"
echo >&2
for name in "${NAMES[@]}"; do
  echo "![${name%.webp}]($WEB/blob/$SHA/$FOLDER/$name?raw=true)"
done
