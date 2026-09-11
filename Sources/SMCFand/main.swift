//
//  main.swift
//  smcfand
//
//  Privileged (root) fan-control daemon. Reads a desired-state JSON file
//  written by `smcfan-ctl`, applies a ramp/constant/full/auto policy to
//  every fan, and fails safe to auto whenever the desired state is
//  missing, unparseable, or stale. Intended to run under a LaunchDaemon
//  (see LaunchDaemon/com.llama-cm.smcfand.plist); NOT executed by any
//  automation in this repo - the one-time `launchctl bootstrap` install
//  is a manual, documented, sudo step (Scripts/install-smcfand.sh).
//
//  Control file: /tmp/smcfan/desired.json (see ORIGIN.md "Control
//  surface" for the exact schema). Log file: /tmp/smcfan/smcfand.log.
//

import Foundation
import SMCFanKit
import SMCKit

// MARK: - Configuration

private let controlDir = "/tmp/smcfan"
private let desiredStatePath = controlDir + "/desired.json"
private let logPath = controlDir + "/smcfand.log"
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
  var sensor: String?
  var minC: Double?
  var maxC: Double?
  var rpm: Double?
  var heartbeat: Double?
  var smoothS: Double?
}

enum ResolvedMode {
  case auto
  case ramp(sensor: String, minC: Double, maxC: Double, smoothS: Double)
  case constant(rpm: Double)
  case full
}

/// Default EMA time constant (seconds) when desired.json omits `smoothS`.
/// Matches Scripts/smcfan-ctl's default so a ctl caller that leaves the arg
/// off gets the same smoothing the daemon assumes.
private let defaultSmoothS: Double = 20

func resolveDesiredMode() -> ResolvedMode {
  guard let data = FileManager.default.contents(atPath: desiredStatePath) else {
    logLine("desired.json missing -> auto (fail-safe)")
    return .auto
  }
  guard let state = try? JSONDecoder().decode(DesiredState.self, from: data) else {
    logLine("desired.json unparseable -> auto (fail-safe)")
    return .auto
  }
  if let heartbeat = state.heartbeat {
    let age = Date().timeIntervalSince1970 - heartbeat
    if age > staleHeartbeatSeconds {
      logLine("heartbeat stale (\(Int(age))s) -> auto (fail-safe)")
      return .auto
    }
  } else {
    logLine("desired.json missing heartbeat -> auto (fail-safe)")
    return .auto
  }

  switch state.mode {
  case "auto":
    return .auto
  case "ramp":
    guard let sensor = state.sensor, let minC = state.minC, let maxC = state.maxC else {
      logLine("ramp mode missing sensor/minC/maxC -> auto (fail-safe)")
      return .auto
    }
    return .ramp(sensor: sensor, minC: minC, maxC: maxC, smoothS: state.smoothS ?? defaultSmoothS)
  case "constant":
    guard let rpm = state.rpm else {
      logLine("constant mode missing rpm -> auto (fail-safe)")
      return .auto
    }
    return .constant(rpm: rpm)
  case "full":
    return .full
  default:
    logLine("unknown mode '\(state.mode)' -> auto (fail-safe)")
    return .auto
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

  func averageTemperature(sensorName: String) -> Float? {
    let allKeys = SensorCatalog.keysForCurrentHardware().filter { $0.type == .temperature }
    let group: SensorGroup?
    switch sensorName {
    case "cpu_core_average": group = .cpu
    case "gpu_cluster_average": group = .gpu
    default: group = nil
    }
    guard let group else { return nil }

    var values: [Float] = []
    for sensor in allKeys where sensor.group == group {
      guard let (bytes, size) = try? connection.readKey(sensor.key) else { continue }
      values.append(SMCDataFormat.float(from: bytes, size: size))
    }
    // Shared with smcread; drops power-gated cores that report 2-3C, which
    // would otherwise pin the ramp at min RPM under load (see SensorAggregate).
    return SensorAggregate.average(values)
  }
}

// MARK: - Ramp temperature smoothing

// Rebuilt whenever the ramp's sensor or requested tau changes, or the
// daemon leaves/re-enters ramp mode - carrying a stale EMA across a
// mode/sensor switch would blend readings from an unrelated stream.
private var rampSmoother = TemperatureSmoother(tau: defaultSmoothS)
private var lastRampSensor: String?
private var lastRampSmoothS: Double?

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

while !shouldExit {
  let mode = resolveDesiredMode()
  let fanCount = writer.fanCount()

  if case let .ramp(sensorName, _, _, smoothS) = mode {
    // Reset the smoother across a sensor or tau change, or on re-entering
    // ramp after any other mode - never blend across an unrelated stream.
    if lastRampSensor != sensorName || lastRampSmoothS != smoothS {
      rampSmoother = TemperatureSmoother(tau: smoothS)
      lastRampSensor = sensorName
      lastRampSmoothS = smoothS
    }
  } else if lastRampSensor != nil {
    rampSmoother.reset()
    lastRampSensor = nil
    lastRampSmoothS = nil
  }

  switch mode {
  case .auto:
    for fan in 0..<fanCount where writer.isManual(fan: fan) {
      writer.setFanAuto(fan: fan)
      logLine("fan\(fan): set to auto")
    }

  case let .ramp(sensorName, minC, maxC, _):
    guard let rawTemperature = writer.averageTemperature(sensorName: sensorName) else {
      logLine("ramp: sensor '\(sensorName)' unavailable -> auto (fail-safe)")
      for fan in 0..<fanCount where writer.isManual(fan: fan) {
        writer.setFanAuto(fan: fan)
      }
      break
    }
    let temperature = rampSmoother.update(rawTemperature) ?? rawTemperature
    for fan in 0..<fanCount {
      let minRPM = writer.readFloat(SMCFanKey.minimum, fan: fan)
      let maxRPM = writer.readFloat(SMCFanKey.maximum, fan: fan)
      let target = FanRamp.targetRPM(
        temperatureC: temperature, minC: Float(minC), maxC: Float(maxC), minRPM: minRPM,
        maxRPM: maxRPM)
      writer.setFanRPM(fan: fan, rpm: target)
    }
    logLine(
      "ramp: \(sensorName) raw=\(String(format: "%.1f", rawTemperature))C "
        + "smoothed=\(String(format: "%.1f", temperature))C applied to \(fanCount) fans")

  case let .constant(rpm):
    for fan in 0..<fanCount {
      writer.setFanRPM(fan: fan, rpm: Float(rpm))
    }
    logLine("constant: \(Int(rpm)) RPM applied to \(fanCount) fans")

  case .full:
    for fan in 0..<fanCount {
      let maxRPM = writer.readFloat(SMCFanKey.maximum, fan: fan)
      writer.setFanRPM(fan: fan, rpm: maxRPM)
    }
    logLine("full: max RPM applied to \(fanCount) fans")
  }

  Thread.sleep(forTimeInterval: pollInterval)
}

logLine("received termination signal -> fail-safe: setting all fans to auto")
writer.setAllFansAuto()
logLine("smcfand exiting cleanly")
