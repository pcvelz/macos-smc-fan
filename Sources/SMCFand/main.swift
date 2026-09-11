//
//  main.swift
//  smcfand
//
//  Privileged (root) fan-control daemon. Reads a desired-state JSON file
//  written by `smcfan-ctl`/`smcfan-rampd`, applies auto/constant/full to
//  every fan, and fails safe to auto whenever the desired state is
//  missing, unparseable, stale, or names a mode this daemon does not
//  understand. Intended to run under a LaunchDaemon (see
//  LaunchDaemon/com.llama-cm.smcfand.plist); NOT executed by any
//  automation in this repo - the one-time `launchctl bootstrap` install
//  is a manual, documented, sudo step (Scripts/install-smcfand.sh).
//
//  This daemon is SMC-writer only - it holds no sensor-reading, smoothing,
//  or ramp-curve logic at all (that lives in the unprivileged
//  Sources/SMCRampAgent, which computes a target RPM and asks for it via
//  `constant`, same as a human would). Keeping this half of the split this
//  small is the point: the root LaunchDaemon should change so rarely that a
//  reinstall (which needs sudo) becomes a non-event.
//
//  Control file: /tmp/smcfan/desired.json (see ORIGIN.md "Control
//  surface" for the exact schema). Log file: /tmp/smcfan/smcfand.log,
//  written only on a state CHANGE (never once per 2s poll) to keep it
//  from growing unbounded while a policy is held steady. Status file:
//  /tmp/smcfan/status.json, rewritten every poll - this, not the log, is
//  the liveness signal a consumer (thermal/controller.sh) should watch.
//

import Foundation
import SMCFanKit
import SMCKit

// MARK: - Configuration

private let controlDir = "/tmp/smcfan"
private let desiredStatePath = controlDir + "/desired.json"
private let logPath = controlDir + "/smcfand.log"
private let statusPath = controlDir + "/status.json"
private let pollInterval: TimeInterval = 2.0
private let staleHeartbeatSeconds: TimeInterval = 60.0

// MARK: - Logging

private let logQueue = DispatchQueue(label: "smcfand.log")

/// The control directory must be writable by the UNPRIVILEGED smcfan-ctl.
/// macOS clears /private/tmp at boot and this daemon (root) starts before any
/// user process, so the daemon itself has to create the directory
/// world-writable (sticky, 1777) - the installer's one-off chmod does not
/// survive a reboot. Re-applied on every call: cheap, and it also repairs a
/// directory something else created with restrictive permissions.
func ensureControlDir() {
  let fm = FileManager.default
  let perms: [FileAttributeKey: Any] = [.posixPermissions: 0o1777]
  if !fm.fileExists(atPath: controlDir) {
    try? fm.createDirectory(
      atPath: controlDir, withIntermediateDirectories: true, attributes: perms)
  }
  // createDirectory honours the umask; setAttributes does not.
  try? fm.setAttributes(perms, ofItemAtPath: controlDir)
}

func logLine(_ message: String) {
  logQueue.sync {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) \(message)\n"
    ensureControlDir()
    if let handle = FileHandle(forWritingAtPath: logPath) {
      handle.seekToEndOfFile()
      handle.write(line.data(using: .utf8)!)
      handle.closeFile()
    } else {
      FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
    FileHandle.standardError.write(line.data(using: .utf8)!)
  }
}

// MARK: - Desired state schema

struct DesiredState: Codable {
  var mode: String
  var rpm: Double?
  var heartbeat: Double?
}

/// Everything this daemon can DO to a fan. Sensor curves ("ramp") are not a
/// case here on purpose - smcfand has no sensor-reading or smoothing logic
/// left; a curve is computed by smcfan-rampd and arrives as `constant`.
enum ResolvedMode: Equatable {
  case auto
  case constant(rpm: Double)
  case full
}

struct Resolution {
  let mode: ResolvedMode
  let reason: String
}

/// Interprets desired.json into what this daemon should actually do.
/// `auto` needs no heartbeat at all - it is always safe and never stale.
/// `constant`/`full` are the only modes gated by the heartbeat dead-man
/// switch, since they are the only modes that keep a fan pinned away from
/// firmware control. Any mode this daemon does not implement (including
/// `ramp`, which now belongs to smcfan-rampd, and any unrecognised string)
/// fails safe to auto.
func resolveDesiredMode() -> Resolution {
  guard let data = FileManager.default.contents(atPath: desiredStatePath) else {
    return Resolution(mode: .auto, reason: "desired.json missing")
  }
  guard let state = try? JSONDecoder().decode(DesiredState.self, from: data) else {
    return Resolution(mode: .auto, reason: "desired.json unparseable")
  }

  switch state.mode {
  case "auto":
    return Resolution(mode: .auto, reason: "requested auto")

  case "constant":
    guard let rpm = state.rpm else {
      return Resolution(mode: .auto, reason: "constant mode missing rpm")
    }
    guard let heartbeat = state.heartbeat,
      Date().timeIntervalSince1970 - heartbeat <= staleHeartbeatSeconds
    else {
      return Resolution(mode: .auto, reason: "constant requested but heartbeat missing/stale")
    }
    return Resolution(mode: .constant(rpm: rpm), reason: "requested constant \(Int(rpm)) RPM")

  case "full":
    guard let heartbeat = state.heartbeat,
      Date().timeIntervalSince1970 - heartbeat <= staleHeartbeatSeconds
    else {
      return Resolution(mode: .auto, reason: "full requested but heartbeat missing/stale")
    }
    return Resolution(mode: .full, reason: "requested full")

  default:
    // Includes "ramp" (owned by smcfan-rampd now, not this daemon) and any
    // unrecognised string - both fail safe to auto rather than guessing.
    return Resolution(
      mode: .auto,
      reason:
        "mode '\(state.mode)' not understood by smcfand (ramp curves are computed by smcfan-rampd, applied here as constant) -> auto")
  }
}

// MARK: - Fan control primitives (this daemon is the sole writer; no arbitration)

final class DaemonFanWriter {
  let connection: SMCConnection
  let controller: FanController

  init() throws {
    self.connection = try SMCConnection()
    self.controller = FanController(connection: connection)
  }

  func fanCount() -> Int {
    guard let (bytes, _) = try? connection.readKey(SMCFanKey.count), !bytes.isEmpty else { return 0 }
    return Int(bytes[0])
  }

  func readFloat(_ template: String, fan: Int) -> Float {
    let key = SMCFanKey.key(template, fan: fan)
    guard let (bytes, size) = try? connection.readKey(key) else { return 0 }
    return SMCDataFormat.float(from: bytes, size: size)
  }

  func isManual(fan: Int) -> Bool {
    let modeKey = SMCFanKey.key(controller.config.modeKeyFormat, fan: fan)
    guard let (bytes, _) = try? connection.readKey(modeKey), !bytes.isEmpty else { return false }
    return bytes[0] == 1
  }

  /// Sets one fan to a manual target RPM, enabling manual mode first if needed.
  func setFanRPM(fan: Int, rpm: Float) {
    if !isManual(fan: fan) {
      do {
        _ = try controller.enableManualMode(fanIndex: fan)
      } catch {
        logLine("fan\(fan): enableManualMode failed: \(error)")
        return
      }
    }
    let key = SMCFanKey.key(SMCFanKey.target, fan: fan)
    let bytes = SMCDataFormat.bytes(from: rpm, size: 4)
    do {
      try connection.writeKey(key, bytes: bytes)
    } catch {
      logLine("fan\(fan): writeKey target failed: \(error)")
    }
  }

  /// Sets one fan back to automatic control and, if no other fan remains
  /// manual, releases the Ftst diagnostic unlock.
  func setFanAuto(fan: Int) {
    guard isManual(fan: fan) else { return }

    let modeKey = SMCFanKey.key(controller.config.modeKeyFormat, fan: fan)
    do {
      try connection.writeKey(modeKey, bytes: [0])
    } catch {
      logLine("fan\(fan): auto mode write failed: \(error)")
    }

    let targetKey = SMCFanKey.key(SMCFanKey.target, fan: fan)
    do {
      try connection.writeKey(targetKey, bytes: SMCDataFormat.bytes(from: 0, size: 4))
    } catch {
      logLine("fan\(fan): target reset failed: \(error)")
    }

    let anyOtherManual = (0..<fanCount()).contains { $0 != fan && isManual(fan: $0) }
    if !anyOtherManual, controller.config.ftstAvailable {
      do {
        try controller.resetFanControl()
        logLine("ftst released (no fans remain manual)")
      } catch {
        logLine("ftst release failed: \(error)")
      }
    }
  }

  func setAllFansAuto() {
    for fan in 0..<fanCount() {
      setFanAuto(fan: fan)
    }
  }
}

/// Clamps a requested RPM to one fan's own [F%dMn, F%dMx] range. A degenerate
/// reading (max not strictly above min - e.g. an SMC read glitch returning
/// 0/0) means the hardware range is not trustworthy this poll, so the
/// request is passed through unclamped rather than forced to a guessed value.
func clampToFanRange(_ rpm: Float, minRPM: Float, maxRPM: Float) -> Float {
  guard maxRPM > minRPM else { return rpm }
  return Swift.min(Swift.max(rpm, minRPM), maxRPM)
}

/// A dedupe key for the log: distinct only when what the daemon is actually
/// DOING changes (mode, and target RPM for `constant`). Different fail-safe
/// REASONS for landing on the same mode (missing file vs stale heartbeat vs
/// an unknown mode string) collapse to the same key on purpose - the log
/// line for entering that state carries the reason, but re-entering it for a
/// different reason is not a new state.
func stateKey(_ mode: ResolvedMode) -> String {
  switch mode {
  case .auto: return "auto"
  case .full: return "full"
  case let .constant(rpm): return "constant:\(Int(rpm))"
  }
}

func modeName(_ mode: ResolvedMode) -> String {
  switch mode {
  case .auto: return "auto"
  case .full: return "full"
  case .constant: return "constant"
  }
}

// MARK: - Status file (the liveness signal; written every poll regardless of
// whether the log line changed, so a consumer can always tell the daemon is
// alive and see the fans it is currently asking for)

struct FanStatusEntry: Codable {
  let index: Int
  let targetRPM: Float
  let actualRPM: Float
}

struct DaemonStatus: Codable {
  let ts: Int
  let mode: String
  let fans: [FanStatusEntry]
}

func writeStatus(mode: String, writer: DaemonFanWriter, fanCount: Int) {
  var fans: [FanStatusEntry] = []
  for fan in 0..<fanCount {
    let target = writer.readFloat(SMCFanKey.target, fan: fan)
    let actual = writer.readFloat(SMCFanKey.actual, fan: fan)
    fans.append(FanStatusEntry(index: fan, targetRPM: target, actualRPM: actual))
  }
  let status = DaemonStatus(ts: Int(Date().timeIntervalSince1970), mode: mode, fans: fans)
  guard let data = try? JSONEncoder().encode(status) else { return }

  ensureControlDir()
  let tmpPath = statusPath + ".tmp"
  FileManager.default.createFile(atPath: tmpPath, contents: data)
  try? FileManager.default.removeItem(atPath: statusPath)
  try? FileManager.default.moveItem(atPath: tmpPath, toPath: statusPath)
}

// MARK: - Signal handling (fail-safe on termination)

private var shouldExit = false

signal(SIGTERM) { _ in shouldExit = true }
signal(SIGINT) { _ in shouldExit = true }

// MARK: - Main

logLine("smcfand starting; control file: \(desiredStatePath)")

guard let writer = try? DaemonFanWriter() else {
  logLine("FATAL: could not open AppleSMC connection")
  exit(1)
}

// Startup invariant: always begin in auto, regardless of any stale
// desired.json left over from a previous run.
writer.setAllFansAuto()
logLine("startup: all fans set to auto")

private var lastStateKey: String?

while !shouldExit {
  let resolution = resolveDesiredMode()
  let fanCount = writer.fanCount()
  let key = stateKey(resolution.mode)

  if key != lastStateKey {
    logLine("state -> \(key) (\(resolution.reason))")
    lastStateKey = key
  }

  switch resolution.mode {
  case .auto:
    for fan in 0..<fanCount where writer.isManual(fan: fan) {
      writer.setFanAuto(fan: fan)
    }

  case let .constant(rpm):
    for fan in 0..<fanCount {
      let minRPM = writer.readFloat(SMCFanKey.minimum, fan: fan)
      let maxRPM = writer.readFloat(SMCFanKey.maximum, fan: fan)
      let clamped = clampToFanRange(Float(rpm), minRPM: minRPM, maxRPM: maxRPM)
      writer.setFanRPM(fan: fan, rpm: clamped)
    }

  case .full:
    for fan in 0..<fanCount {
      let maxRPM = writer.readFloat(SMCFanKey.maximum, fan: fan)
      writer.setFanRPM(fan: fan, rpm: maxRPM)
    }
  }

  writeStatus(mode: modeName(resolution.mode), writer: writer, fanCount: fanCount)

  Thread.sleep(forTimeInterval: pollInterval)
}

logLine("received termination signal -> fail-safe: setting all fans to auto")
writer.setAllFansAuto()
logLine("smcfand exiting cleanly")
