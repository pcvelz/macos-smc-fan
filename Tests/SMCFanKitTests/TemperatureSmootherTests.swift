//
//  TemperatureSmootherTests.swift
//  SMCFanKitTests
//

import Foundation
import Testing

@testable import SMCFanKit

@Suite("TemperatureSmoother")
struct TemperatureSmootherTests {

  @Test("first sample passes through unchanged")
  func firstSamplePassthrough() {
    let smoother = TemperatureSmoother(tau: 20)
    let out = smoother.update(50, now: Date())
    #expect(out == 50)
  }

  @Test("a step input converges with the expected time constant")
  func stepConverges() {
    // alpha = min(1, dt/tau) - linear, not exponential - matching the
    // approved offline-sim formula (alpha = poll/tau).
    let smoother = TemperatureSmoother(tau: 20)
    let t0 = Date()
    _ = smoother.update(45, now: t0)          // prime at 45C

    // Step to 75C. After half a tau (10s), alpha = 0.5: exactly halfway,
    // 45 + 0.5*(75-45) = 60C.
    let afterHalfTau = smoother.update(75, now: t0.addingTimeInterval(10))!
    #expect(abs(afterHalfTau - 60) < 0.01)

    // A full tau (or more) elapsed since the last sample clamps alpha to 1:
    // the output tracks the new value exactly.
    let afterOneTau = smoother.update(75, now: t0.addingTimeInterval(10 + 20))!
    #expect(abs(afterOneTau - 75) < 0.01)
  }

  @Test("a single spike moves the output by at most a tau-proportional fraction")
  func spikeIsDamped() {
    let smoother = TemperatureSmoother(tau: 20)
    let t0 = Date()
    _ = smoother.update(50, now: t0)

    // One 2s poll after priming, a 10C spike (50 -> 60) arrives. alpha =
    // dt/tau = 2/20 = 0.1, so the output should move by ~1C, nowhere near
    // the full 10C jump.
    let out = smoother.update(60, now: t0.addingTimeInterval(2))!
    #expect(out > 50 && out < 52)
  }

  @Test("tau of 0 disables smoothing")
  func tauZeroDisablesSmoothing() {
    let smoother = TemperatureSmoother(tau: 0)
    let t0 = Date()
    _ = smoother.update(50, now: t0)
    let out = smoother.update(90, now: t0.addingTimeInterval(2))
    #expect(out == 90)
  }

  @Test("an implausible (nil) reading leaves the smoothed value unchanged")
  func nilReadingHoldsLastValue() {
    let smoother = TemperatureSmoother(tau: 20)
    let t0 = Date()
    _ = smoother.update(55, now: t0)
    let held = smoother.update(nil, now: t0.addingTimeInterval(2))
    #expect(held == 55)
  }

  @Test("nil before any sample returns nil")
  func nilBeforeAnySampleReturnsNil() {
    let smoother = TemperatureSmoother(tau: 20)
    #expect(smoother.update(nil) == nil)
  }

  @Test("reset clears state, next sample passes through again")
  func resetClearsState() {
    let smoother = TemperatureSmoother(tau: 20)
    let t0 = Date()
    _ = smoother.update(50, now: t0)
    _ = smoother.update(80, now: t0.addingTimeInterval(2))
    smoother.reset()
    let out = smoother.update(20, now: t0.addingTimeInterval(4))
    #expect(out == 20)
  }
}
