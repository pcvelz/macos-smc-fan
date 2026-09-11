#!/usr/bin/env bash
# test-thermal-cpu-ramp-threshold.sh — RED/GREEN guard for the thermal
# controller's CPU-hot reach, its config-file loading, and its optional
# external-fan/alert hooks.
#
# controller.sh documents two signals with different reach:
#     GPU hot -> internal ramp AND external fan (if configured)
#     CPU hot -> internal ramp ONLY
# All four corners of that reach are pinned here so neither half can regress.
#
# Hermetic: sidecar log, state dir, log file and every actuator/hook are
# stubbed into a temp dir. DRY_RUN=1 throughout — nothing is actuated, no
# external hook is called for real.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROLLER="$REPO/controller.sh"

pass=0
fail=0

PASS() { echo "PASS:  $*"; pass=$((pass + 1)); }
FAIL() { echo "FAIL:  $*"; fail=$((fail + 1)); }

[[ -r "$CONTROLLER" ]] || { echo "FATAL: controller.sh not readable at $CONTROLLER"; exit 1; }

# Keep every case off the machine's real config and daemon state: an
# installed ~/.config/smcfan/thermal.conf would otherwise fill any hook the
# case leaves unset (real EXTERNAL_STATUS_CMD etc.), and the live
# /tmp/smcfan/desired.json would decide the internal-fan state. Cases that
# need either set their own value, which wins over these exports.
_HERMETIC_DIR=$(mktemp -d)
export THERMAL_CONF="$_HERMETIC_DIR/no-such-thermal.conf"
export SMCFAN_DESIRED="$_HERMETIC_DIR/no-such-desired.json"
export SMCFAN_LOG="$_HERMETIC_DIR/no-such-smcfand.log"

# CPU load levels come from the measured distribution documented inline in
# controller.sh. QUIET_MW is an idle-ish desktop that must never ramp.
# BUSY_MW is real sustained CPU work that must ramp.
QUIET_MW=3000
BUSY_MW=10000

# GPU utilisation levels. GPU_IDLE_PCT is genuinely idle. GPU_DESKTOP_PCT is a
# plausible desktop-only baseline that must never ramp either — the whole
# reason the trigger is utilisation with a threshold above the desktop range,
# not power. GPU_BUSY_PCT is a clear sustained-load reading.
GPU_IDLE_PCT=5
GPU_DESKTOP_PCT=60
GPU_BUSY_PCT=95

# Build an isolated scenario dir: synthetic sidecar log, synthetic ioreg GPU
# util dump, and a stub external-fan script. Echoes the dir path.
#   $1 gpu_util_pct  $2 cpu_mw
setup_scenario() {
    local dir gpu_util cpu
    gpu_util="$1"
    cpu="$2"
    dir=$(mktemp -d)

    cat > "$dir/sidecar.log" <<EOF
*** Sampled system activity ***
CPU Power: $cpu mW
ANE Power: 0 mW
**** Thermal pressure ****
Current pressure level: Nominal
EOF

    # read_gpu_util_pct greps this for "Device Utilization %"=N.
    printf '"Device Utilization %%"=%s\n' "$gpu_util" > "$dir/gpu-util.ioreg"

    # Stub external fan: one script, three subcommands, so EXTERNAL_ON_CMD /
    # EXTERNAL_OFF_CMD / EXTERNAL_STATUS_CMD can each point at "$dir/ext-fan.sh <verb>".
    # "off" is the resting state the CPU-only cases must preserve. Every
    # invocation (on/off/status alike) is also appended to ext-fan-calls.log
    # so tests can assert on the NUMBER of calls, not just their content -
    # that is what proves a tick did (or did not) poll/actuate at all.
    cat > "$dir/ext-fan.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$dir/ext-fan-calls.log"
case "\${1:-}" in
    status) echo "off" ;;
    *)      echo "stub-ext-fan called with: \$*" ;;
esac
STUB
    chmod +x "$dir/ext-fan.sh"

    mkdir -p "$dir/state"
    echo "$dir"
}

# Seed the hysteresis counters so a single tick sees an already-sustained
# signal; otherwise the tick reports "hot 0" and reaches no decision until
# ON_SUSTAIN_SECONDS has elapsed in real time.
#   $1 dir, $2 gpu_hot_sustained(1|0), $3 cpu_hot_sustained(1|0)
seed_state() {
    local dir="$1" gpu_hot="$2" cpu_hot="$3" now past
    now=$(date +%s)
    past=$((now - 70))          # > ON_SUSTAIN_SECONDS (60) and > OFF_SUSTAIN (30)

    if (( gpu_hot == 1 )); then
        echo "$past" > "$dir/state/hot_since";  echo 0 > "$dir/state/cool_since"
    else
        echo 0 > "$dir/state/hot_since";        echo "$past" > "$dir/state/cool_since"
    fi
    if (( cpu_hot == 1 )); then
        echo "$past" > "$dir/state/cpu_hot_since";  echo 0 > "$dir/state/cpu_cool_since"
    else
        echo 0 > "$dir/state/cpu_hot_since";        echo "$past" > "$dir/state/cpu_cool_since"
    fi
    echo 0 > "$dir/state/alert_armed"
}

# Run one tick against the scenario (external fan configured) and echo the
# tick's log output.
run_tick() {
    local dir="$1"
    DRY_RUN=1 \
    PRESSURE_LOG="$dir/sidecar.log" \
    GPU_UTIL_SRC="$dir/gpu-util.ioreg" \
    STATE_DIR="$dir/state" \
    LOG_FILE="$dir/controller.log" \
    ALERT_FILE="$dir/cool-dip-alert" \
    STATE_FILE="$dir/state.snapshot" \
    EXTERNAL_ON_CMD="$dir/ext-fan.sh on" \
    EXTERNAL_OFF_CMD="$dir/ext-fan.sh off" \
    EXTERNAL_STATUS_CMD="$dir/ext-fan.sh status" \
    ALERT_CMD="" \
        bash "$CONTROLLER" once 2>&1
}

# Same shape as run_tick, but DRY_RUN=0 so on/off actually invoke the stub
# (DRY_RUN=1 logs the actuation but never calls the command) - needed by
# cases that count real on/off calls, not just the tick's log text.
# INTERNAL_FAN_ENABLED=0 keeps it from touching the real smcfan-ctl.
run_tick_actuate() {
    local dir="$1"
    DRY_RUN=0 \
    INTERNAL_FAN_ENABLED=0 \
    PRESSURE_LOG="$dir/sidecar.log" \
    GPU_UTIL_SRC="$dir/gpu-util.ioreg" \
    STATE_DIR="$dir/state" \
    LOG_FILE="$dir/controller.log" \
    ALERT_FILE="$dir/cool-dip-alert" \
    STATE_FILE="$dir/state.snapshot" \
    EXTERNAL_ON_CMD="$dir/ext-fan.sh on" \
    EXTERNAL_OFF_CMD="$dir/ext-fan.sh off" \
    EXTERNAL_STATUS_CMD="$dir/ext-fan.sh status" \
    ALERT_CMD="" \
        bash "$CONTROLLER" once 2>&1
}

# A scenario's ext-fan.sh whose "status" answer is fixed by the caller - it
# stands in for a human who manually flipped the switch - while still logging
# every invocation, same as the default stub.
setup_manual_stub() {
    local dir="$1" manual_status="$2"
    cat > "$dir/ext-fan.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$dir/ext-fan-calls.log"
case "\${1:-}" in
    status) echo "$manual_status" ;;
    *)      : ;;
esac
STUB
    chmod +x "$dir/ext-fan.sh"
}

echo "== thermal controller: CPU-hot reach =="
echo

# ---- Case A: sustained real CPU work MUST engage the internal ramp ---------
dir=$(setup_scenario "$GPU_IDLE_PCT" "$BUSY_MW")
seed_state "$dir" 0 1
out=$(run_tick "$dir")
if grep -q "ramp (cpu " <<<"$out"; then
    PASS "A: CPU sustained at ${BUSY_MW}mW engages the internal ramp"
else
    FAIL "A: CPU sustained at ${BUSY_MW}mW did NOT engage the internal ramp"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case B: quiet desktop must NOT engage the ramp ------------------------
dir=$(setup_scenario "$GPU_IDLE_PCT" "$QUIET_MW")
seed_state "$dir" 0 0
out=$(run_tick "$dir")
if grep -q "ramp (cpu " <<<"$out"; then
    FAIL "B: quiet CPU at ${QUIET_MW}mW wrongly engaged the internal ramp"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
else
    PASS "B: quiet CPU at ${QUIET_MW}mW leaves the ramp alone"
fi

# ---- Case C: CPU-hot must NOT reach the external fan ------------------------
dir=$(setup_scenario "$GPU_IDLE_PCT" "$BUSY_MW")
seed_state "$dir" 0 1
out=$(run_tick "$dir")
if grep -qE "external fan -> on|external fan off -> on|re-asserting on" <<<"$out"; then
    FAIL "C: CPU-hot wrongly switched the external fan on"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
else
    PASS "C: CPU-hot leaves the external fan off"
fi

# ---- Case D: GPU-hot must reach BOTH fans ----------------------------------
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
out=$(run_tick "$dir")
if grep -q "ramp (gpu " <<<"$out" && grep -qE "external fan (off )?-> on|DRY-RUN external fan -> on" <<<"$out"; then
    PASS "D: GPU sustained at ${GPU_BUSY_PCT}% engages both fans"
else
    FAIL "D: GPU sustained at ${GPU_BUSY_PCT}% did NOT engage both fans"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case E: desktop-level GPU util MUST NEVER turn the fan on -------------
dir=$(setup_scenario "$GPU_DESKTOP_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
out=$(run_tick "$dir")
if grep -qE "external fan (off )?-> on|DRY-RUN external fan -> on|ramp \(gpu " <<<"$out"; then
    FAIL "E: desktop-level GPU util (${GPU_DESKTOP_PCT}%) wrongly engaged a fan"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
else
    PASS "E: desktop-level GPU util (${GPU_DESKTOP_PCT}%) leaves both fans alone"
fi

# ---- Case F: CPU keeps its on-delay ---------------------------------------
dir=$(setup_scenario "$GPU_IDLE_PCT" "$BUSY_MW")
mkdir -p "$dir/state"
out=$(run_tick "$dir")
if grep -q "ramp (cpu " <<<"$out"; then
    FAIL "F: CPU engaged the ramp on the first hot tick (on-delay lost)"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
else
    PASS "F: CPU still serves its on-delay before ramping"
fi

# ---- Case G: GPU util needs a SECOND hot tick, not the first ---------------
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
mkdir -p "$dir/state"
out=$(run_tick "$dir")
if grep -qE "external fan (off )?-> on|DRY-RUN external fan -> on" <<<"$out"; then
    FAIL "G: GPU util engaged the fan on the first hot tick"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
else
    PASS "G: GPU util at ${GPU_BUSY_PCT}% waits for a second hot tick"
fi

# ---- Case H: ...and DOES engage once the second tick lands ----------------
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
out=$(run_tick "$dir")
if grep -qE "external fan (off )?-> on|DRY-RUN external fan -> on" <<<"$out"; then
    PASS "H: GPU util at ${GPU_BUSY_PCT}% engages the fan on the second hot tick"
else
    FAIL "H: GPU util did NOT engage the fan on the second hot tick"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case I: unreadable GPU util holds, same as a dead sidecar ------------
dir=$(setup_scenario "$GPU_BUSY_PCT" "$BUSY_MW")
rm -f "$dir/gpu-util.ioreg"
seed_state "$dir" 1 1
out=$(run_tick "$dir")
if grep -q "sensor missing or stale, holding" <<<"$out" \
    && ! grep -qE "external fan|ramp \(gpu |ramp \(cpu " <<<"$out"; then
    PASS "I: unreadable GPU util holds (no action taken)"
else
    FAIL "I: unreadable GPU util did not hold as expected"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case J: commanded already "on" while GPU stays hot sustained is read
# straight from the commanded state, no poll -------------------------------
# Was: "OVERRIDE only fires when WE last commanded the fan on" - OVERRIDE
# detection required polling EXTERNAL_STATUS_CMD on every sustained tick to
# catch a human's manual flip, which is exactly the "never poll between
# crossings" rule this file's cases a/b/c/d now pin. OVERRIDE (and its poll)
# is gone; this case now pins the replacement behaviour: a commanded state
# that already matches the tick's decision is recognised from the state file
# alone, with zero calls to the external-fan command.
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
echo on > "$dir/state/external_fan_commanded"
out=$(run_tick "$dir")
calls=$([[ -f "$dir/ext-fan-calls.log" ]] && wc -l < "$dir/ext-fan-calls.log" || echo 0)
if grep -q "external fan already on" <<<"$out" && ! grep -q "OVERRIDE" <<<"$out" && [[ "$calls" -eq 0 ]]; then
    PASS "J: commanded-on fan with GPU still hot logs 'already on' with zero calls, no OVERRIDE"
else
    FAIL "J: commanded-on fan with GPU still hot was not recognized without polling (calls=$calls)"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case K: commanded off, then GPU goes hot sustained, is a normal
# transition, NOT an OVERRIDE (OVERRIDE itself is gone - see Case J - but the
# "off -> on on a real crossing" behaviour it used to gate must still work) --
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
echo off > "$dir/state/external_fan_commanded"
out=$(run_tick "$dir")
if grep -q "external fan off -> on" <<<"$out" && ! grep -q "OVERRIDE" <<<"$out"; then
    PASS "K: controller-initiated off then re-hot logs a normal transition"
else
    FAIL "K: controller-initiated off then re-hot was mis-attributed"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- smcfan backend (the internal-fan actuator) ----------------------------
# Same hermetic shape: smcfan-ctl, the desired file and the daemon log are all
# stubbed into the scenario dir. These ticks run DRY_RUN=0 because the smcfan
# path (actuation, heartbeat, liveness) is DRY_RUN-gated; the stubs make that
# safe - the external fan is a stub, ALERT_CMD is empty, smcfan-ctl only echoes.
run_tick_smcfan() {
    local dir="$1"
    DRY_RUN=0 \
    SMCFAN_CTL="$dir/smcfan-ctl" \
    SMCFAN_DESIRED="$dir/desired.json" \
    SMCFAN_LOG="$dir/smcfand.log" \
    PRESSURE_LOG="$dir/sidecar.log" \
    GPU_UTIL_SRC="$dir/gpu-util.ioreg" \
    STATE_DIR="$dir/state" \
    LOG_FILE="$dir/controller.log" \
    ALERT_FILE="$dir/cool-dip-alert" \
    STATE_FILE="$dir/state.snapshot" \
    EXTERNAL_ON_CMD="$dir/ext-fan.sh on" \
    EXTERNAL_OFF_CMD="$dir/ext-fan.sh off" \
    EXTERNAL_STATUS_CMD="$dir/ext-fan.sh status" \
    ALERT_CMD="" \
        bash "$CONTROLLER" once 2>&1
}
setup_smcfan() {
    local dir="$1"
    printf '#!/usr/bin/env bash\necho "stub smcfan-ctl: $*"\n' > "$dir/smcfan-ctl"
    chmod +x "$dir/smcfan-ctl"
}

# ---- Case L: the smcfan backend actuates through smcfan-ctl ---------------
dir=$(setup_scenario "$GPU_IDLE_PCT" "$BUSY_MW"); setup_smcfan "$dir"
seed_state "$dir" 0 1
out=$(run_tick_smcfan "$dir")
if grep -q "smcfan-ctl ramp cpu_core_average 45 75" <<<"$out"; then
    PASS "L: smcfan backend engages the ramp via smcfan-ctl (45-75C on cpu_core_average)"
else
    FAIL "L: smcfan backend did not actuate through smcfan-ctl"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case M: ramp requested, daemon dead -> ONE loud NOT ALIVE line --------
dir=$(setup_scenario "$GPU_IDLE_PCT" "$BUSY_MW"); setup_smcfan "$dir"
seed_state "$dir" 0 1
echo '{"mode":"ramp","sensor":"cpu_core_average","minC":45,"maxC":75,"heartbeat":0}' > "$dir/desired.json"
out1=$(run_tick_smcfan "$dir"); out2=$(run_tick_smcfan "$dir")
if grep -q "smcfand NOT ALIVE" <<<"$out1" && ! grep -q "smcfand NOT ALIVE" <<<"$out2"; then
    PASS "M: dead smcfand under a wanted ramp is reported once (latched)"
else
    FAIL "M: dead smcfand not reported exactly once (tick1: $(grep -c 'NOT ALIVE' <<<"$out1"), tick2: $(grep -c 'NOT ALIVE' <<<"$out2"))"
    echo "--- tick1 ---"; echo "$out1"; echo "--- tick2 ---"; echo "$out2"; echo "-------------"
fi

# ---- Case N: daemon polling (fresh log) -> no false alarm, heartbeat fed ---
dir=$(setup_scenario "$GPU_IDLE_PCT" "$BUSY_MW"); setup_smcfan "$dir"
seed_state "$dir" 0 1
echo '{"mode":"ramp","sensor":"cpu_core_average","minC":45,"maxC":75,"heartbeat":0}' > "$dir/desired.json"
echo "ramp: cpu_core_average=70.0C applied to 2 fans" > "$dir/smcfand.log"
out=$(run_tick_smcfan "$dir")
if ! grep -q "smcfand NOT ALIVE" <<<"$out"; then
    PASS "N: live smcfand (fresh log) raises no liveness alarm"
else
    FAIL "N: live smcfand flagged NOT ALIVE"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case O: stale log (> liveness window) while ramp wanted -> alarm -------
dir=$(setup_scenario "$GPU_IDLE_PCT" "$BUSY_MW"); setup_smcfan "$dir"
seed_state "$dir" 0 1
echo '{"mode":"ramp","sensor":"cpu_core_average","minC":45,"maxC":75,"heartbeat":0}' > "$dir/desired.json"
echo "ramp: cpu_core_average=70.0C applied to 2 fans" > "$dir/smcfand.log"
touch -t "$(date -v-5M +%Y%m%d%H%M.%S)" "$dir/smcfand.log"
out=$(run_tick_smcfan "$dir")
if grep -q "smcfand NOT ALIVE (log [0-9]*s stale)" <<<"$out"; then
    PASS "O: stale smcfand log under a wanted ramp raises the liveness alarm"
else
    FAIL "O: stale smcfand log not flagged"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

echo
echo "== thermal controller: config file loading =="
echo

# run_tick_conf: like run_tick, but drives controller.sh purely via
# THERMAL_CONF (no *_CMD/threshold env vars set), to exercise _load_config.
run_tick_conf() {
    local dir="$1" conf="$2"
    DRY_RUN=1 \
    PRESSURE_LOG="$dir/sidecar.log" \
    GPU_UTIL_SRC="$dir/gpu-util.ioreg" \
    STATE_DIR="$dir/state" \
    LOG_FILE="$dir/controller.log" \
    ALERT_FILE="$dir/cool-dip-alert" \
    STATE_FILE="$dir/state.snapshot" \
    THERMAL_CONF="$conf" \
        bash "$CONTROLLER" once 2>&1
}

# ---- Case P: missing config file -> defaults, no crash --------------------
dir=$(setup_scenario "$GPU_IDLE_PCT" "$QUIET_MW")
seed_state "$dir" 0 0
out=$(run_tick_conf "$dir" "$dir/does-not-exist.conf")
if grep -q " SENSE gpu=" <<<"$out"; then   # log lines are timestamp-prefixed, so no ^ anchor
    PASS "P: a missing config file runs on built-in defaults"
else
    FAIL "P: a missing config file did not run cleanly"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case Q: an unknown key is reported and ignored, known keys still apply
dir=$(setup_scenario "$GPU_IDLE_PCT" "$QUIET_MW")
seed_state "$dir" 0 0
conf="$dir/thermal.conf"
cat > "$conf" <<EOF
# a comment
GPU_UTIL_PCT=50
BOGUS_KEY=nonsense
EOF
out=$(run_tick_conf "$dir" "$conf")
if grep -q "ignoring unknown key 'BOGUS_KEY'" <<<"$out" && grep -q "thr50%" <<<"$out"; then
    PASS "Q: an unknown config key is reported and ignored; known keys still apply"
else
    FAIL "Q: unknown-key handling or known-key application did not behave as expected"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case R: no EXTERNAL_*_CMD configured -> internal fans only, no crash -
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
conf="$dir/thermal.conf"
: > "$conf"
out=$(run_tick_conf "$dir" "$conf")
if grep -qE "external fan" <<<"$out"; then
    FAIL "R: no external hooks configured, but the external-fan section still ran"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
else
    PASS "R: no external hooks configured runs internal-fans-only (external section skipped)"
fi

# ---- Case S: EXTERNAL_*_CMD from the config file actually get invoked -----
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
conf="$dir/thermal.conf"
cat > "$conf" <<EOF
EXTERNAL_ON_CMD=$dir/ext-fan.sh on
EXTERNAL_OFF_CMD=$dir/ext-fan.sh off
EXTERNAL_STATUS_CMD=$dir/ext-fan.sh status
EOF
out=$(run_tick_conf "$dir" "$conf")
if grep -qE "DRY-RUN external fan -> on" <<<"$out"; then
    PASS "S: EXTERNAL_*_CMD read from the config file are used"
else
    FAIL "S: EXTERNAL_*_CMD from the config file were not used"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case T: EXTERNAL_STATUS_CMD absent -> state falls back to the last
# commanded value, same as when it IS configured (tick() never polls it at
# all any more - see cases a/b/c/d - so its presence or absence no longer
# changes tick behaviour; this case now just pins that the fallback path
# still works with the command entirely unset) ------------------------------
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
echo on > "$dir/state/external_fan_commanded"
out=$(DRY_RUN=1 \
      PRESSURE_LOG="$dir/sidecar.log" \
      GPU_UTIL_SRC="$dir/gpu-util.ioreg" \
      STATE_DIR="$dir/state" \
      LOG_FILE="$dir/controller.log" \
      ALERT_FILE="$dir/cool-dip-alert" \
      STATE_FILE="$dir/state.snapshot" \
      EXTERNAL_ON_CMD="$dir/ext-fan.sh on" \
      EXTERNAL_OFF_CMD="$dir/ext-fan.sh off" \
      ALERT_CMD="" \
          bash "$CONTROLLER" once 2>&1)
if grep -q "external fan already on" <<<"$out" && ! grep -q "OVERRIDE" <<<"$out"; then
    PASS "T: without EXTERNAL_STATUS_CMD, state falls back to last-commanded (no OVERRIDE)"
else
    FAIL "T: missing EXTERNAL_STATUS_CMD did not fall back as expected"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

# ---- Case U: the state snapshot file is written every tick ----------------
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
seed_state "$dir" 1 0
run_tick "$dir" >/dev/null
if [[ -f "$dir/state.snapshot" ]] && grep -q "^gpu_util_pct=${GPU_BUSY_PCT}$" "$dir/state.snapshot" \
    && grep -q "^gpu_hot=1$" "$dir/state.snapshot"; then
    PASS "U: the state snapshot file is written with the tick's readings"
else
    FAIL "U: the state snapshot file was not written as expected"
    echo "--- snapshot ---"; cat "$dir/state.snapshot" 2>/dev/null; echo "----------------"
fi

# ---- Case V: the state-snapshot file and the hysteresis dir never collide -
# even under a shared parent shaped like the production layout
# (/tmp/thermal-controller/{status,hysteresis}). A snapshot path that
# resolved to the SAME name as the hysteresis dir would silently move the
# snapshot file INSIDE it instead of writing a sibling.
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
tc_root="$dir/thermal-controller"
hyst_dir="$tc_root/hysteresis"
mkdir -p "$hyst_dir"
now=$(date +%s); past=$((now - 70))
echo "$past" > "$hyst_dir/hot_since";     echo 0 > "$hyst_dir/cool_since"
echo 0 > "$hyst_dir/cpu_hot_since";       echo "$past" > "$hyst_dir/cpu_cool_since"
echo 0 > "$hyst_dir/alert_armed"
out=$(DRY_RUN=1 \
      PRESSURE_LOG="$dir/sidecar.log" \
      GPU_UTIL_SRC="$dir/gpu-util.ioreg" \
      STATE_DIR="$hyst_dir" \
      LOG_FILE="$tc_root/controller.log" \
      ALERT_FILE="$tc_root/cool-dip-alert" \
      STATE_FILE="$tc_root/status" \
      EXTERNAL_ON_CMD="$dir/ext-fan.sh on" \
      EXTERNAL_OFF_CMD="$dir/ext-fan.sh off" \
      EXTERNAL_STATUS_CMD="$dir/ext-fan.sh status" \
      ALERT_CMD="" \
          bash "$CONTROLLER" once 2>&1)
if [[ -f "$tc_root/status" ]] && [[ ! -d "$tc_root/status" ]] && [[ -f "$hyst_dir/hot_since" ]]; then
    PASS "V: STATE_FILE (status) and STATE_DIR (hysteresis) coexist under a shared parent without collision"
else
    FAIL "V: STATE_FILE/STATE_DIR collided or one was not written as expected"
    echo "--- tick output ---"; echo "$out"; echo "--- ls $tc_root ---"; ls -la "$tc_root" 2>&1; echo "-------------------"
fi

# ---- Case W: a tick that does not touch the external-fan section (nothing
# sustained yet) must poll EXTERNAL_STATUS_CMD zero times — the snapshot
# reuses the last-commanded fallback, it never triggers its own extra poll.
# First tick + idle GPU: hysteresis starts empty, so neither g_hot_sust nor
# g_cool_sust is set and the whole external-fan block is skipped. (tick() now
# never calls EXTERNAL_STATUS_CMD at all, even when the block IS entered -
# see cases a/b/c/d - so this is one instance of a now-general rule.)
dir=$(setup_scenario "$GPU_IDLE_PCT" "$QUIET_MW")
mkdir -p "$dir/state"
cat > "$dir/status-count.sh" <<EOSTUB
#!/usr/bin/env bash
echo call >> "$dir/status-calls"
echo off
EOSTUB
chmod +x "$dir/status-count.sh"
out=$(DRY_RUN=1 \
      PRESSURE_LOG="$dir/sidecar.log" \
      GPU_UTIL_SRC="$dir/gpu-util.ioreg" \
      STATE_DIR="$dir/state" \
      LOG_FILE="$dir/controller.log" \
      ALERT_FILE="$dir/cool-dip-alert" \
      STATE_FILE="$dir/status.snapshot" \
      EXTERNAL_ON_CMD="$dir/ext-fan.sh on" \
      EXTERNAL_OFF_CMD="$dir/ext-fan.sh off" \
      EXTERNAL_STATUS_CMD="$dir/status-count.sh" \
      ALERT_CMD="" \
          bash "$CONTROLLER" once 2>&1)
if [[ ! -f "$dir/status-calls" ]]; then
    PASS "W: a tick with no fan action due polls EXTERNAL_STATUS_CMD zero times"
else
    FAIL "W: EXTERNAL_STATUS_CMD was polled $(wc -l < "$dir/status-calls") time(s) on a tick with no fan action due"
    echo "--- tick output ---"; echo "$out"; echo "-------------------"
fi

echo
echo "== thermal controller: external fan is edge-triggered, never polled between crossings =="
echo

# ---- Case a: GPU cool and sustained, we last commanded off, a human has
# manually switched the external fan ON (the status stub reports "on"). The
# controller must make ZERO calls of any kind across several ticks - no
# status poll, no off command - because no threshold crossing happened; the
# manual "on" must stick.
dir=$(setup_scenario "$GPU_IDLE_PCT" "$QUIET_MW")
setup_manual_stub "$dir" "on"
seed_state "$dir" 0 0
echo off > "$dir/state/external_fan_commanded"
run_tick "$dir" >/dev/null
run_tick "$dir" >/dev/null
run_tick "$dir" >/dev/null
calls=$([[ -f "$dir/ext-fan-calls.log" ]] && wc -l < "$dir/ext-fan-calls.log" || echo 0)
if [[ "$calls" -eq 0 ]]; then
    PASS "a: manual fan-on during a sustained-cool episode stays on (zero calls over 3 ticks)"
else
    FAIL "a: manual fan-on during a sustained-cool episode was touched ($calls call(s))"
    echo "--- calls ---"; cat "$dir/ext-fan-calls.log" 2>/dev/null; echo "-------------"
fi

# ---- Case b: GPU hot and sustained, we last commanded on, a human has
# manually switched the external fan OFF during the hot episode (the status
# stub reports "off"). The controller must make ZERO calls across several
# ticks - no status poll, no re-assertion of on - because no threshold
# crossing happened; the manual "off" must stick.
dir=$(setup_scenario "$GPU_BUSY_PCT" "$QUIET_MW")
setup_manual_stub "$dir" "off"
seed_state "$dir" 1 0
echo on > "$dir/state/external_fan_commanded"
run_tick "$dir" >/dev/null
run_tick "$dir" >/dev/null
run_tick "$dir" >/dev/null
calls=$([[ -f "$dir/ext-fan-calls.log" ]] && wc -l < "$dir/ext-fan-calls.log" || echo 0)
if [[ "$calls" -eq 0 ]]; then
    PASS "b: manual fan-off during a sustained-hot episode stays off (zero calls over 3 ticks)"
else
    FAIL "b: manual fan-off during a sustained-hot episode was touched ($calls call(s))"
    echo "--- calls ---"; cat "$dir/ext-fan-calls.log" 2>/dev/null; echo "-------------"
fi

# ---- Case c: a cool -> hot -> cool sequence fires "on" exactly once at the
# crossing into hot, zero calls on every steady-hot tick that follows, and
# "off" exactly once at the crossing back to cool - and never a status poll.
# Each step hand-seeds the hysteresis files the way seed_state does, so the
# sequence does not depend on real wall-clock time between ticks.
dir=$(setup_scenario "$GPU_IDLE_PCT" "$QUIET_MW")
cat > "$dir/ext-fan.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$dir/ext-fan-calls.log"
case "\${1:-}" in
    status) echo "off" ;;
    *)      : ;;
esac
STUB
chmod +x "$dir/ext-fan.sh"
mkdir -p "$dir/state"

seq_tick() {
    local gpu_util="$1"
    printf '"Device Utilization %%"=%s\n' "$gpu_util" > "$dir/gpu-util.ioreg"
    run_tick_actuate "$dir" >/dev/null
}

now=$(date +%s); past=$((now - 70))

# steady cool (already sustained), commanded off
echo 0 > "$dir/state/hot_since";  echo "$past" > "$dir/state/cool_since"
echo off > "$dir/state/external_fan_commanded"
seq_tick "$GPU_IDLE_PCT"

# first hot tick, not yet sustained
echo 0 > "$dir/state/hot_since"
seq_tick "$GPU_BUSY_PCT"

# second hot tick: sustained -> the crossing into hot
echo "$past" > "$dir/state/hot_since"; echo 0 > "$dir/state/cool_since"
seq_tick "$GPU_BUSY_PCT"

# a further steady-hot tick: nothing should change
echo "$past" > "$dir/state/hot_since"
seq_tick "$GPU_BUSY_PCT"

# first cool tick, not yet sustained
echo 0 > "$dir/state/cool_since"
seq_tick "$GPU_IDLE_PCT"

# second cool tick: sustained -> the crossing back to cool
echo "$past" > "$dir/state/cool_since"; echo 0 > "$dir/state/hot_since"
seq_tick "$GPU_IDLE_PCT"

on_calls=$(grep -x 'on' "$dir/ext-fan-calls.log" 2>/dev/null | wc -l | tr -d ' ')
off_calls=$(grep -x 'off' "$dir/ext-fan-calls.log" 2>/dev/null | wc -l | tr -d ' ')
status_calls=$(grep -x 'status' "$dir/ext-fan-calls.log" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$on_calls" -eq 1 && "$off_calls" -eq 1 && "$status_calls" -eq 0 ]]; then
    PASS "c: a cool->hot->cool sequence fires on/off exactly once each, no status poll"
else
    FAIL "c: crossing calls were on=$on_calls off=$off_calls status=$status_calls (want on=1 off=1 status=0)"
    echo "--- calls ---"; cat "$dir/ext-fan-calls.log" 2>/dev/null; echo "-------------"
fi

# ---- Case d: first tick after a fresh start (no commanded-state file at
# all) with GPU already cool and sustained: at most ONE "off" call (bringing
# the state from unknown to a known off), then none on a following tick, and
# never a status poll.
dir=$(setup_scenario "$GPU_IDLE_PCT" "$QUIET_MW")
cat > "$dir/ext-fan.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$dir/ext-fan-calls.log"
case "\${1:-}" in
    status) echo "off" ;;
    *)      : ;;
esac
STUB
chmod +x "$dir/ext-fan.sh"
seed_state "$dir" 0 0
rm -f "$dir/state/external_fan_commanded"
run_tick_actuate "$dir" >/dev/null
run_tick_actuate "$dir" >/dev/null
off_calls=$(grep -x 'off' "$dir/ext-fan-calls.log" 2>/dev/null | wc -l | tr -d ' ')
on_calls=$(grep -x 'on' "$dir/ext-fan-calls.log" 2>/dev/null | wc -l | tr -d ' ')
status_calls=$(grep -x 'status' "$dir/ext-fan-calls.log" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$off_calls" -le 1 && "$on_calls" -eq 0 && "$status_calls" -eq 0 ]]; then
    PASS "d: fresh start with GPU cool makes at most one off call, then none"
else
    FAIL "d: fresh-start behaviour was off=$off_calls on=$on_calls status=$status_calls (want off<=1 on=0 status=0)"
    echo "--- calls ---"; cat "$dir/ext-fan-calls.log" 2>/dev/null; echo "-------------"
fi

echo
echo "== installer: a config missing hook keys must not abort the install =="
echo

# ---- Case e: THERMAL_CONF with none of EXTERNAL_ON_CMD/EXTERNAL_OFF_CMD/
# EXTERNAL_STATUS_CMD/ALERT_CMD set must still install cleanly (rc=0, config
# copied) - install-thermal-agent.sh's per-key `grep ... || true` guard is
# what keeps a `set -euo pipefail` script alive through a no-match grep;
# without it the install aborts partway with the old process left on the
# stale config. Hermetic: HOME points at a scratch dir, launchctl/sudo are
# PATH-stubbed to just log, and a fake smcfan build satisfies the installer's
# smcread/smcfan-ctl guard so it reaches the config-copy step at all. Nothing
# real is ever installed, loaded, or started.
install_dir=$(mktemp -d)
fake_home="$install_dir/home"
# ~/Library/LaunchAgents always exists on a real Mac; the scratch HOME needs
# it created explicitly since nothing else in this test populates it.
mkdir -p "$fake_home/Library/LaunchAgents"

fake_bin="$install_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "launchctl $*" >> "$FAKE_BIN_LOG"
exit 0
STUB
chmod +x "$fake_bin/launchctl"
cat > "$fake_bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >> "$FAKE_BIN_LOG"
"$@"
STUB
chmod +x "$fake_bin/sudo"

fake_smcfan_src="$install_dir/smcfan-src"
mkdir -p "$fake_smcfan_src/Scripts" "$fake_smcfan_src/.build/out/Products/Release"
printf '#!/usr/bin/env bash\necho stub smcfan-ctl\n' > "$fake_smcfan_src/Scripts/smcfan-ctl"
chmod +x "$fake_smcfan_src/Scripts/smcfan-ctl"
printf '#!/usr/bin/env bash\necho stub smcread\n' > "$fake_smcfan_src/.build/out/Products/Release/smcread"
chmod +x "$fake_smcfan_src/.build/out/Products/Release/smcread"

fake_conf="$install_dir/thermal.conf"
cat > "$fake_conf" <<'EOF'
GPU_UTIL_PCT=90
EOF

installer_out=$(env -i \
    HOME="$fake_home" \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FAKE_BIN_LOG="$install_dir/fake-bin.log" \
    THERMAL_CONF="$fake_conf" \
    SMCFAN_SRC="$fake_smcfan_src" \
        bash "$REPO/install-thermal-agent.sh" 2>&1)
installer_rc=$?

dest_conf="$fake_home/Library/Application Support/smcfan/thermal/thermal.conf"
if [[ "$installer_rc" -eq 0 && -f "$dest_conf" ]]; then
    PASS "e: installer with no hook keys configured exits 0 and copies the config"
else
    FAIL "e: installer with no hook keys configured did not complete cleanly (rc=$installer_rc)"
    echo "--- installer output ---"; echo "$installer_out"; echo "------------------------"
fi

echo
echo "passed: $pass, failed: $fail"
(( fail == 0 )) || exit 1
