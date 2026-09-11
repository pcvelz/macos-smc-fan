//
//  RampAgentDecisionTests.swift
//  SMCFanKitTests
//

import Foundation
import Testing

@testable import SMCFanKit

@Suite("RampAgentDecision")
struct RampAgentDecisionTests {

  static let request = RampAgentDecision.Request(
    sensor: "cpu_core_average", minC: 45, maxC: 75, smoothS: 20, heartbeat: 1000)

  @Test("no request at all -> auto")
  func noRequestIsAuto() {
    let desired = RampAgentDecision.decide(
      request: nil, now: 1000, staleAfter: 60, temperatureC: 60, minRPM: 1000, maxRPM: 5000)
    #expect(desired == .auto)
  }

  @Test("fresh request with a plausible reading -> constant, ramp math applied")
  func freshRequestRamps() {
    let desired = RampAgentDecision.decide(
      request: Self.request, now: 1005, staleAfter: 60, temperatureC: 60, minRPM: 1000, maxRPM: 5000)
    #expect(desired == .constant(rpm: 3000))  // midpoint of 45-75C -> midpoint of 1000-5000 RPM
  }

  @Test("stale heartbeat -> auto, even with a plausible reading")
  func staleHeartbeatIsAuto() {
    let desired = RampAgentDecision.decide(
      request: Self.request, now: 1061, staleAfter: 60, temperatureC: 60, minRPM: 1000, maxRPM: 5000)
    #expect(desired == .auto)
  }

  @Test("heartbeat exactly at the boundary is still live")
  func heartbeatAtBoundaryIsLive() {
    let desired = RampAgentDecision.decide(
      request: Self.request, now: 1060, staleAfter: 60, temperatureC: 60, minRPM: 1000, maxRPM: 5000)
    #expect(desired == .constant(rpm: 3000))
  }

  @Test("no plausible reading -> auto, never a guessed RPM")
  func noReadingIsAuto() {
    let desired = RampAgentDecision.decide(
      request: Self.request, now: 1005, staleAfter: 60, temperatureC: nil, minRPM: 1000, maxRPM: 5000)
    #expect(desired == .auto)
  }

  @Test("below minC clamps to minRPM")
  func belowMinClamps() {
    let desired = RampAgentDecision.decide(
      request: Self.request, now: 1005, staleAfter: 60, temperatureC: 30, minRPM: 1000, maxRPM: 5000)
    #expect(desired == .constant(rpm: 1000))
  }

  @Test("above maxC clamps to maxRPM")
  func aboveMaxClamps() {
    let desired = RampAgentDecision.decide(
      request: Self.request, now: 1005, staleAfter: 60, temperatureC: 90, minRPM: 1000, maxRPM: 5000)
    #expect(desired == .constant(rpm: 5000))
  }
}
