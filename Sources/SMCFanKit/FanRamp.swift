//
//  FanRamp.swift
//  SMCFanKit
//
//  Pure temperature-to-RPM ramp math for smcfand. No SMC access, no
//  side effects, so it is directly unit testable.
//

import Foundation

/// Computes a fan RPM target from a temperature reading using a linear
/// ramp between (minC, minRPM) and (maxC, maxRPM). Below minC the fan
/// stays at minRPM; above maxC it is clamped to maxRPM.
public enum FanRamp {

  /// - Parameters:
  ///   - temperatureC: current sensor reading in Celsius.
  ///   - minC: temperature at or below which the fan runs at `minRPM`.
  ///   - maxC: temperature at or above which the fan runs at `maxRPM`.
  ///   - minRPM: floor RPM (typically the fan's `F%dMn`).
  ///   - maxRPM: ceiling RPM (typically the fan's `F%dMx`).
  /// - Returns: target RPM, linearly interpolated and clamped to
  ///   `[minRPM, maxRPM]`. If `maxC <= minC` (degenerate config), returns
  ///   `maxRPM` whenever `temperatureC >= minC`, else `minRPM`.
  public static func targetRPM(
    temperatureC: Float,
    minC: Float,
    maxC: Float,
    minRPM: Float,
    maxRPM: Float
  ) -> Float {
    guard maxC > minC else {
      return temperatureC >= minC ? maxRPM : minRPM
    }

    if temperatureC <= minC { return minRPM }
    if temperatureC >= maxC { return maxRPM }

    let fraction = (temperatureC - minC) / (maxC - minC)
    return minRPM + fraction * (maxRPM - minRPM)
  }
}
