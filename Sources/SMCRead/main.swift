//
//  main.swift
//  smcread
//
//  Unprivileged, read-only SMC reader. Opens AppleSMC directly in-process
//  via SMCKit (no daemon, no XPC, no root). Never calls writeKey. Prints
//  one JSON object to stdout: sensor temperatures, computed CPU-core /
//  GPU-cluster averages, and per-fan RPM/mode info.
//

import Foundation
import SMCFanKit
import SMCKit

struct SensorReading: Codable {
  let key: String
  let name: String
  let group: String
  let celsius: Double
}

struct FanReading: Codable {
  let index: Int
  let actualRPM: Double
  let targetRPM: Double
  let minRPM: Double
  let maxRPM: Double
  let mode: String
}

struct SMCReadOutput: Codable {
  let hardwareModel: String
  let sensors: [SensorReading]
  let aggregates: [String: Double]
  let fans: [FanReading]
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  exit(1)
}

let subcommand = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
guard ["all", "sensors", "fans"].contains(subcommand) else {
  fail("Usage: smcread [sensors|fans|all]")
}

do {
  let connection = try SMCConnection()

  // MARK: Sensors (read-only)

  let candidateKeys =
    (subcommand == "all" || subcommand == "sensors")
    ? SensorCatalog.keysForCurrentHardware().filter { $0.type == .temperature } : []
  var sensors: [SensorReading] = []
  for sensor in candidateKeys {
    guard let (bytes, size) = try? connection.readKey(sensor.key) else { continue }
    let value = Double(SMCDataFormat.float(from: bytes, size: size))
    guard value > 0, value < 150 else { continue }
    sensors.append(
      SensorReading(key: sensor.key, name: sensor.name, group: sensor.group.rawValue, celsius: value))
  }

  // Same helper the daemon ramps on, so the number printed here is the
  // number the fans follow. Individual readings stay in `sensors` unfiltered
  // (a gated P-core at 2.2C is real data about that core); only the
  // aggregate applies the plausibility floor.
  func average(group: String) -> Double? {
    let values = sensors.filter { $0.group == group }.map { Float($0.celsius) }
    return SensorAggregate.average(values).map(Double.init)
  }

  var aggregates: [String: Double] = [:]
  if let cpuAvg = average(group: SensorGroup.cpu.rawValue) {
    aggregates["cpu_core_average"] = cpuAvg
  }
  if let gpuAvg = average(group: SensorGroup.gpu.rawValue) {
    aggregates["gpu_cluster_average"] = gpuAvg
  }

  // MARK: Fans (read-only; SMCHardwareConfig.detectHardwareKeys only reads)

  let hwConfig = SMCHardwareConfig.detectHardwareKeys(connection: connection)

  var fans: [FanReading] = []
  if subcommand == "all" || subcommand == "fans",
    let (countBytes, _) = try? connection.readKey(SMCFanKey.count), !countBytes.isEmpty
  {
    let fanCount = Int(countBytes[0])
    for fanIndex in 0..<fanCount {
      func readFloat(_ template: String) -> Double {
        let key = SMCFanKey.key(template, fan: fanIndex)
        guard let (bytes, size) = try? connection.readKey(key) else { return 0 }
        return Double(SMCDataFormat.float(from: bytes, size: size))
      }
      let actual = readFloat(SMCFanKey.actual)
      let target = readFloat(SMCFanKey.target)
      let minRPM = readFloat(SMCFanKey.minimum)
      let maxRPM = readFloat(SMCFanKey.maximum)

      let modeKey = SMCFanKey.key(hwConfig.modeKeyFormat, fan: fanIndex)
      let mode: String
      if let (modeBytes, _) = try? connection.readKey(modeKey), !modeBytes.isEmpty {
        mode = modeBytes[0] == 1 ? "manual" : "auto"
      } else {
        mode = "unknown"
      }

      fans.append(
        FanReading(
          index: fanIndex, actualRPM: actual, targetRPM: target, minRPM: minRPM, maxRPM: maxRPM,
          mode: mode))
    }
  }

  let output = SMCReadOutput(
    hardwareModel: SMCConnection.hardwareModel(),
    sensors: sensors.sorted { $0.key < $1.key },
    aggregates: aggregates,
    fans: fans
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(output)
  print(String(data: data, encoding: .utf8) ?? "{}")
} catch {
  fail("smcread: SMC connection failed: \(error)")
}
