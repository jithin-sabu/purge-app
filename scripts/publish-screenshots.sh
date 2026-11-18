#!/usr/bin/env bash
# Publish before and after screenshots for a PR to jithin-sabu/purge-screenshots.
#
# Usage: scripts/publish-screenshots.sh <issue> <shot.png>...
#        scripts/publish-screenshots.sh <branch-name> <shot.png>...
# Example: scripts/publish-screenshots.sh 403 hero-before-dark.png hero-after-dark.png
#
# Screenshots never go into this repo (#403): 991 of them made every full
# clone 163 MB heavier. This converts each PNG to lossless WebP (about 74%
# smaller, text stays exact), commits it to <issue>/ or misc/<branch-name>/
# in the screenshots repo, pushes, and prints Markdown links pinned to that
# commit. Paste the links into the PR description. The links never move,
# because files there are never overwritten or deleted.
#
# It needs write access to the screenshots repo. Without it, drag the images
# into the PR description instead.
#
# The screenshots repo is kept at ~/Developer/purge-screenshots, or at
# $PURGE_SCREENSHOTS_DIR, and cloned there on first use.
# $PURGE_SCREENSHOTS_REMOTE replaces the remote, for testing this script only.
set -euo pipefail

REMOTE="${PURGE_SCREENSHOTS_REMOTE:-https://github.com/jithin-sabu/purge-screenshots.git}"
WEB="https://github.com/jithin-sabu/purge-screenshots"
REPO="${PURGE_SCREENSHOTS_DIR:-$HOME/Developer/purge-screenshots}"
REPO="${REPO%/}"
LOCK="$REPO.publish-lock"

usage() {
  echo "Usage: scripts/publish-screenshots.sh <issue or branch-name> <shot.png>..." >&2
  exit 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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

for tool in cwebp dwebp; do
  command -v "$tool" >/dev/null || { echo "$tool not found. Install it with: brew install webp" >&2; exit 1; }
done

# Check every name before touching anything. Names are compared without
# case, because a Mac volume treats Hero-dark and hero-dark as one file.
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
    [ "$(lower "$seen")" != "$(lower "$name")" ] || { echo "Two files would both become $name" >&2; exit 1; }
  done
  NAMES+=("$name")
done

# Convert and check the whole batch outside the checkout first, so a bad
# file leaves nothing behind there.
TMP="$(mktemp -d)"
LOCKED=""
cleanup() {
  rm -rf "$TMP"
  if [ -n "$LOCKED" ]; then rmdir "$LOCK" 2>/dev/null || true; fi
}
trap cleanup EXIT

i=0
for shot in "$@"; do
  name="${NAMES[$i]}"
  i=$((i + 1))
  case "$shot" in
    *.webp) cp "$shot" "$TMP/$name" ;;
    # Keep the colour profile: macOS tags screenshots Display P3.
    *) cwebp -quiet -lossless -z 6 -metadata icc "$shot" -o "$TMP/$name" || { echo "Couldn't convert $shot. Nothing was published." >&2; exit 1; } ;;
  esac
  dwebp -quiet -pam "$TMP/$name" -o /dev/null 2>/dev/null || { echo "$shot doesn't decode as an image. Nothing was published." >&2; exit 1; }
done

# One run at a time per checkout, from the name check to the push.
mkdir -p "$(dirname "$REPO")"
mkdir "$LOCK" 2>/dev/null || {
  echo "Another publish is using $REPO. If none is running, remove $LOCK and try again." >&2
  exit 1
}
LOCKED=1

RESET_HINT="git -C \"$REPO\" rebase --abort; git -C \"$REPO\" reset --hard origin/main"
NO_ACCESS_HINT="Without write access to jithin-sabu/purge-screenshots, drag the images into the PR description instead."

if [ -d "$REPO/.git" ]; then
  # The links name jithin-sabu/purge-screenshots, so the push must go there.
  # A push goes to every push URL, so check them all.
  URLS="$(git -C "$REPO" remote get-url --all origin; git -C "$REPO" remote get-url --push --all origin)" || {
    echo "$REPO has no origin remote. Use another folder." >&2
    exit 1
  }
  while IFS= read -r url; do
    case "${url%.git}" in
      "${REMOTE%.git}" | git@github.com:jithin-sabu/purge-screenshots | ssh://git@github.com/jithin-sabu/purge-screenshots) ;;
      *) echo "$REPO pushes to $url, not to jithin-sabu/purge-screenshots. Point origin there or use another folder." >&2; exit 1 ;;
    esac
  done <<<"$URLS"
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
  if ls -A "$REPO/$FOLDER" | tr '[:upper:]' '[:lower:]' | grep -Fqx "$(lower "$name")"; then
    echo "$FOLDER/$name already exists, and merged PRs may link to it. Pick another name." >&2
    exit 1
  fi
done

# Paths this run puts into the checkout, so a failure can take them out
# again, ignored by git or not.
INSTALLED=()
remove_installed() {
  for path in "${INSTALLED[@]+"${INSTALLED[@]}"}"; do rm -f "$REPO/$path"; done
}

# Puts the screenshots repo back to GitHub's main, so a failed run leaves
# nothing behind that blocks the next one or rides along with it. The
# source PNGs are untouched.
give_up() {
  git -C "$REPO" rebase --abort >/dev/null 2>&1 || true
  # Before the reset: on a Mac volume, our k-dark and someone else's
  # published K-dark are one file, and the reset must win.
  remove_installed
  git -C "$REPO" reset -q --hard origin/main
  echo "$1 Nothing was published." >&2
  exit 1
}

links() {
  for name in "${NAMES[@]}"; do
    echo "![${name%.webp}]($WEB/blob/$1/$FOLDER/$name?raw=true)"
  done
}

i=0
for shot in "$@"; do
  name="${NAMES[$i]}"
  i=$((i + 1))
  INSTALLED+=("$FOLDER/$name")
  mv "$TMP/$name" "$REPO/$FOLDER/$name" || give_up "Couldn't move $name into $REPO."
  echo "$FOLDER/$name: $(wc -c <"$shot" | tr -d ' ') bytes -> $(wc -c <"$REPO/$FOLDER/$name" | tr -d ' ') bytes" >&2
done

# Exact paths, so git refuses a shot that an ignore rule would skip.
git -C "$REPO" add -- "${INSTALLED[@]}" || give_up "Couldn't stage the shots."
git -C "$REPO" commit -q -m "Add shots for $WHAT" || give_up "Couldn't commit the shots."
COMMIT="$(git -C "$REPO" rev-parse HEAD)"
if ! git -C "$REPO" push -q origin main; then
  if ! git -C "$REPO" fetch -q origin main; then
    # The push may have landed before the connection dropped, so keep the
    # commit. If it didn't land, the next run says how to drop it.
    echo "The push failed and GitHub can't be reached, so it's unclear whether commit $COMMIT got there." >&2
    echo "If it did, these links work. Open one to check:" >&2
    links "$COMMIT"
    exit 1
  fi
  if git -C "$REPO" merge-base --is-ancestor "$COMMIT" origin/main; then
    # The push landed after all; only the reply was lost.
    git -C "$REPO" merge -q --ff-only origin/main
  else
    # Another session may have pushed first. Names that differ only in case
    # are different paths to git, so check them before the rebase.
    published="$(git -C "$REPO" ls-tree --name-only origin/main -- "$FOLDER/" | sed 's|.*/||' | tr '[:upper:]' '[:lower:]')"
    for name in "${NAMES[@]}"; do
      if printf '%s\n' "$published" | grep -Fqx "$(lower "$name")"; then
        give_up "Someone published $FOLDER/$name, or the same name in other case, meanwhile. Pick another name."
      fi
    done
    git -C "$REPO" rebase -q origin/main >/dev/null 2>&1 || give_up "The rebase onto GitHub's main failed."
    git -C "$REPO" push -q origin main || give_up "The push to jithin-sabu/purge-screenshots failed. $NO_ACCESS_HINT"
  fi
fi

SHA="$(git -C "$REPO" rev-parse HEAD)"
echo >&2
links "$SHA"
