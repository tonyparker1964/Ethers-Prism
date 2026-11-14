#!/bin/bash
# Rebuild Ethers Prism with the latest changes from GitHub.
#
# Finds your Ethers Prism project folder, pulls the newest code from
# github.com/tonyparker1964/Ethers-Prism, runs the tests, then builds and
# installs "Ethers Prism.app" in Applications and opens it.
#
# Run it from anywhere:
#   curl -fsSL https://raw.githubusercontent.com/tonyparker1964/Ethers-Prism/main/scripts/rebuild-prism.sh | bash
# Use a specific folder: put PRISM_DIR=/path/to/Ethers-Prism before bash.

set -euo pipefail

REPO_URL="https://github.com/tonyparker1964/Ethers-Prism.git"
FRESH_DIR="$HOME/Ethers-Prism"

say()  { printf '\n\033[1;35m▸ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# A folder is the Prism project if its Package.swift names EthersPrism and it has install-app.sh.
is_prism() { [ -f "$1/Package.swift" ] && [ -f "$1/install-app.sh" ] && grep -q 'name: "EthersPrism"' "$1/Package.swift"; }

# 1. Find the project folder ------------------------------------------------
say "Looking for your Ethers Prism folder…"
DIR=""
if [ -n "${PRISM_DIR:-}" ]; then
  is_prism "$PRISM_DIR" || fail "$PRISM_DIR isn't an Ethers Prism project folder."
  DIR="$PRISM_DIR"
else
  # Spotlight first (fast), then a quick look in the usual places.
  CANDIDATES=$( { mdfind -name install-app.sh 2>/dev/null || true
                  find "$HOME/Documents" "$HOME/Desktop" "$HOME/Developer" "$HOME" -maxdepth 4 \
                       -name install-app.sh -not -path '*/.build/*' -not -path '*/.Trash/*' 2>/dev/null || true; } \
                | grep -v -e '/\.build/' -e '/\.Trash/' -e '/Library/' | sort -u )
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    d=$(dirname "$f")
    if is_prism "$d"; then
      # Prefer a git checkout of the GitHub repo.
      if git -C "$d" remote get-url origin 2>/dev/null | grep -qi 'ethers-prism'; then DIR="$d"; break; fi
      [ -z "$DIR" ] && DIR="$d"
    fi
  done <<< "$CANDIDATES"
fi

# 2. Get the latest code -----------------------------------------------------
if [ -z "$DIR" ]; then
  say "No Ethers Prism folder found. Downloading a fresh copy to $FRESH_DIR…"
  [ -e "$FRESH_DIR" ] && fail "$FRESH_DIR already exists but isn't the project. Move it, or run with PRISM_DIR=…"
  git clone "$REPO_URL" "$FRESH_DIR"
  DIR="$FRESH_DIR"
elif git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  say "Found: $DIR"
  cd "$DIR"
  if [ -n "$(git status --porcelain)" ]; then
    echo "This folder has changes that aren't on GitHub yet:"
    git status --short
    fail "Nothing was changed. Commit or move those changes, then run this again."
  fi
  say "Pulling the latest changes…"
  git pull --ff-only || fail "Couldn't pull cleanly. Paste this output to Claude."
else
  say "Found $DIR, but it isn't linked to GitHub, so it can't be updated."
  [ -e "$FRESH_DIR" ] && fail "Move or rename $FRESH_DIR, then run this again to get a fresh copy there."
  echo "Downloading a fresh copy to $FRESH_DIR (your old folder is left as it is)…"
  git clone "$REPO_URL" "$FRESH_DIR"
  DIR="$FRESH_DIR"
fi

cd "$DIR"
echo "Now at: $(git log -1 --format='%h  %s  (%ad)' --date=format:'%b %d %H:%M')"

# 3. Test ---------------------------------------------------------------------
say "Running the tests (the first run takes a few minutes)…"
swift test || fail "Some tests failed. Nothing was installed. Paste this output to Claude."

# 4. Build, install and open -------------------------------------------------
say "Building and installing Ethers Prism…"
./install-app.sh

say "Done. Ethers Prism is up to date in Applications."
echo "Project folder: $DIR"
