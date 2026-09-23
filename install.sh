#!/bin/bash
# Builds the app and installs it, replacing any copy already there.
#
#   ./install.sh                  # into /Applications
#   ./install.sh ~/Applications   # into your own, which needs no admin rights
set -euo pipefail
cd "$(dirname "$0")"

DEST="${1:-/Applications}"
APP="OctopusMenuBar.app"
SOURCE="build/$APP"

# Resolve before doing anything destructive: an empty or mistyped destination would otherwise
# aim the rm below at the root of the disk.
DEST="${DEST%/}"
if [ -z "$DEST" ]; then
  echo "install.sh: refusing to install into the root of the disk" >&2
  exit 1
fi
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
TARGET="$DEST/$APP"

./build.sh
[ -d "$SOURCE" ] || { echo "install.sh: $SOURCE was not built" >&2; exit 1; }

# Say what is being replaced before replacing it.
if [ -d "$TARGET" ]; then
  echo "Replacing the copy installed $(date -r "$TARGET" '+%d %b %Y at %H:%M')"
elif [ -e "$TARGET" ]; then
  echo "install.sh: $TARGET exists and is not an app bundle" >&2
  exit 1
fi

# A running copy has to stop before its bundle is swapped underneath it.
if pgrep -x OctopusMenuBar >/dev/null 2>&1; then
  echo "Quitting the running copy…"
  osascript -e 'quit app "OctopusMenuBar"' >/dev/null 2>&1 || pkill -x OctopusMenuBar || true
  for _ in $(seq 25); do
    pgrep -x OctopusMenuBar >/dev/null 2>&1 || break
    sleep 0.2
  done
  pkill -x OctopusMenuBar 2>/dev/null || true
fi

if [ ! -w "$DEST" ]; then
  echo "install.sh: cannot write to $DEST" >&2
  echo "  run it with sudo, or install into your own folder:  ./install.sh ~/Applications" >&2
  exit 1
fi

# Replace outright rather than copying over the top: a file left behind by an older build would
# still be inside the bundle and still be loaded.
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

echo "Installed $TARGET"
# The signature changes on every build, so macOS treats this as a different app from the one it
# granted Keychain access to. Choose Always Allow and it will not ask again until the next build.
echo "macOS will ask for Keychain access again — the ad-hoc signature changes on every build."
# Launching is a convenience, not the job: a refusal here must not report the install as failed.
open "$TARGET" || echo "note: couldn't launch it — open $APP from $DEST yourself"
