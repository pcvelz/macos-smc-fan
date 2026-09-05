#!/usr/bin/env bash
#
# install-smcfand.sh - ONE-TIME privileged install of the smcfand
# LaunchDaemon. This script is NOT run by any automation in this repo;
# it is provided for the user to review and run by hand, exactly once,
# with sudo. It copies the already-built release binary to
# /usr/local/libexec and bootstraps the daemon via launchctl.
#
# Prerequisite: `swift build -c release --product smcfand` has already
# been run in this repo so .build/out/Products/Release/smcfand exists.
#
# Usage (run manually, not from any script):
#   sudo bash Scripts/install-smcfand.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT_BINARY="${REPO_ROOT}/.build/out/Products/Release/smcfand"
INSTALL_BINARY="/usr/local/libexec/smcfand"
PLIST_SRC="${REPO_ROOT}/LaunchDaemon/com.llama-cm.smcfand.plist"
PLIST_DEST="/Library/LaunchDaemons/com.llama-cm.smcfand.plist"

if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run with sudo (it installs a root LaunchDaemon)." >&2
  echo "  sudo bash Scripts/install-smcfand.sh" >&2
  exit 1
fi

if [[ ! -x "$BUILT_BINARY" ]]; then
  echo "Missing built binary at ${BUILT_BINARY}." >&2
  echo "Build it first (as the normal user, not root):" >&2
  echo "  swift build -c release --product smcfand" >&2
  exit 1
fi

mkdir -p /usr/local/libexec
cp "$BUILT_BINARY" "$INSTALL_BINARY"
chown root:wheel "$INSTALL_BINARY"
chmod 755 "$INSTALL_BINARY"

mkdir -p /tmp/smcfan
chmod 1777 /tmp/smcfan

cp "$PLIST_SRC" "$PLIST_DEST"
chown root:wheel "$PLIST_DEST"
chmod 644 "$PLIST_DEST"

launchctl bootout system "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DEST"
launchctl enable "system/com.llama-cm.smcfand"

echo "Installed and started com.llama-cm.smcfand."
echo "Check status: sudo launchctl print system/com.llama-cm.smcfand"
echo "Tail logs:    tail -f /tmp/smcfan/smcfand.log"
echo "Control it (no sudo needed): Scripts/smcfan-ctl auto|ramp|constant|full|status"
