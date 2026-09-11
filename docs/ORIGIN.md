# Origin

Cloned from https://github.com/agoodkind/macos-smc-fan at commit
`31a1feae0c4999ebd8cdddfbd90d2c98182091b8` on 2026-09-05.

Purpose: scriptable, fail-safe fan control for llama-cm's thermal
controller, built and verified on a Mac16,7 (M4 Pro). Published as the
public fork https://github.com/pcvelz/macos-smc-fan (branch `llama-cm`,
remote `origin`); `upstream` stays a fetch-only reference.

## Architecture (llama-cm fork, branch `llama-cm`)

Upstream's `smcfan`/`SMCFanHelper` design requires a paid Apple Developer
ID cert to code-sign an `SMAppService`/`SMJobBless` privileged helper.
We don't have that, so this fork replaces the privileged surface with a
plain root LaunchDaemon plus a JSON control file, and keeps a completely
separate unprivileged read path.

**Split 2026-09-11: the root daemon is SMC-writer only.** Originally
`smcfand` also owned the sensor-reading, smoothing and ramp-curve logic, so
any change to that policy needed a fresh privileged (sudo) install. That
logic moved out into a second unprivileged piece, `smcfan-rampd`, so the
root daemon should now change rarely enough that reinstalling it becomes a
non-event:

```
smcread (unprivileged, in-process SMCKit)
  reads sensors/fans directly, no daemon
  needed, no root

smcfan-ctl (bash, no privilege)
  auto/constant/full -----------------------> /tmp/smcfan/desired.json
  ramp/heartbeat ------> /tmp/smcfan/ramp.json          ^
                                |                        |
                                v                        |
                  smcfan-rampd (LaunchAgent, no root)    |
                  reads ramp.json + SMC sensors in-      |
                  process, computes a target RPM,        |
                  writes desired.json as `constant` -----+
                                                          |
                                                          v
                                    smcfand (root LaunchDaemon, in-process SMCKit)
                                    owns ALL SMC writes; polls desired.json every
                                    2s; auto/constant/full ONLY - no sensor or
                                    curve logic of its own
```

- **`smcread`** (`Sources/SMCRead/main.swift`) - unprivileged executable.
  Opens `AppleSMC` directly via `SMCConnection` (no XPC, no daemon, no
  root). Never calls `writeKey`. Subcommands: `smcread sensors` (every
  readable temperature key for this hardware generation plus computed
  `cpu_core_average` / `gpu_cluster_average`), `smcread fans` (per-fan
  actual/target/min/max RPM and mode), `smcread all` (default, both).
  Prints one JSON object.

- **`smcfand`** (`Sources/SMCFand/main.swift`) - privileged daemon, meant
  to run as a root LaunchDaemon. Also opens `SMCConnection` in-process
  (same as `smcread`, no XPC), and is the *only* process that ever calls
  `writeKey`. Polls `desired.json` every 2s and applies one of three
  policies to every fan: `auto`, `constant <rpm>` (clamped to each fan's
  own `F%dMn`/`F%dMx`), `full` (max RPM). Holds NO sensor-reading, curve,
  or smoothing logic at all - any `mode` it does not implement (including
  `"ramp"`, which belongs to `smcfan-rampd` now) fails safe to `auto`, same
  as a missing/unparseable file. `auto` needs no heartbeat; `constant`/
  `full` are gated by a heartbeat older than 60s (the only modes that keep
  a fan pinned away from firmware control). Also fails safe to `auto` on
  startup and on `SIGTERM`/`SIGINT` (releasing the `Ftst` diagnostic unlock
  once no fan remains manual). Logs to `/tmp/smcfan/smcfand.log` only on a
  state CHANGE (mode, or target RPM for `constant`) - never once per 2s
  poll - and rewrites `/tmp/smcfan/status.json` every poll regardless
  (`{"ts":...,"mode":...,"fans":[{"index":...,"targetRPM":...,"actualRPM":...}]}`):
  THAT file, not the log, is the liveness signal a consumer should watch
  (see `thermal/controller.sh`'s `smcfan_liveness_check`).

- **`smcfan-rampd`** (`Sources/SMCRampAgent/main.swift`) - unprivileged
  agent, meant to run as a per-user LaunchAgent. Reads a ramp REQUEST from
  `/tmp/smcfan/ramp.json` (sensor, `min_c..max_c`, smoothing tau,
  heartbeat), reads and smooths the requested sensor in-process (same read
  path as `smcread`), computes a target RPM with the same linear curve the
  daemon used to own (`SMCFanKit/FanRamp.swift`, driven through the pure,
  unit-tested decision helper `SMCFanKit/RampAgentDecision.swift` - see
  `Tests/SMCFanKitTests/RampAgentDecisionTests.swift`), and asks `smcfand`
  for it by writing `desired.json` as `constant <rpm>` with a fresh
  heartbeat. If the request is absent, unparseable, explicitly `auto`, or
  its own heartbeat has gone stale (>60s), it writes `auto` to
  `desired.json` ONCE and then stops touching it, rather than fighting
  another writer (e.g. a human running `smcfan-ctl constant` by hand) for
  the file every poll.

- **Control surface**:
  - `/tmp/smcfan/desired.json`, read only by `smcfand`, written by
    `smcfan-ctl` (`auto`/`constant`/`full`) or by `smcfan-rampd` (its own
    computed `constant`, or a one-shot `auto`). Schema:
    `{"mode":"auto","heartbeat":<unix epoch seconds>}` or
    `{"mode":"constant","rpm":4500,"heartbeat":...}` or
    `{"mode":"full","heartbeat":...}`.
  - `/tmp/smcfan/ramp.json`, read only by `smcfan-rampd`, written by
    `smcfan-ctl ramp`/`heartbeat`/`auto`. Schema:
    `{"mode":"ramp","sensor":"cpu_core_average","minC":45,"maxC":75,"smoothS":20,"heartbeat":...}`
    or `{"mode":"auto"}`.
  - `/tmp/smcfan/status.json`, written by `smcfand` every 2s poll
    regardless of mode - the liveness signal (see above).
  - `smcfan-ctl` refreshes `ramp.json`'s `heartbeat` on `ramp`/`heartbeat`;
    a `ramp` request left unrefreshed for 60s is a deliberate dead-man's
    switch (`smcfan-rampd` falls back to `auto`) - run `smcfan-ctl
    heartbeat` from cron/a loop at a sub-60s interval to keep a ramp alive
    unattended. `/tmp/smcfan/smcfand.log` is the daemon's own append log
    (state changes only); `/tmp/smcfan/smcfand.std{out,err}.log` capture
    anything the LaunchDaemon itself redirects.

- **`smcfan-ctl`** (`Scripts/smcfan-ctl`, no privilege needed) - the only
  supported way to talk to the backend: `auto` (clears both control
  files), `ramp <sensor> <min_c> <max_c> [smooth_s]` (a REQUEST to
  `smcfan-rampd`, writes `ramp.json`), `constant <rpm>` / `full` (direct
  to `smcfand`, write `desired.json`), `heartbeat` (refreshes `ramp.json`),
  `status` (prints both control files plus live `smcread fans` output).

- **`LaunchDaemon/com.llama-cm.smcfand.plist`** - `RunAtLoad`/`KeepAlive`
  LaunchDaemon definition pointing at `/usr/local/libexec/smcfand`.

- **`thermal/com.smcfan.smcfan-rampd.plist`** - `RunAtLoad`/`KeepAlive`
  LaunchAgent template for `smcfan-rampd`, filled in and installed (no
  sudo) by `thermal/install-thermal-agent.sh`.

- **`Scripts/install-smcfand.sh`** - the ONE-TIME privileged install step,
  and now the ONLY privileged step in this whole backend (everything else,
  including `smcfan-rampd`, is unprivileged). Not run by any automation in
  this repo. Builds are done unprivileged; this script only copies the
  already-built binary into place and registers the LaunchDaemon. Exact
  command the user runs by hand once, after `swift build -c release
  --product smcfand`:

  ```
  sudo bash Scripts/install-smcfand.sh
  ```

  To remove it later: `sudo launchctl bootout system /Library/LaunchDaemons/com.llama-cm.smcfand.plist`.

### What's still open

- No sensor-driven "linear ramp" existed upstream at all; it's new here
  (`FanRamp.targetRPM`), applied as ONE `constant` value across all fans
  each poll (per-fan curves are possible later but not built) - `smcfand`
  clamps that value to each fan's own `F%dMn`/`F%dMx` independently when it
  applies it, so a single shared target stays safe even across fans whose
  ranges differ.
- `smcread`, `smcfand`'s old ramp path (now gone) and `smcfan-rampd` each
  needed `SensorCatalog.keysForCurrentHardware()`, but the averaging is
  ONE helper (`SMCFanKit/SensorAggregate.swift`, unit tested) so the
  number printed and the number ramped on cannot diverge.
- `smcfand` IS verified on this hardware (Mac16,7, 2026-09-05, before the
  2026-09-11 root/agent split): ramp puts both fans in manual and the
  targets track the core average (5517 RPM at 73.2C, 4217 at 66.2C), auto
  returns them to macOS within one poll. `Ftst` is not needed on this
  generation (runtime-detected), so no `ftst released` line is expected
  here. NOT yet re-verified live since the split moved the curve out to
  `smcfan-rampd` - build/unit-test verified only so far.

### Fixed 2026-09-05 (first live ramp on this box)

- **Power-gated cores read 2-3C and were averaged in.** Witnessed on the
  first live ramp: with six P-cores gated the E-cores read 60C but
  `cpu_core_average` swung 68C -> 44C -> 17C across three polls and the
  ramp sat at minimum RPM under GPU load. `SensorAggregate.average` now
  drops readings at or below a 10C plausibility floor and returns `nil`
  (fail-safe auto) when nothing plausible remains.

### Fixed 2026-09-05 (review before first install)

- `/tmp/smcfan` is created by the daemon itself with mode 1777
  (`ensureControlDir` in `SMCFand/main.swift`). macOS clears `/tmp` at
  boot and the root daemon starts first, so the installer's one-off
  `chmod 1777` never survived a reboot and the unprivileged `smcfan-ctl`
  could not write `desired.json` afterwards.
- `ExitTimeOut 30` on the LaunchDaemon: the SIGTERM path is polled (2s
  loop plus up to 10s for the `Ftst` release), so launchd gets an explicit
  budget before it would SIGKILL mid-release.
- The daemon-liveness gap lives on the CONSUMER side: llama-cm's
  `controller.sh` watches `status.json`'s `ts` age (and that its `mode` has
  reached `constant`) while a ramp is wanted, and logs one `smcfand NOT
  ALIVE` line when nothing is behind the request. Pre-split this watched
  the daemon's OWN log mtime instead (the daemon appended a line every poll
  while ramping) - see "Fixed 2026-09-11" below for why that moved.

### Fixed 2026-09-11 (root/agent split)

- **The root daemon owned sensor reading, smoothing and the ramp curve, so
  any change to that policy needed a fresh sudo install.** Split into two
  pieces: `smcfand` (root, SMC-writer only: `auto`/`constant`/`full`) and
  the new unprivileged `smcfan-rampd` (reads sensors, smooths, computes the
  curve, asks the root daemon for `constant <rpm>`). The root LaunchDaemon
  should now change rarely enough that reinstalling it is a non-event.
- **The per-2s "fail-safe" log line was thousands of lines an hour under a
  steady `auto`** (previously flagged as "log noise" above). `smcfand` now
  logs on a state CHANGE only (mode, or target RPM for `constant`) - an
  explicit `auto` needs no heartbeat and never spams a stale-heartbeat line
  at all.
- **The daemon's log was the only liveness signal, but state-change-only
  logging means it can go quiet for a legitimately healthy reason (a
  steady `constant`).** `smcfand` now writes `/tmp/smcfan/status.json`
  every 2s poll regardless of whether the log changed - THAT file, not the
  log, is what a consumer should watch for liveness.
