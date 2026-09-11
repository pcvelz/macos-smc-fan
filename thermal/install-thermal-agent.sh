#!/bin/bash
# install-thermal-agent.sh - install the cold-start LaunchAgent for the thermal
# controller, so fan control survives a reboot without anyone running the
# start command by hand.
#
# macOS TCC denies a launchd job any read under ~/Documents: an agent pointed
# straight at a repo checkout there dies with status 126 ("Operation not
# permitted") while still looking installed. So the controller and its
# dependencies are copied to ~/Library/Application Support/smcfan/thermal/
# and the agent runs that copy. Re-run this script after any change to them.
#
# Config and hooks travel too: the config file (default
# ~/.config/smcfan/thermal.conf, or $THERMAL_CONF) is copied into the same
# dir, and any script named by its EXTERNAL_*_CMD / ALERT_CMD keys has its
# WHOLE containing directory copied alongside it (so a hook that imports
# sibling files, like a Python helper module, keeps working) - the copied
# config is then rewritten to call the copied scripts, never the originals.
# A STALE copy is the failure mode to watch for: re-run this installer after
# editing any hook script or the config file, or the agent keeps running the
# old copy.
#
# Usage: bash install-thermal-agent.sh [--uninstall|--status|--install-sidecar|--uninstall-sidecar]

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Library/Application Support/smcfan/thermal"
LOGDIR="$HOME/Library/Logs/smcfan"
LABEL="com.smcfan.thermal-controller"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OLD_LABEL="com.llama-cm.thermal-controller"

SIDECAR_LABEL="com.smcfan.powermetrics-sidecar"
SIDECAR_PLIST="/Library/LaunchDaemons/$SIDECAR_LABEL.plist"
OLD_SIDECAR_LABEL="com.llama-cm.powermetrics-sidecar"

SRC_CONF="${THERMAL_CONF:-$HOME/.config/smcfan/thermal.conf}"
DEST_CONF="$DEST/thermal.conf"

case "${1:-}" in
  --install-sidecar)
    # Separate subcommand because this is the ONE privileged step: powermetrics
    # needs root and most machines have no passwordless sudo, so this cannot
    # be part of the unattended install.
    echo "Installing $SIDECAR_LABEL (requires your password - powermetrics needs root)."
    sudo cp "$SRC_DIR/$SIDECAR_LABEL.plist" "$SIDECAR_PLIST"
    sudo chown root:wheel "$SIDECAR_PLIST"
    sudo chmod 644 "$SIDECAR_PLIST"
    # Both write the same log; two samplers would interleave it.
    sudo launchctl bootout "system/$OLD_SIDECAR_LABEL" 2>/dev/null || true
    sudo rm -f "/Library/LaunchDaemons/$OLD_SIDECAR_LABEL.plist"
    sudo launchctl bootout "system/$SIDECAR_LABEL" 2>/dev/null || true
    sudo launchctl bootstrap system "$SIDECAR_PLIST"
    echo "installed $SIDECAR_LABEL -> /tmp/t1-powermetrics-smc.log"
    exit 0
    ;;
  --uninstall-sidecar)
    sudo launchctl bootout "system/$SIDECAR_LABEL" 2>/dev/null || true
    sudo rm -f "$SIDECAR_PLIST"
    echo "uninstalled $SIDECAR_LABEL"
    exit 0
    ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled $LABEL (the running daemon, if any, is left alone)"
    exit 0
    ;;
  --status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null \
      | grep -E "state =|last exit|pid =" || echo "$LABEL: not loaded"
    exit 0
    ;;
esac

mkdir -p "$DEST" "$LOGDIR" "$DEST/hooks"

# Migration: an older install under the previous label must not keep running
# a stale copy alongside the new one. Unloading is not enough - a plist left
# in LaunchAgents is loaded again at the next login (RunAtLoad), which would
# start a second controller - so the file goes too. The old SIDECAR is left
# alone here: it is the controller's CPU signal, and replacing it needs root,
# so that migration lives in --install-sidecar.
launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"

cp "$SRC_DIR/controller.sh" "$DEST/controller.sh"

# smcfan-ctl + the unprivileged reader are the only internal-fan backend. The
# agent cannot read ~/Documents, so both travel into DEST and the copy is
# repointed at the copied reader; a missing build is fatal rather than a
# silent degrade to no internal fan control.
SMCFAN_SRC="${SMCFAN_SRC:-$(cd "$SRC_DIR/.." && pwd)}"
if [[ -r "$SMCFAN_SRC/Scripts/smcfan-ctl" && -x "$SMCFAN_SRC/.build/out/Products/Release/smcread" ]]; then
  cp "$SMCFAN_SRC/Scripts/smcfan-ctl" "$DEST/smcfan-ctl"
  cp "$SMCFAN_SRC/.build/out/Products/Release/smcread" "$DEST/smcread"
  sed -i '' "s|^SMCREAD_BIN=.*|SMCREAD_BIN=\"\${SMCREAD_BIN:-$DEST/smcread}\"|" "$DEST/smcfan-ctl"
else
  echo "$SMCFAN_SRC has no built smcread/smcfan-ctl - build it first (swift build -c release)" >&2
  exit 1
fi

# Copy the config (if any) and every hook script it names, each with its
# WHOLE containing directory so a hook's own sibling dependencies travel
# with it, then rewrite the copied config's *_CMD lines to call the copies.
if [[ -r "$SRC_CONF" ]]; then
  cp "$SRC_CONF" "$DEST_CONF"
  for key in EXTERNAL_ON_CMD EXTERNAL_OFF_CMD EXTERNAL_STATUS_CMD ALERT_CMD; do
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SRC_CONF" | tail -1 | sed -E "s/^[^=]*=[[:space:]]*//")
    [[ -z "$val" ]] && continue
    script="${val%% *}"     # first whitespace-delimited token
    [[ -f "$script" ]] || continue
    srcdir="$(cd "$(dirname "$script")" && pwd)"
    base="$(basename "$srcdir")"
    hookdir="$DEST/hooks/$base"
    mkdir -p "$hookdir"
    cp -R "$srcdir"/. "$hookdir"/
    chmod +x "$hookdir/$(basename "$script")" 2>/dev/null || true
    # DEST contains a space ("Application Support") and the controller runs
    # hooks with `bash -c`, so the copied path must be single-quoted or the
    # command splits at the space. Any arguments after the script are kept.
    rest="${val#"$script"}"
    newval="'$hookdir/$(basename "$script")'$rest"
    sed -i '' -E "s|^([[:space:]]*${key}[[:space:]]*=).*|\1${newval}|" "$DEST_CONF"
  done
  echo "installed config -> $DEST_CONF (hooks copied under $DEST/hooks)"
else
  echo "no config at $SRC_CONF - installing with built-in defaults (internal fans only)"
fi

sed -e "s|__CONTROLLER__|$DEST/controller.sh|" \
    -e "s|__LOGDIR__|$LOGDIR|" \
    -e "s|__SMCFAN_CTL__|$DEST/smcfan-ctl|" \
    -e "s|__THERMAL_CONF__|$DEST_CONF|" \
    "$SRC_DIR/$LABEL.plist" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "installed $LABEL -> $DEST/controller.sh"
echo "agent log: $LOGDIR/thermal-controller-agent.log"
echo "controller log: /tmp/thermal-controller/controller.log"
