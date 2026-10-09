//
//  AppDisplayModeTests.swift
//  SwiftSparkyFitnessTests
//
//  Light unless experimental dark mode is on; the saved choice only counts
//  while it is.
//

import XCTest
@testable import SwiftSparkyFitness

final class AppDisplayModeTests: XCTestCase {
    func testLightWhateverWasSavedWhileExperimentOff() {
        for raw in ["system", "light", "dark", "", "garbage"] {
            XCTAssertEqual(AppDisplayMode.effective(raw: raw, experimentalDark: false), .light, raw)
        }
    }

    func testSavedChoiceAppliesWhileExperimentOn() {
        XCTAssertEqual(AppDisplayMode.effective(raw: "dark", experimentalDark: true), .dark)
        XCTAssertEqual(AppDisplayMode.effective(raw: "light", experimentalDark: true), .light)
        XCTAssertEqual(AppDisplayMode.effective(raw: "system", experimentalDark: true), .system)
        XCTAssertEqual(AppDisplayMode.effective(raw: "garbage", experimentalDark: true), .system)
    }
}
