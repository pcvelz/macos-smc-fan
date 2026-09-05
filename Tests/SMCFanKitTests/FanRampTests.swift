//
//  FanRampTests.swift
//  SMCFanKitTests
//

import Foundation
import Testing

@testable import SMCFanKit

@Suite("FanRamp")
struct FanRampTests {

  @Test("below min clamps to minRPM")
  func belowMinClampsToFloor() {
    let rpm = FanRamp.targetRPM(
      temperatureC: 30, minC: 45, maxC: 75, minRPM: 1000, maxRPM: 5000)
    #expect(rpm == 1000)
  }

  @Test("above max clamps to maxRPM")
  func aboveMaxClampsToCeiling() {
    let rpm = FanRamp.targetRPM(
      temperatureC: 90, minC: 45, maxC: 75, minRPM: 1000, maxRPM: 5000)
    #expect(rpm == 5000)
  }

  @Test("midpoint interpolates linearly")
  func midpointInterpolates() {
    let rpm = FanRamp.targetRPM(
      temperatureC: 60, minC: 45, maxC: 75, minRPM: 1000, maxRPM: 5000)
    #expect(rpm == 3000)
  }

  @Test("exact boundaries return the floor and ceiling")
  func exactBoundaries() {
    let atMin = FanRamp.targetRPM(
      temperatureC: 45, minC: 45, maxC: 75, minRPM: 1000, maxRPM: 5000)
    let atMax = FanRamp.targetRPM(
      temperatureC: 75, minC: 45, maxC: 75, minRPM: 1000, maxRPM: 5000)
    #expect(atMin == 1000)
    #expect(atMax == 5000)
  }

  @Test("degenerate range (maxC <= minC) still returns a defined RPM")
  func degenerateRangeIsSafe() {
    let below = FanRamp.targetRPM(
      temperatureC: 40, minC: 50, maxC: 50, minRPM: 1000, maxRPM: 5000)
    let atOrAbove = FanRamp.targetRPM(
      temperatureC: 55, minC: 50, maxC: 50, minRPM: 1000, maxRPM: 5000)
    #expect(below == 1000)
    #expect(atOrAbove == 5000)
  }
}
