//
//  main.swift
//  smcfan-rampd
//
//  Unprivileged fan-ramp agent, meant to run as a per-user LaunchAgent (see
//  thermal/install-thermal-agent.sh). Reads a ramp REQUEST written by
//  Scripts/smcfan-ctl (`/tmp/smcfan/ramp.json`), reads and smooths the
//  requested temperature sensor in-process (same read path as `smcread`, no
//  daemon, no root), computes a target RPM with the same linear curve the
//  root daemon used to own (`SMCFanKit.FanRamp`, via the pure decision
//  helper `SMCFanKit.RampAgentDecision`), and asks the root daemon
//  (`smcfand`) for it by writing `/tmp/smcfan/desired.json` as
//  `constant <rpm>` with a fresh heartbeat.
//
//  smcfand itself understands only auto/constant/full and knows nothing
//  about sensors, curves, or smoothing - this agent is where all of that
//  logic now lives, entirely outside the privileged root daemon. That split
//  is the point: the root LaunchDaemon should change so rarely that
//  reinstalling it (which needs sudo) becomes a non-event, while this agent
//  can be rebuilt and reinstalled without a password.
//
//  If the ramp request is absent, unparseable, explicitly `auto`, or its own
//  heartbeat has gone stale (>60s - Scripts/smcfan-ctl's `ramp`/`heartbeat`
//  subcommands refresh it), this agent writes `auto` to desired.json ONCE
//  and then stops touching it - it does not fight over desired.json with
//  whatever else last set it (a human running `smcfan-ctl constant` by
//  hand, for instance).
//

import Foundation
import SMCFanKit
import SMCKit

// MARK: - Configuration

private let controlDir = "/tmp/smcfan"
private let rampPath = controlDir + "/ramp.json"
private let desiredPath = controlDir + "/desired.json"
private let pollInterval: TimeInterval = 2.0
private let staleAfter: TimeInterval = 60.0
// Smallest target change worth a new fan write (see RampAgentDecision.applyDeadband).
private let rpmDeadband: Float = 100

// MARK: - ramp.json schema (written by Scripts/smcfan-ctl)

struct RampRequestFile: Codable {
  var mode: String
  var sensor: String?
  var minC: Double?
  var maxC: Double?
  var smoothS: Double?
  var heartbeat: Double?
}

/// `nil` covers every reason the agent should treat there as being no live
/// ramp request: the file is missing, unparseable, explicitly `"auto"`, or a
/// `"ramp"` entry missing a field it needs.
func readRampRequest() -> RampAgentDecision.Request? {
  guard let data = FileManager.default.contents(atPath: rampPath) else { return nil }
  guard let file = try? JSONDecoder().decode(RampRequestFile.self, from: data) else { return nil }
  guard file.mode == "ramp" else { return nil }
  guard let sensor = file.sensor, let minC = file.minC, let maxC = file.maxC,
    let heartbeat = file.heartbeat
  else { return nil }
  return RampAgentDecision.Request(
    sensor: sensor, minC: minC, maxC: maxC, smoothS: file.smoothS ?? 20, heartbeat: heartbeat)
}

// MARK: - desired.json writer (this agent's half of smcfand's control file)

func writeDesired(mode: String, rpm: Float?) {
  let fm = FileManager.default
  try? fm.createDirectory(atPath: controlDir, withIntermediateDirectories: true)

  var json = "{\"mode\":\"\(mode)\""
  if let rpm {
    json += ",\"rpm\":\(rpm)"
  }
  json += ",\"heartbeat\":\(Date().timeIntervalSince1970)}"

  // Write-tmp-then-rename, same pattern Scripts/smcfan-ctl uses: a reader
  // (smcfand, mid-poll) must never see a half-written file.
  let tmpPath = desiredPath + ".tmp.rampd"
  fm.createFile(atPath: tmpPath, contents: json.data(using: .utf8))
  try? fm.removeItem(atPath: desiredPath)
  try? fm.moveItem(atPath: tmpPath, toPath: desiredPath)
}

// MARK: - Temperature reading (unprivileged, in-process - same path as smcread)

final class TemperatureReader {
  let connection: SMCConnection

  init() throws {
    self.connection = try SMCConnection()
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

  /// Same helper smcfand used to use and smcread still uses, so the ramp
  /// input here can never diverge from what `smcread`/`smcfan-ctl status`
  /// report.
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
    return SensorAggregate.average(values)
  }
}

// MARK: - Main

guard let reader = try? TemperatureReader() else {
  FileHandle.standardError.write("smcfan-rampd: FATAL: could not open AppleSMC connection\n".data(using: .utf8)!)
  exit(1)
}

// Rebuilt whenever the requested sensor or tau changes, or the agent
// leaves/re-enters a live request - carrying a stale EMA across a
// mode/sensor switch would blend readings from an unrelated stream.
var smoother = TemperatureSmoother(tau: 20)
var lastSensor: String?
var lastSmoothS: Double?

// Tracks whether the last thing this agent wrote was `auto`, so a dead/absent
// request writes it exactly ONCE rather than fighting for desired.json every
// poll against whatever else might be setting it by hand.
var lastWasAuto = true
var lastRPM: Float?

while true {
  let request = readRampRequest()

  if let request {
    if lastSensor != request.sensor || lastSmoothS != request.smoothS {
      smoother = TemperatureSmoother(tau: request.smoothS)
      lastSensor = request.sensor
      lastSmoothS = request.smoothS
    }
  } else if lastSensor != nil {
    smoother.reset()
    lastSensor = nil
    lastSmoothS = nil
  }

  let rawTemperature = request.flatMap { reader.averageTemperature(sensorName: $0.sensor) }
  let smoothedTemperature = smoother.update(rawTemperature)

  let fanCount = reader.fanCount()
  let minRPM = fanCount > 0 ? reader.readFloat(SMCFanKey.minimum, fan: 0) : 0
  let maxRPM = fanCount > 0 ? reader.readFloat(SMCFanKey.maximum, fan: 0) : 0

  let decision = RampAgentDecision.decide(
    request: request,
    now: Date().timeIntervalSince1970,
    staleAfter: staleAfter,
    temperatureC: smoothedTemperature,
    minRPM: minRPM,
    maxRPM: maxRPM)

  switch decision {
  case let .constant(rpm):
    // Same target is re-sent every poll anyway: it carries the fresh
    // heartbeat smcfand's dead-man switch needs.
    let target = RampAgentDecision.applyDeadband(new: rpm, previous: lastRPM, band: rpmDeadband)
    writeDesired(mode: "constant", rpm: target)
    lastRPM = target
    lastWasAuto = false

  case .auto:
    lastRPM = nil
    if !lastWasAuto {
      writeDesired(mode: "auto", rpm: nil)
      lastWasAuto = true
    }
  }

  Thread.sleep(forTimeInterval: pollInterval)
}
