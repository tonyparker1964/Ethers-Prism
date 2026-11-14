#!/bin/bash
# Leaves exactly one Ethers Prism app: /Applications/Ethers Prism.app.
#
# Every other "Ethers Prism.app" this Mac knows about is handled like this:
#   - a copy that's part of a Prism project folder (tracked in git) stays on disk,
#     but is hidden from Launchpad, Spotlight's app list and "Open With";
#   - any other copy is moved to the Trash (nothing is deleted for good);
#   - records of copies that no longer exist are cleared.
# Then the Dock restarts so it picks up the change.
#
# Run:  bash scripts/one-prism-icon.sh

set -uo pipefail

KEEP="/Applications/Ethers Prism.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

say()  { printf '\033[1;35m▸ %s\033[0m\n' "$*"; }

if [ ! -d "$KEEP" ]; then
  echo "✗ $KEEP isn't installed yet. Run ./install-app.sh first." >&2
  exit 1
fi

say "Finding every copy of Ethers Prism…"
LIST=$( { mdfind 'kMDItemFSName == "Ethers Prism.app"' 2>/dev/null
          "$LSREG" -dump 2>/dev/null | sed -n 's/^path: *\(.*Ethers Prism\.app\).*/\1/p'
          ls -d "$HOME/Applications/Ethers Prism.app" 2>/dev/null; } | sed 's/ (0x[0-9a-f]*)$//' | sort -u )

moved=0; hidden=0; cleared=0
while IFS= read -r app; do
  [ -z "$app" ] && continue
  [ "$app" = "$KEEP" ] && continue
  case "$app" in /Volumes/*|*/.Trash/*) "$LSREG" -u "$app" >/dev/null 2>&1; continue;; esac

  if [ ! -e "$app" ]; then
    "$LSREG" -u "$app" >/dev/null 2>&1 && cleared=$((cleared + 1))
    continue
  fi

  dir=$(dirname "$app")
  if git -C "$dir" ls-files --error-unmatch "Ethers Prism.app/Contents/Info.plist" >/dev/null 2>&1; then
    "$LSREG" -u "$app" >/dev/null 2>&1
    echo "  hidden (part of a project folder): $app"
    hidden=$((hidden + 1))
  else
    dest="$HOME/.Trash/Ethers Prism (old $(date +%H%M%S)-$moved).app"
    if mv "$app" "$dest" 2>/dev/null; then
      "$LSREG" -u "$app" >/dev/null 2>&1
      echo "  moved to Trash: $app"
      moved=$((moved + 1))
    else
      echo "  couldn't move (needs permission?): $app"
    fi
  fi
done <<< "$LIST"

"$LSREG" -f "$KEEP" >/dev/null 2>&1
killall Dock 2>/dev/null || true

say "Done: kept $KEEP"
echo "  moved to Trash: $moved · hidden: $hidden · old records cleared: $cleared"
echo "  If the Dock still shows a second Prism icon or a '?', drag it off the Dock."
