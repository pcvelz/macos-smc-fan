#!/bin/bash
# controller.sh - GPU-load-driven dual-fan controller.
#
# Input signals: GPU UTILISATION % (unprivileged ioreg read) drives the
# internal ramp AND an optional external fan; CPU power (from the
# powermetrics sidecar log) drives the internal ramp only.
# Actuation:     the internal MacBook fans via the smcfan-ctl/smcfand root
#                daemon (ramp = linear min-max sensor curve, stock = auto),
#                plus an OPTIONAL external fan/ventilator driven by whatever
#                command the config file points at.
#
# The two signals have different reach:
#   GPU hot -> internal ramp AND external fan (both fans)
#   CPU hot -> internal ramp ONLY (a hot CPU is the laptop's own problem; an
#              external fan, if configured, is reserved for GPU work)
# So the ramp engages when EITHER signal is sustained-hot and only returns to
# stock when BOTH are sustained-cool; the external fan follows GPU alone. Both
# signals use the same sustain windows.
#
# The internal side is best-effort - if smcfan-ctl or the smcfand daemon is
# missing or misbehaves the tick logs it and carries on with the external fan
# alone (if any), because losing the ramp must never stop cooling.
#
#   controller.sh once     - evaluate one tick and exit (default)
#   controller.sh loop     - evaluate every POLL_INTERVAL seconds until killed
#   controller.sh probe    - print the sensor readings only, take no action
#   controller.sh reset    - hand both actuators back to stock/off and exit
#
# DRY_RUN defaults to 1. The armed daemon form is an explicit DRY_RUN=0.
#
# CONFIGURATION: all site-specific values (thresholds, sustain windows, the
# smcfan sensor/curve, and any external-fan/alert hooks) come from a config
# file, never hardcoded here. Path: $THERMAL_CONF, default
# ~/.config/smcfan/thermal.conf. See thermal.conf.example for every key.
# A missing config file is not an error - the script runs on its built-in
# defaults with the internal fans only (no external hook = internal only).
# Precedence: an already-set environment variable wins over the config file,
# which wins over the built-in default (this is what keeps the test suite
# hermetic - it sets env vars directly and the config file never overrides
# them).

set -uo pipefail

# ============================== CONFIG ======================================

# --- load site config (before any ${VAR:-default} below) -------------------
# The file is parsed line by line and NEVER sourced/eval'd: only a fixed
# whitelist of keys is accepted, everything else is reported and ignored, so
# a config file can only ever set the values it is documented to set.
_load_config() {
    local conf="${THERMAL_CONF:-$HOME/.config/smcfan/thermal.conf}"
    [[ -r "$conf" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                                    # strip comments
        line="${line#"${line%%[![:space:]]*}"}"                 # ltrim
        line="${line%"${line##*[![:space:]]}"}"                 # rtrim
        [[ -z "$line" ]] && continue
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        case "$key" in
            GPU_UTIL_PCT|CPU_LOAD_MW|POLL_INTERVAL|ON_SUSTAIN_SECONDS|OFF_SUSTAIN_SECONDS|\
            ALERT_AFTER_SECONDS|ALERT_CLEAR_SECONDS|\
            SMCFAN_SENSOR|SMCFAN_MIN_C|SMCFAN_MAX_C|SMCFAN_SMOOTH_S|SMCFAN_CTL|\
            PRESSURE_LOG|EXTERNAL_ON_CMD|EXTERNAL_OFF_CMD|EXTERNAL_STATUS_CMD|ALERT_CMD)
                if [[ -z "${!key:-}" ]]; then
                    printf -v "$key" '%s' "$val"
                fi
                ;;
            *)
                echo "thermal.conf: ignoring unknown key '$key' ($conf)" >&2
                ;;
        esac
    done < "$conf"
}
_load_config

# --- actuation -------------------------------------------------------------
DRY_RUN="${DRY_RUN:-1}"
INTERNAL_FAN_ENABLED="${INTERNAL_FAN_ENABLED:-1}"   # 0 disables the internal ramp only

# The internal fans are driven by two companion pieces from this same repo:
# smcfand (root daemon, the only SMC writer - auto/constant/full only, no
# ramp logic) and smcfan-rampd (unprivileged agent that turns a ramp REQUEST
# into smcfand `constant` writes). The controller only ever writes a request
# via smcfan-ctl; it never talks to either backend directly. Both backends
# fall back to auto by themselves when a heartbeat goes stale (60s), so the
# loop refreshes the heartbeat on every tick while the ramp is wanted - a
# dead controller hands the fans back to macOS within a minute either way.
SMCFAN_CTL="${SMCFAN_CTL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Scripts/smcfan-ctl}"
SMCFAN_DESIRED="${SMCFAN_DESIRED:-/tmp/smcfan/desired.json}"
SMCFAN_RAMP="${SMCFAN_RAMP:-/tmp/smcfan/ramp.json}"        # the ramp REQUEST, read by smcfan-rampd
SMCFAN_STATUS="${SMCFAN_STATUS:-/tmp/smcfan/status.json}"  # smcfand's own liveness signal, rewritten every 2s poll
SMCFAN_LIVENESS_SECONDS="${SMCFAN_LIVENESS_SECONDS:-30}"  # > several 2s polls, < the 60s dead-man
SMCFAN_SENSOR="${SMCFAN_SENSOR:-cpu_core_average}"        # sensor the ramp targets
SMCFAN_MIN_C="${SMCFAN_MIN_C:-45}"
SMCFAN_MAX_C="${SMCFAN_MAX_C:-75}"
SMCFAN_SMOOTH_S="${SMCFAN_SMOOTH_S:-20}"                   # EMA time constant (s); smcfand default matches, 0 = off

# --- optional external fan --------------------------------------------------
# Any shell command; run with `bash -c`, no arguments passed. Leave both
# EXTERNAL_ON_CMD and EXTERNAL_OFF_CMD unset to run internal-fans-only - the
# whole external-fan section of every tick is then skipped, not merely
# no-op'd. EXTERNAL_STATUS_CMD is a manual-diagnostics hook ONLY (`controller.sh
# probe` and `cmd_reset`'s "already off" check) - tick() never calls it. The
# external fan is a real-world switch (e.g. a Home Assistant entity) and
# polling it every tick would spam that backend for no reason, so the tick
# decision is edge-triggered purely off the controller's OWN last-commanded
# state (EXT_FAN_COMMANDED_F): it acts only when the desired state differs
# from what it last asked for. A side effect worth calling out: a human who
# flips the switch by hand between crossings is never overridden - the
# controller has no way to see that flip without polling, and the rule that
# forbids polling is more important than reasserting our own command. It must
# print exactly "on", "off", or "unknown" when used via `probe`/`reset`.
EXTERNAL_ON_CMD="${EXTERNAL_ON_CMD:-}"
EXTERNAL_OFF_CMD="${EXTERNAL_OFF_CMD:-}"
EXTERNAL_STATUS_CMD="${EXTERNAL_STATUS_CMD:-}"

# --- sensing ---------------------------------------------------------------
# GPU UTILISATION % is read unprivileged via `ioreg -r -c IOGPU -d 1 -f`, key
# "Device Utilization %". Ordinary desktop use alone can read well into the
# 40-70% range on some machines, so the threshold should sit above whatever
# your own idle-desktop baseline turns out to be - see thermal.conf.example.
GPU_UTIL_SRC="${GPU_UTIL_SRC:-}"   # empty = run ioreg live; set to a file to stub its output in tests
GPU_UTIL_PCT="${GPU_UTIL_PCT:-85}"
PRESSURE_LOG="${PRESSURE_LOG:-/tmp/t1-powermetrics-smc.log}"
SENSOR_MAX_AGE=60                       # s; staler than this = UNKNOWN, hold

# CPU power drives the INTERNAL fans only - a hot CPU is the laptop's own
# cooling problem, while an external fan (if any) is reserved for GPU work.
CPU_LOAD_MW="${CPU_LOAD_MW:-8000}"

# --- hysteresis ------------------------------------------------------------
POLL_INTERVAL="${POLL_INTERVAL:-15}"
ON_SUSTAIN_SECONDS="${ON_SUSTAIN_SECONDS:-60}"    # CPU: loaded this long before the ramp engages
OFF_SUSTAIN_SECONDS="${OFF_SUSTAIN_SECONDS:-30}"  # idle this long before a fan goes off

# GPU engages after 2 consecutive hot ticks, not the first one: unlike GPU
# power, utilisation has no load-only dead band, so a single crossing is not
# enough evidence of sustained load. _streak reports elapsed seconds since
# the first hot tick, so requiring one POLL_INTERVAL of streak is what
# "2 ticks" means here.
GPU_ON_SUSTAIN_SECONDS=$POLL_INTERVAL

# The alert fires on the COOL side of an episode, not the hot side: once the
# GPU has been above threshold and then drops below it for this long, run
# ALERT_CMD (if configured) once per dip.
ALERT_AFTER_SECONDS="${ALERT_AFTER_SECONDS:-120}"  # below threshold this long after being above -> one alert per dip
ALERT_CLEAR_SECONDS="${ALERT_CLEAR_SECONDS:-120}"  # back above threshold this long before the latch re-arms

# --- state / logging -------------------------------------------------------
STATE_DIR="${STATE_DIR:-/tmp/thermal-controller/hysteresis}"
# The machine-readable snapshot deliberately does NOT sit at
# /tmp/thermal-controller/state - the hysteresis counters used to live at
# exactly that path, and `mv` would silently move the snapshot file INSIDE
# that directory the moment both existed on the same box.
STATE_FILE="${STATE_FILE:-/tmp/thermal-controller/status}"   # written every tick
LOG_FILE="${LOG_FILE:-/tmp/thermal-controller/controller.log}"
ALERT_FILE="${ALERT_FILE:-/tmp/thermal-controller/cool-dip-alert}"

# Optional hook run on the cool-dip alert event (see raise_alert below). Any
# shell command; the event's numbers are passed as THERMAL_ALERT_* env vars.
# Empty = no external notification, the log line and sentinel file still land.
ALERT_CMD="${ALERT_CMD:-}"

# ============================ END CONFIG ====================================

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null

HOT_SINCE_F="$STATE_DIR/hot_since"
COOL_SINCE_F="$STATE_DIR/cool_since"
ALERT_ARMED_F="$STATE_DIR/alert_armed"   # 1 = GPU was above threshold, cool-dip alert may fire on next sustained dip
CPU_HOT_SINCE_F="$STATE_DIR/cpu_hot_since"
CPU_COOL_SINCE_F="$STATE_DIR/cpu_cool_since"
EXT_FAN_COMMANDED_F="$STATE_DIR/external_fan_commanded"   # on|off - what WE last told the external fan, for OVERRIDE attribution

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null
}

_read_state() { cat "$1" 2>/dev/null || echo 0; }
_write_state() { echo "$2" > "$1" 2>/dev/null; }

# Is an external fan configured at all? Neither command set = internal-fans-
# only, and the whole external-fan section of a tick is skipped outright.
_has_external_fan() {
    [[ -n "$EXTERNAL_ON_CMD" || -n "$EXTERNAL_OFF_CMD" ]]
}

# The last state WE commanded ("on"/"off"), or "unknown" if we never have.
# Used as the fallback external-fan reading when a tick has not polled
# EXTERNAL_STATUS_CMD itself, so the snapshot never triggers its own extra
# poll (see _write_snapshot).
_last_commanded_external_fan() {
    local last
    last=$(_read_state "$EXT_FAN_COMMANDED_F")
    [[ "$last" == "on" || "$last" == "off" ]] && echo "$last" || echo "unknown"
}

# Write the current tick's readings atomically (write-tmp-then-mv), so a
# reader never sees a half-written file. $5 is the external-fan state to
# report; the caller decides it (a live poll if one already happened this
# tick, else the last-commanded fallback) - this function never polls itself.
_write_snapshot() {
    local tmp="${STATE_FILE}.tmp.$$"
    {
        echo "ts=$(date +%s)"
        echo "gpu_util_pct=${1:-UNKNOWN}"
        echo "gpu_hot=${2:-0}"
        echo "cpu_mw=${3:-UNKNOWN}"
        echo "cpu_hot=${4:-0}"
        echo "ramp=$(internal_fan_state)"
        echo "external=${5:-none}"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE_FILE" 2>/dev/null
}

# ---------------------------------------------------------------- sensing ---

_log_fresh() {
    [[ -r "$PRESSURE_LOG" ]] || return 1
    local now mtime
    now=$(date +%s)
    mtime=$(stat -f %m "$PRESSURE_LOG" 2>/dev/null || echo 0)
    (( now - mtime <= SENSOR_MAX_AGE ))
}

# Echo the current GPU utilisation percentage, or UNKNOWN when ioreg is
# unreadable or carries no utilisation field. An unreadable read must never be
# treated as idle, or the fan would be switched off on a transient ioreg glitch.
read_gpu_util_pct() {
    local out val
    if [[ -n "$GPU_UTIL_SRC" ]]; then
        out=$(cat "$GPU_UTIL_SRC" 2>/dev/null)
    else
        out=$(ioreg -r -c IOGPU -d 1 -f 2>/dev/null)
    fi
    [[ -n "$out" ]] || { echo "UNKNOWN"; return; }
    val=$(grep -a -oE '"Device Utilization %"=[0-9]+' <<<"$out" | tail -1 | grep -oE '[0-9]+$')
    [[ -n "$val" ]] && echo "$val" || echo "UNKNOWN"
}

# Same contract as read_gpu_util_pct: UNKNOWN on a dead sidecar, never a stale number.
read_cpu_mw() {
    _log_fresh || { echo "UNKNOWN"; return; }
    tail -c 200000 "$PRESSURE_LOG" 2>/dev/null \
        | grep -a -oE '^CPU Power: [0-9]+ mW' \
        | tail -1 | awk '{print $3}' | grep -E '^[0-9]+$' || echo "UNKNOWN"
}

# Thermal pressure is logged for context only; it does not drive decisions.
read_pressure() {
    _log_fresh || { echo "UNKNOWN"; return; }
    tail -c 200000 "$PRESSURE_LOG" 2>/dev/null \
        | grep -a 'Current pressure level:' | tail -1 \
        | sed -E 's/.*Current pressure level:[[:space:]]*//' | tr -d '\r' \
        | grep -E '.' || echo "UNKNOWN"
}

# -------------------------------------------------------------- actuation ---

# "on|off|unknown". Without EXTERNAL_STATUS_CMD the fan can't be polled, so
# the last state WE commanded stands in for it (never "unknown" once we have
# actually asked for something). This IS a live poll when EXTERNAL_STATUS_CMD
# is set - callers that only want the tick's already-known value should use
# _last_commanded_external_fan() instead of calling this a second time.
read_external_fan_state() {
    if [[ -z "$EXTERNAL_STATUS_CMD" ]]; then
        _last_commanded_external_fan
        return
    fi
    bash -c "$EXTERNAL_STATUS_CMD" 2>/dev/null || echo "unknown"
}

set_external_fan() {
    local want="$1" cmd
    # Record what WE asked for, independent of DRY_RUN, so a later OVERRIDE
    # check can tell "we turned it off" from "someone else did".
    _write_state "$EXT_FAN_COMMANDED_F" "$want"
    [[ "$want" == "on" ]] && cmd="$EXTERNAL_ON_CMD" || cmd="$EXTERNAL_OFF_CMD"
    if [[ -z "$cmd" ]]; then
        log "  external fan -> $want FAILED: no command configured for '$want'"
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN external fan -> $want (no call made)"
        return 0
    fi
    log "ACTUATE external fan -> $want"
    bash -c "$cmd" 2>&1 | while read -r l; do log "  external: $l"; done
}

# "ramp" = a live ramp REQUEST is on file for smcfan-rampd, "stock" = auto
# (firmware control), read straight from the control files so an external
# change (someone running smcfan-ctl by hand) is seen rather than assumed.
#
# The ramp desire itself now lives in ramp.json, not desired.json - smcfand
# has no concept of "ramp" any more (see Sources/SMCFand/main.swift), only
# smcfan-rampd does. A ramp.json present and not explicitly marked auto means
# "we want ramp" regardless of what desired.json currently says, since the
# agent may not have caught up to the request yet.
internal_fan_state() {
    if [[ -f "$SMCFAN_RAMP" ]] && ! grep -q '"mode":"auto"' "$SMCFAN_RAMP" 2>/dev/null; then
        echo "ramp"
        return
    fi
    # No desired file means smcfand sits in its fail-safe auto state.
    [[ -f "$SMCFAN_DESIRED" ]] || { echo "stock"; return; }
    case "$(grep -o '"mode":"[a-z]*"' "$SMCFAN_DESIRED" 2>/dev/null)" in
        '"mode":"auto"') echo "stock" ;;
        '')              echo "unknown" ;;
        *)               echo "other" ;;   # constant/full - our own ramp-derived
                                            # value, or set by hand - leave alone
    esac
}

# Best-effort by design: every failure path logs and returns 0, so a missing
# or wedged smcfan-ctl degrades the controller to external-fan-only instead of
# killing the loop.
set_internal_fan() {
    local want="$1"
    case "$want" in
        ramp|stock) ;;
        *) log "  internal fan: refusing unknown target '$want'"; return 0 ;;
    esac

    if (( INTERNAL_FAN_ENABLED == 0 )); then
        log "  internal fan -> $want skipped (INTERNAL_FAN_ENABLED=0)"
        return 0
    fi
    set_internal_fan_smcfan "$want"
    return 0
}

# The controller never touches the SMC itself. It writes the desired state
# through smcfan-ctl; the root daemon applies it and reverts to auto on its
# own when the heartbeat stops.
set_internal_fan_smcfan() {
    local want="$1" out
    if [[ ! -r "$SMCFAN_CTL" ]]; then
        log "  internal fan -> $want FAILED: smcfan-ctl not readable at $SMCFAN_CTL (continuing on external fan)"
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN internal fan -> $want (smcfan-ctl, no call made)"
        return 0
    fi
    case "$want" in
        ramp)  log "ACTUATE internal fan -> ramp (smcfan-ctl ramp $SMCFAN_SENSOR $SMCFAN_MIN_C $SMCFAN_MAX_C $SMCFAN_SMOOTH_S)"
               out=$(bash "$SMCFAN_CTL" ramp "$SMCFAN_SENSOR" "$SMCFAN_MIN_C" "$SMCFAN_MAX_C" "$SMCFAN_SMOOTH_S" 2>&1) ;;
        stock) log "ACTUATE internal fan -> stock (smcfan-ctl auto)"
               out=$(bash "$SMCFAN_CTL" auto 2>&1) ;;
    esac
    local rc=$?
    (( rc == 0 )) || log "  internal fan -> $want FAILED (smcfan-ctl rc=$rc) - continuing on external fan"
    printf '%s\n' "$out" | while read -r l; do [[ -n "$l" ]] && log "  smcfan-ctl: $l"; done
    return 0
}

# Keep the daemon's dead-man switch fed while we want the ramp. Called every
# tick; a no-op whenever the desired mode is not ramp.
smcfan_heartbeat() {
    [[ "$DRY_RUN" == "1" ]] && return 0
    [[ "$(internal_fan_state)" == "ramp" ]] || return 0
    smcfan_liveness_check
    [[ -r "$SMCFAN_CTL" ]] || return 0
    bash "$SMCFAN_CTL" heartbeat >/dev/null 2>&1 || log "  smcfan-ctl heartbeat failed"
    return 0
}

# ramp.json only says what we ASKED for. If smcfand or smcfan-rampd is not
# installed, not running, or wedged, that request actuates nothing and the
# box cools on the external fan alone (if any) - silently, unless someone
# checks. smcfand rewrites status.json every 2s poll regardless of mode, so a
# status.json older than SMCFAN_LIVENESS_SECONDS (or missing) means the
# daemon itself is dead; a fresh status.json whose mode is not yet
# "constant" means the daemon is alive but the ramp REQUEST has not been
# applied yet (typically smcfan-rampd not running, or not yet caught up).
# Latched via a state file: one DEAD line when it stops, one ALIVE line when
# it comes back, never a line per tick.
smcfan_liveness_check() {
    local age now ts mode prev="" cur
    if [[ -f "$SMCFAN_STATUS" ]]; then
        now=$(date +%s)
        ts=$(grep -o '"ts":[0-9]*' "$SMCFAN_STATUS" 2>/dev/null | head -1 | grep -o '[0-9]*$')
        mode=$(grep -o '"mode":"[a-z]*"' "$SMCFAN_STATUS" 2>/dev/null | head -1 | sed -E 's/.*:"//; s/"//')
        if [[ -n "$ts" ]]; then
            age=$(( now - ts ))
            if (( age > SMCFAN_LIVENESS_SECONDS )); then
                cur="dead:status ${age}s stale"
            elif [[ "$mode" != "constant" ]]; then
                cur="dead:status mode=${mode:-unknown} (want constant)"
            else
                cur="alive"
            fi
        else
            cur="dead:status.json missing ts field"
        fi
    else
        cur="dead:no status at $SMCFAN_STATUS"
    fi
    [[ -f "$STATE_DIR/smcfand_liveness" ]] && prev=$(cat "$STATE_DIR/smcfand_liveness")
    if [[ "${cur%%:*}" != "${prev%%:*}" ]]; then
        if [[ "$cur" == "alive" ]]; then
            log "  smcfand ALIVE again - internal ramp is actuating"
        else
            log "  smcfand NOT ALIVE (${cur#dead:}) - ramp requested but NOTHING actuates the internal fans; cooling on the external fan only, if configured."
        fi
        echo "$cur" > "$STATE_DIR/smcfand_liveness"
    fi
    return 0
}

# A detached shell cannot reach an interactive notifier, so the alert is
# published as a log line plus this sentinel file, and (if ALERT_CMD is set)
# one external hook invocation. Whoever watches the episode reads it from
# there. The trigger is the COOL side of an episode: the GPU was above
# threshold and has now dropped below it and stayed there for
# ALERT_AFTER_SECONDS - one notification per dip (see the latch in tick()).
raise_alert() {
    local streak="$1" gpu="$2" fan
    # Last-commanded, not a live poll: raise_alert runs from inside tick(),
    # and tick() never calls EXTERNAL_STATUS_CMD (see the external-fan
    # section above) - an alert must not become a backdoor poll.
    fan=$(_has_external_fan && _last_commanded_external_fan || echo none)
    log "COOL-DIP ALERT: GPU dropped below ${GPU_UTIL_PCT}% and stayed there ${streak}s (>= ${ALERT_AFTER_SECONDS}s), now at ${gpu}%"
    {
        echo "$(date '+%Y-%m-%d %H:%M:%S') COOL-DIP ALERT"
        echo "cool_seconds=$streak"
        echo "gpu_util_pct=$gpu"
        echo "fan=$fan"
    } >> "$ALERT_FILE" 2>/dev/null

    # Best-effort: a failed hook must never stop the controller. DRY_RUN must
    # not fire the hook - a dry-run tick is a test, and a test that fires a
    # real notification is indistinguishable from a real event.
    if [[ "$DRY_RUN" == "1" ]]; then
        log "  DRY-RUN: ALERT_CMD suppressed (log line and sentinel still written)"
    elif [[ -n "$ALERT_CMD" ]]; then
        THERMAL_ALERT_COOL_SECONDS="$streak" \
        THERMAL_ALERT_GPU_UTIL_PCT="$gpu" \
        THERMAL_ALERT_FAN="$fan" \
        THERMAL_ALERT_HOST="$(hostname -s)" \
            bash -c "$ALERT_CMD" >>"$LOG_FILE" 2>&1
        if (( $? == 0 )); then
            log "  ALERT_CMD ran"
        else
            log "  ALERT_CMD FAILED - log line and sentinel still written"
        fi
    fi
}

# Hand the machine back: internal fans to stock, external fan off (if
# configured), hysteresis state cleared. Stopping the daemon without this
# leaves the fans pinned with nothing left running to ever release them.
cmd_reset() {
    local ramp fan
    ramp=$(internal_fan_state)
    if [[ "$ramp" == "stock" ]]; then
        log "RESET internal fans already stock"
    else
        log "RESET internal fans -> stock"
        set_internal_fan stock
    fi

    if _has_external_fan; then
        fan=$(read_external_fan_state)
        if [[ "$fan" == "off" ]]; then
            log "RESET external fan already off"
        else
            log "RESET external fan -> off"
            set_external_fan off
        fi
    fi

    _write_state "$HOT_SINCE_F" 0
    _write_state "$COOL_SINCE_F" 0
    _write_state "$CPU_HOT_SINCE_F" 0
    _write_state "$CPU_COOL_SINCE_F" 0
    _write_state "$ALERT_ARMED_F" 0
    _write_state "$EXT_FAN_COMMANDED_F" off
    log "RESET complete (state cleared)"
}

# On a fresh start the hysteresis counters are empty, so a machine that is
# ALREADY under load would idle through ON_SUSTAIN_SECONDS before the fans
# engage. Seed the counter so an already-loaded box actuates on the first tick;
# the sustain window still applies to load that starts later. UNKNOWN is left
# unseeded so the stale-sidecar fail-safe keeps holding.
prime_state() {
    local gpu cpu seed
    gpu=$(read_gpu_util_pct)
    cpu=$(read_cpu_mw)
    if [[ "$gpu" == "UNKNOWN" || "$cpu" == "UNKNOWN" ]]; then
        log "PRIME gpu=${gpu} cpu=${cpu} - not seeding, fail-safe holds"
        return 0
    fi
    seed=$(( $(date +%s) - ON_SUSTAIN_SECONDS ))
    if (( gpu >= GPU_UTIL_PCT )); then
        _write_state "$HOT_SINCE_F" "$seed"
        _write_state "$COOL_SINCE_F" 0
        log "PRIME gpu=${gpu}% already loaded - both fans engage on first tick"
    else
        log "PRIME gpu=${gpu}% idle - normal hysteresis"
    fi
    if (( cpu >= CPU_LOAD_MW )); then
        _write_state "$CPU_HOT_SINCE_F" "$seed"
        _write_state "$CPU_COOL_SINCE_F" 0
        log "PRIME cpu=${cpu}mW already loaded - internal ramp engages on first tick"
    else
        log "PRIME cpu=${cpu}mW idle - normal hysteresis"
    fi
}

# ------------------------------------------------------------------ tick ----

# Advance one signal's hysteresis pair and echo "<hot|cool> <seconds>".
# Keeping this generic is what lets GPU and CPU run the same sustain rules
# without duplicating the counter bookkeeping twice.
_streak() {
    local hot="$1" hot_f="$2" cool_f="$3" now hot_since cool_since
    now=$(date +%s)
    hot_since=$(_read_state "$hot_f")
    cool_since=$(_read_state "$cool_f")
    if (( hot == 1 )); then
        _write_state "$cool_f" 0
        if (( hot_since == 0 )); then _write_state "$hot_f" "$now"; echo "hot 0"; return 0; fi
        echo "hot $(( now - hot_since ))"
    else
        _write_state "$hot_f" 0
        if (( cool_since == 0 )); then _write_state "$cool_f" "$now"; echo "cool 0"; return 0; fi
        echo "cool $(( now - cool_since ))"
    fi
}

# TWO SIGNALS, DIFFERENT REACH:
#   GPU  -> internal ramp AND the external fan (if configured) - both fans.
#   CPU  -> the internal ramp ONLY. A hot CPU is the laptop's own problem;
#           an external fan, if configured, stays reserved for GPU work.
# So the ramp engages when EITHER signal is sustained-hot, and only returns to
# stock when BOTH are sustained-cool. The external fan follows GPU alone.
tick() {
    local gpu cpu pressure gpu_hot cpu_hot
    local g_state g_secs c_state c_secs
    local g_hot_sust c_hot_sust g_cool_sust c_cool_sust
    local want_ramp want_fan ramp fan alert_armed reason
    local ext_snapshot="none"

    gpu=$(read_gpu_util_pct)
    cpu=$(read_cpu_mw)
    pressure=$(read_pressure)

    if [[ "$gpu" == "UNKNOWN" || "$cpu" == "UNKNOWN" ]]; then
        log "SENSE gpu=${gpu} cpu=${cpu} -> sensor missing or stale, holding (no action)"
        _has_external_fan && ext_snapshot=$(_last_commanded_external_fan)
        _write_snapshot "$gpu" 0 "$cpu" 0 "$ext_snapshot"
        return 0
    fi

    if (( gpu >= GPU_UTIL_PCT )); then gpu_hot=1; else gpu_hot=0; fi
    if (( cpu >= CPU_LOAD_MW )); then cpu_hot=1; else cpu_hot=0; fi
    log "SENSE gpu=${gpu}%(thr${GPU_UTIL_PCT}% hot=${gpu_hot}) cpu=${cpu}mW(thr${CPU_LOAD_MW} hot=${cpu_hot}) pressure=${pressure}"

    read -r g_state g_secs <<<"$(_streak "$gpu_hot" "$HOT_SINCE_F" "$COOL_SINCE_F")"
    read -r c_state c_secs <<<"$(_streak "$cpu_hot" "$CPU_HOT_SINCE_F" "$CPU_COOL_SINCE_F")"

    g_hot_sust=0;  [[ "$g_state" == hot  ]] && (( g_secs >= GPU_ON_SUSTAIN_SECONDS )) && g_hot_sust=1
    c_hot_sust=0;  [[ "$c_state" == hot  ]] && (( c_secs >= ON_SUSTAIN_SECONDS  )) && c_hot_sust=1
    g_cool_sust=0; [[ "$g_state" == cool ]] && (( g_secs >= OFF_SUSTAIN_SECONDS )) && g_cool_sust=1
    c_cool_sust=0; [[ "$c_state" == cool ]] && (( c_secs >= OFF_SUSTAIN_SECONDS )) && c_cool_sust=1

    log "  gpu ${g_state} ${g_secs}s | cpu ${c_state} ${c_secs}s"

    # ---- internal ramp: either signal engages it, both must cool to release ---
    want_ramp=""
    if (( g_hot_sust == 1 || c_hot_sust == 1 )); then
        want_ramp=ramp
        if (( g_hot_sust == 1 && c_hot_sust == 1 )); then reason="gpu+cpu"
        elif (( g_hot_sust == 1 )); then reason="gpu ${gpu}%"
        else reason="cpu ${cpu}mW"; fi
    elif (( g_cool_sust == 1 && c_cool_sust == 1 )); then
        want_ramp=stock
        reason="both idle"
    fi

    if [[ -n "$want_ramp" ]]; then
        ramp=$(internal_fan_state)
        if [[ "$ramp" == "$want_ramp" ]]; then
            log "  internal ramp already ${want_ramp} (${reason})"
        else
            log "  internal ramp ${ramp} -> ${want_ramp} (${reason})"
            set_internal_fan "$want_ramp"
        fi
    fi
    smcfan_heartbeat

    # ---- external fan: GPU only, and only when configured -------------------
    # Edge-triggered on our OWN last-commanded state, never on a live poll:
    # EXTERNAL_STATUS_CMD is never called here, on any tick, by design (see
    # the CONFIG comment above) - a real switch (e.g. Home Assistant) must not
    # be polled every tick just to decide whether to act. This also means a
    # human's manual flip is never detected or fought between crossings: it
    # sticks until the next real threshold crossing commands the opposite
    # state, which is the whole point.
    if _has_external_fan; then
        want_fan=""
        (( g_hot_sust == 1 ))  && want_fan=on
        (( g_cool_sust == 1 )) && want_fan=off

        if [[ -n "$want_fan" ]]; then
            fan=$(_last_commanded_external_fan)
            if [[ "$fan" == "$want_fan" ]]; then
                log "  external fan already ${want_fan} (commanded)"
            else
                log "  external fan ${fan} -> ${want_fan}"
                set_external_fan "$want_fan"
            fi
            ext_snapshot="$want_fan"
        else
            # Nothing to change this tick - the last-commanded value stands in.
            ext_snapshot=$(_last_commanded_external_fan)
        fi
    fi

    # ---- cool-dip alert: GPU episodes only ---------------------------------
    # The trigger is the COOL side of an episode. The latch (ALERT_ARMED_F)
    # ARMS while the GPU is above threshold and FIRES once when it has been
    # below for ALERT_AFTER_SECONDS. It re-arms only after the GPU is back
    # above for ALERT_CLEAR_SECONDS, so a benchmark that flaps across the
    # threshold cannot re-alert on every brief dip.
    if [[ "$g_state" == cool ]]; then
        alert_armed=$(_read_state "$ALERT_ARMED_F")
        # Only alert on a dip that followed a real load period: the latch must
        # be armed (GPU was above threshold) before a cool streak can fire it.
        if (( g_secs >= ALERT_AFTER_SECONDS )) && (( alert_armed == 1 )); then
            raise_alert "$g_secs" "$gpu"
            _write_state "$ALERT_ARMED_F" 0
        fi
    elif (( g_secs >= ALERT_CLEAR_SECONDS )); then
        # Sustained load: arm the latch so the next cool-down alerts once.
        _write_state "$ALERT_ARMED_F" 1
    fi

    _write_snapshot "$gpu" "$gpu_hot" "$cpu" "$cpu_hot" "$ext_snapshot"
}

# ------------------------------------------------------------------ main ----

case "${1:-once}" in
    probe)
        echo "sensor log      : $PRESSURE_LOG"
        echo "gpu_util_pct    : $(read_gpu_util_pct)"
        echo "cpu_mw          : $(read_cpu_mw)"
        echo "threshold_pct   : $GPU_UTIL_PCT"
        echo "cpu_thr_mw      : $CPU_LOAD_MW"
        echo "pressure        : $(read_pressure)"
        if _has_external_fan; then
            echo "external fan    : $(read_external_fan_state)"
        else
            echo "external fan    : (not configured - internal fans only)"
        fi
        echo "internal fan    : $(internal_fan_state) (enabled=$INTERNAL_FAN_ENABLED)"
        echo "dry_run         : $DRY_RUN"
        ;;
    once)
        tick
        ;;
    reset)
        cmd_reset
        ;;
    loop)
        log "== controller ARMED (DRY_RUN=$DRY_RUN, thr=${GPU_UTIL_PCT}%, poll=${POLL_INTERVAL}s, pid=$$) =="
        prime_state
        while true; do
            tick
            sleep "$POLL_INTERVAL"
        done
        ;;
    *)
        echo "usage: $(basename "$0") {once|loop|probe|reset}" >&2
        exit 1
        ;;
esac
