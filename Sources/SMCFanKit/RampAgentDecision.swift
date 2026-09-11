//
//  RampAgentDecision.swift
//  SMCFanKit
//
//  Pure decision logic for smcfan-rampd, the unprivileged agent that turns a
//  ramp REQUEST (sensor + min/max C + smoothing tau, refreshed by
//  Scripts/smcfan-ctl) plus a temperature READING into the `constant`/`auto`
//  policy smcfand (the root daemon) should apply. No SMC access, no file I/O,
//  no side effects, so it is directly unit testable.
//
//  smcfand itself holds no ramp/sensor/curve logic any more - it only ever
//  sees `auto`, `constant <rpm>`, `full`. The curve computed here is what
//  turns a ramp REQUEST into the `constant` value it asks for.
//

import Foundation

public enum RampAgentDecision {

  /// A parsed ramp.json request.
  public struct Request: Equatable, Sendable {
    public let sensor: String
    public let minC: Double
    public let maxC: Double
    public let smoothS: Double
    /// Unix epoch seconds this request was last refreshed - the dead-man
    /// switch input, same shape as smcfand's own desired.json heartbeat.
    public let heartbeat: Double

    public init(sensor: String, minC: Double, maxC: Double, smoothS: Double, heartbeat: Double) {
      self.sensor = sensor
      self.minC = minC
      self.maxC = maxC
      self.smoothS = smoothS
      self.heartbeat = heartbeat
    }
  }

  /// What the agent should ask smcfand for.
  public enum Desired: Equatable, Sendable {
    case auto
    case constant(rpm: Float)
  }

  /// - Parameters:
  ///   - request: the current ramp.json content, or `nil` if the file is
  ///     absent, unparseable, or explicitly marks `"mode":"auto"`.
  ///   - now: current time in the same epoch as `request.heartbeat`.
  ///   - staleAfter: dead-man window (seconds) - matches smcfand's own 60s.
  ///   - temperatureC: the (already averaged/smoothed) sensor reading, or
  ///     `nil` when no plausible reading exists this poll.
  ///   - minRPM: floor RPM for the curve (typically one fan's `F%dMn`).
  ///   - maxRPM: ceiling RPM for the curve (typically that same fan's
  ///     `F%dMx`). smcfand clamps the resulting `constant` value to EVERY
  ///     fan's own range independently when it applies it, so using one
  ///     fan's range here as the curve's scale is safe even when fans differ.
  /// - Returns: `.auto` whenever there is no live request or no plausible
  ///   reading - never a guessed RPM; `.constant(rpm:)` otherwise, using the
  ///   same linear ramp math as the old in-daemon curve (`FanRamp.targetRPM`).
  public static func decide(
    request: Request?,
    now: TimeInterval,
    staleAfter: TimeInterval,
    temperatureC: Float?,
    minRPM: Float,
    maxRPM: Float
  ) -> Desired {
    guard let request else { return .auto }
    guard now - request.heartbeat <= staleAfter else { return .auto }
    guard let temperatureC else { return .auto }

    let rpm = FanRamp.targetRPM(
      temperatureC: temperatureC,
      minC: Float(request.minC),
      maxC: Float(request.maxC),
      minRPM: minRPM,
      maxRPM: maxRPM)
    return .constant(rpm: rpm)
  }

  /// Keeps `previous` unless `new` differs from it by at least `band` RPM.
  /// Even smoothed, the computed target drifts a few RPM every poll; without
  /// a deadband every poll is a new SMC write and a new daemon log line for
  /// a change nobody can hear.
  public static func applyDeadband(new: Float, previous: Float?, band: Float) -> Float {
    guard let previous else { return new }
    return abs(new - previous) >= band ? new : previous
  }
}
