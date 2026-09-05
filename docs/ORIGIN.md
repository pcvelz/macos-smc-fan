# Origin

Cloned from https://github.com/agoodkind/macos-smc-fan at commit
`31a1feae0c4999ebd8cdddfbd90d2c98182091b8` on 2026-09-05.

Purpose: local-only, scriptable, fail-safe fan control for llama-cm's
thermal controller on this machine (Mac16,7). Never pushed
anywhere; the `upstream` remote is fetch-only reference, there is no
`origin`.

## Architecture (llama-cm fork, branch `llama-cm`)

Upstream's `smcfan`/`SMCFanHelper` design requires a paid Apple Developer
ID cert to code-sign an `SMAppService`/`SMJobBless` privileged helper.
We don't have that, so this fork replaces the privileged surface with a
plain root LaunchDaemon plus a JSON control file, and keeps a completely
separate unprivileged read path:

```
smcread (unprivileged, in-process SMCKit)      smcfan-ctl (bash, no privilege)
  reads sensors/fans directly, no daemon               |
  needed, no root                                       v
                                          /tmp/smcfan/desired.json
                                                         |
                                                         v
                                    smcfand (root LaunchDaemon, in-process SMCKit)
                                    owns ALL writes; polls desired.json every 2s
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
  `writeKey`. Polls the control file every 2s and applies one of four
  policies to every fan: `auto`, `ramp` (linear interpolation between a
  fan's own `F%dMn`/`F%dMx` over a caller-given `min_c..max_c` window,
  driven by `cpu_core_average` or `gpu_cluster_average` from `smcread`'s
  sensor set - math in `SMCFanKit/FanRamp.swift`, unit tested in
  `Tests/SMCFanKitTests/FanRampTests.swift`), `constant <rpm>`, `full`
  (max RPM). Fail-safe to `auto` (and releases the `Ftst` diagnostic
  unlock once no fan remains manual) on: startup, a missing or
  unparseable control file, or a heartbeat older than 60s. Also
  fails safe on `SIGTERM`/`SIGINT`.

- **Control surface**: `/tmp/smcfan/desired.json`, written only by
  `smcfan-ctl`, read only by `smcfand`. Schema:
  `{"mode":"auto","heartbeat":<unix epoch seconds>}` or
  `{"mode":"ramp","sensor":"cpu_core_average","minC":45,"maxC":75,"heartbeat":...}` or
  `{"mode":"constant","rpm":4500,"heartbeat":...}` or
  `{"mode":"full","heartbeat":...}`. `smcfan-ctl` refreshes `heartbeat`
  on every mutating call; a `ramp`/`constant` policy left unrefreshed for
  60s is a deliberate dead-man's switch - run `smcfan-ctl heartbeat` from
  cron/a loop at a sub-60s interval to keep a non-auto policy alive
  unattended. `/tmp/smcfan/smcfand.log` is the daemon's own append log;
  `/tmp/smcfan/smcfand.std{out,err}.log` capture anything the LaunchDaemon
  itself redirects.

- **`smcfan-ctl`** (`Scripts/smcfan-ctl`, no privilege needed) - the only
  supported way to talk to `smcfand`: `auto`, `ramp <sensor> <min_c>
  <max_c>`, `constant <rpm>`, `full`, `heartbeat`, `status` (prints
  `desired.json` plus live `smcread fans` output).

- **`LaunchDaemon/com.llama-cm.smcfand.plist`** - `RunAtLoad`/`KeepAlive`
  LaunchDaemon definition pointing at `/usr/local/libexec/smcfand`.

- **`Scripts/install-smcfand.sh`** - the ONE-TIME privileged install step.
  Not run by any automation in this repo. Builds are done unprivileged;
  this script only copies the already-built binary into place and
  registers the LaunchDaemon. Exact command the user runs by hand once,
  after `swift build -c release --product smcfand`:

  ```
  sudo bash Scripts/install-smcfand.sh
  ```

  To remove it later: `sudo launchctl bootout system /Library/LaunchDaemons/com.llama-cm.smcfand.plist`.

### What's still open

- No sensor-driven "linear ramp" existed upstream at all; it's new here
  (`FanRamp.targetRPM`), applied identically to both fans per the ramp
  request (per-fan curves are possible later but not built).
- `smcread` and `smcfand` each read `SensorCatalog.keysForCurrentHardware()`
  themselves, but the averaging is now ONE helper
  (`SMCFanKit/SensorAggregate.swift`, unit tested) so the number printed
  and the number ramped on cannot diverge.
- `smcfand` IS verified on this hardware (Mac16,7, 2026-09-05): ramp
  puts both fans in manual and the targets track the core average
  (5517 RPM at 73.2C, 4217 at 66.2C), auto returns them to macOS within
  one poll. `Ftst` is not needed on this generation (runtime-detected),
  so no `ftst released` line is expected here.
- Log noise: while the control file is missing or its heartbeat stale the
  daemon logs one fail-safe line per 2s poll. Harmless; collapse to a
  single line per state change when it bothers someone.
- The ramp is a straight line from `F%dMn` to `F%dMx` over `minC..maxC`,
  re-targeted every 2s from the aggregate with no smoothing, so it can run
  the fans harder than a smoothed controller at the same reading - the
  safe direction; tune `maxC` upward or add smoothing if the noise is
  unwanted.

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
  `controller.sh` watches this daemon's log mtime while a ramp is wanted
  (the daemon appends an `applied` line every poll in ramp mode) and
  logs one `smcfand NOT ALIVE` line when nothing is behind the request.
