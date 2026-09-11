# Thermal controller - GPU/CPU-load-driven fan policy

## What is in this directory

| File | Role |
|---|---|
| `controller.sh` | the policy: reads sensors, drives the internal fans and an optional external fan |
| `thermal.conf.example` | every config key, documented; copy to `~/.config/smcfan/thermal.conf` and edit |
| `install-thermal-agent.sh` | installs the LaunchAgent (controller) and LaunchDaemon (powermetrics sidecar) |
| `fan-commands.zsh` | shell commands (`fan-auto`, `fan-off`, `fan-status`) that drive the installed agent |
| `com.smcfan.thermal-controller.plist` / `com.smcfan.powermetrics-sidecar.plist` | LaunchAgent/LaunchDaemon templates the installer fills in and copies |
| `tests/` | hermetic bash tests - no real sensor, no real actuator, `DRY_RUN=1` throughout |

Runtime state (log, hysteresis counters, the machine-readable state snapshot, the
cool-dip sentinel) lives in `/tmp/thermal-controller/` - ephemeral by design,
created on first run.

## What it does

`controller.sh loop` ticks every `POLL_INTERVAL` seconds and drives TWO
actuators off two signals:

- **The internal MacBook fans**, via the `smcfan-ctl`/`smcfand` root daemon in
  this repo (see below) - `ramp` (a linear min-to-max-RPM curve over a
  configurable sensor and temperature range) on load, `auto` (stock) on idle.
  Driven by GPU utilisation OR CPU power - either signal engages it, both must
  cool to release it. Internal actuation is **best-effort**: a missing or
  wedged `smcfan-ctl` logs and returns 0, degrading to external-fan-only (if
  configured) rather than killing the loop. The ramp's temperature input is
  smoothed by `smcfand` with an exponential moving average (`SMCFAN_SMOOTH_S`,
  default 20s) before it hits the curve - `cpu_core_average` jumps >=5C on
  power-gated-core noise in a large fraction of 2s polls, and unsmoothed that
  swings the fan target ~1500 RPM every poll; `0` disables smoothing.
- **An optional external fan**, driven by whatever command you configure
  (`EXTERNAL_ON_CMD` / `EXTERNAL_OFF_CMD` / `EXTERNAL_STATUS_CMD` in
  `thermal.conf` - see `thermal.conf.example`). Driven by GPU utilisation
  only. Leave all three unset and the controller runs internal-fans-only; the
  whole external-fan section of every tick is then skipped, not merely a
  no-op.

**GPU signal: utilisation %, not power.** Read unprivileged via `ioreg -r -c
IOGPU -d 1 -f`, key `"Device Utilization %"`. Ordinary desktop use alone can
read well into the 40-70% range on some machines, so `GPU_UTIL_PCT` should sit
comfortably above your own idle-desktop baseline - measure it first with
`controller.sh probe`. `GPU_UTIL_SRC` overrides the live `ioreg` call with a
file, for hermetic tests.

- **GPU on:** utilisation >= `GPU_UTIL_PCT` for 2 consecutive polls (a single
  crossing is not enough evidence of sustained load once ordinary desktop use
  can graze the high end of its own range).
- **GPU off:** utilisation below threshold for `OFF_SUSTAIN_SECONDS`
  continuous.
- **CPU signal: power**, from the powermetrics sidecar log, drives the
  internal ramp only - a hot CPU is the laptop's own cooling problem, an
  external fan (if configured) stays reserved for GPU work. Threshold
  `CPU_LOAD_MW` with `ON_SUSTAIN_SECONDS` / `OFF_SUSTAIN_SECONDS`.
- **Cool-dip alert:** once the GPU has been above threshold and then drops
  below it for `ALERT_AFTER_SECONDS` continuous, the controller logs one
  `COOL-DIP ALERT` line, appends to the sentinel file `cool-dip-alert`, and
  (if `ALERT_CMD` is configured) runs it once, with the event's numbers passed
  as `THERMAL_ALERT_*` env vars. The latch arms while the GPU is above
  threshold and re-arms only after it is back above for `ALERT_CLEAR_SECONDS`,
  so a benchmark flapping across the threshold cannot re-alert on every brief
  dip.
- **External fan is edge-triggered, never polled:** the tick loop decides
  purely from what it last commanded (`EXT_FAN_COMMANDED_F`), never from a
  live `EXTERNAL_STATUS_CMD` read - it acts only when a threshold crossing
  changes the wanted state, and `EXTERNAL_STATUS_CMD` is never called inside
  `tick()` at all (it remains a manual-diagnostics hook for `probe`/`reset`
  only). This matters because the external fan is often a real switch (e.g.
  a Home Assistant entity) and polling it every tick would spam that backend
  for no reason. One consequence: a human who flips the switch by hand
  between crossings is never detected or fought - the manual state sticks
  until the next real crossing commands the opposite state.
- **Fail-safe:** an unreadable GPU utilisation read, or a missing/stale CPU
  sidecar log (`PRESSURE_LOG`, >60s old), reads as `UNKNOWN` and the
  controller holds rather than acting. A dead sensor must never look like
  idle, or a fan would be switched off mid-load.
- **State snapshot:** every tick writes `/tmp/thermal-controller/status`
  (`KEY=VALUE`, atomic write-then-rename) with the latest readings and
  actuator states, for anything that wants to poll the controller's status
  without parsing the log. The external-fan field reports whatever was
  learned during that tick's own fan-logic section (or the last commanded
  state, if the tick did not touch the fan) - the snapshot never triggers an
  extra `EXTERNAL_STATUS_CMD` call of its own.

## Configuration

All site-specific values (thresholds, sustain windows, the smcfan curve, and
the external-fan/alert hooks) come from a config file, never hardcoded. Path:
`$THERMAL_CONF`, default `~/.config/smcfan/thermal.conf`. See
`thermal.conf.example` for every key. Parsed line by line, never sourced -
only the documented keys can ever be set from it; unknown keys are reported to
stderr and ignored. A missing config file is not an error: the controller runs
on its built-in defaults, internal fans only.

## Start/stop

```
fan-auto              # start (or restart) the installed agent, primed
fan-off               # stop the agent AND hand both actuators back to stock/off
fan-off --keep        # stop the agent, leave the actuators as they are
fan-status            # running/not + last log line
```

`fan-auto` primes: a daemon started on an already-loaded box would otherwise
idle through the sustain windows before engaging, so `controller.sh loop`
seeds the hot counters on start when the box is already loaded. `fan-off`
resets: stopping the loop without resetting the actuators would leave the
internal fans pinned near max with nothing running to release them.

Without the shell functions:

```
DRY_RUN=0 bash controller.sh once     # one tick, real actuation
DRY_RUN=0 bash controller.sh reset    # hand both actuators back
bash controller.sh probe              # print sensor readings only, no action
```

## Cold start - the two-piece chain

Fan control needs BOTH pieces:

```
bash install-thermal-agent.sh                    # LaunchAgent: the controller (no password)
bash install-thermal-agent.sh --install-sidecar  # LaunchDaemon: the CPU-power signal (NEEDS password)
bash install-thermal-agent.sh --status           # is the controller loaded?
```

| Piece | Kind | Why |
|---|---|---|
| `com.smcfan.thermal-controller` | LaunchAgent (user) | runs `controller.sh loop` at login |
| `com.smcfan.powermetrics-sidecar` | LaunchDaemon (root) | produces `/tmp/t1-powermetrics-smc.log` (CPU power) |

- **The sidecar needs root** (`powermetrics` does), so it is a LaunchDaemon
  and its install is the one step that cannot be unattended. Without it the
  controller reads `UNKNOWN` for CPU power forever and holds by fail-safe -
  GPU utilisation is unaffected, since it does not depend on the sidecar, but
  the CPU-hot reach never fires.
- **The agent runs a COPY**, under
  `~/Library/Application Support/smcfan/thermal/`. macOS TCC denies a launchd
  job any read under `~/Documents`, so an agent pointed at a repo checkout
  there dies with status 126 while still looking installed. The config file
  and every hook script it names (each with its whole containing directory,
  so a hook's own sibling dependencies travel with it) are copied too.
  **Re-run the installer after changing any hook script or the config file** -
  the agent otherwise keeps running the stale copy.
- **Deliberately NOT `KeepAlive`** on the controller: the loop has no exit
  path of its own, so `KeepAlive` would only ever fire against a deliberate
  stop, which launchd would then resurrect within seconds. `RunAtLoad` fixes
  the cold start; a deliberate stop stays meaningful.
- The installer bootouts the previous `com.llama-cm.thermal-controller` /
  `com.llama-cm.powermetrics-sidecar` labels if present (migration from an
  earlier, non-generic install) but never installs or runs anything under
  those labels.

## The internal-fan backend: smcfan

Internal fans are driven by this repo's own daemon (see the top-level
README and `docs/ORIGIN.md`). Three pieces:

| Piece | Privilege | Role |
|---|---|---|
| `smcread` | none | in-process AppleSMC reads: temp sensors, `cpu_core_average` / `gpu_cluster_average` aggregates, per-fan actual/target/min/max RPM and mode |
| `smcfand` | root LaunchDaemon | the ONLY SMC writer. Polls `/tmp/smcfan/desired.json` every 2s: `auto`, `ramp <sensor> <min_c> <max_c>` (linear min RPM -> max RPM), `constant <rpm>`, `full`. Starts in auto, reverts to auto on SIGTERM, on a missing/unparseable file, or when the file's heartbeat is older than 60s |
| `smcfan-ctl` | none | writes `desired.json` (`auto\|ramp\|constant\|full\|heartbeat\|status`) |

`controller.sh` calls `smcfan-ctl ramp $SMCFAN_SENSOR $SMCFAN_MIN_C
$SMCFAN_MAX_C` or `smcfan-ctl auto`, and every tick feeds the daemon's
heartbeat while the ramp is wanted. A dead controller therefore hands the fans
back to macOS within a minute.

`desired.json` only records what was ASKED, so a missing or dead daemon under
a wanted ramp would otherwise cool on the external fan alone (if any) with
nothing in the log. While the ramp is wanted the daemon appends an `applied`
line every 2s poll, so `controller.sh` treats a stale/missing daemon log as
"nothing actuates" and logs ONE `smcfand NOT ALIVE` line (latched; one `ALIVE
again` on recovery).

Cutover (the ONE privileged step is the daemon install; do it by hand):

```
cd ..
swift build -c release                # smcread + smcfand
sudo bash Scripts/install-smcfand.sh  # root LaunchDaemon, once
tail -f /tmp/smcfan/smcfand.log       # expect "startup: all fans set to auto"
bash thermal/install-thermal-agent.sh
```

## Tests

```
bash tests/test-thermal-cpu-ramp-threshold.sh
```

Hermetic: sidecar log, state dir, log file and both actuator paths are
stubbed into a temp dir. `DRY_RUN=1` throughout - nothing is actuated, no
external hook is called.
