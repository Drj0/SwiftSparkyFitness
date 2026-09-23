//
//  HealthKitService.swift
//  SwiftSparkyFitness
//
//  Reads the day's active energy from Health. Read-only — the app never
//  writes to HealthKit, which is why the entitlement asks for no share types.
//
//  WHY ACTIVE ENERGY AND NOT STEPS
//  -------------------------------
//  The server can take either, and the difference matters because it decides
//  whether the figure gets double-counted against exercise the user logged by
//  hand. Reading `calorieCalculations.ts`:
//
//      workoutPlusSteps = loggedExerciseCalories + backgroundStepCalories
//      if activeCalories >= workoutPlusSteps  -> use activeCalories  ("active")
//      else                                   -> use workoutPlusSteps ("logged"/"steps")
//
//  So steps ADD to logged workouts, while active calories REPLACE them by
//  taking the larger of the two. The server subtracts steps already attached
//  to a logged session first, but a manually logged run with no step count on
//  it would still have its steps sitting in the background bucket and be paid
//  for twice.
//
//  Active energy is also the honest match for what HealthKit reports: on a
//  real device it already includes workouts. So the app reads active energy
//  and posts it to the endpoint built for exactly this, and the server's
//  `max()` does the de-duplication.
//
//  Steps are deliberately not read or written. They'd be a second, weaker
//  estimate of the same quantity, and writing them is the branch that can
//  double-count.
//
//  THE PERMISSION MODEL IS NOT SYMMETRIC, AND THAT SHAPES THE UI
//  ------------------------------------------------------------
//  HealthKit will not tell you whether a *read* was granted:
//  `authorizationStatus(for:)` reports sharing (write) status only. Knowing
//  you'd been denied would itself leak health information — the fact that the
//  user has something they don't want to share.
//
//  `statusForAuthorizationRequest` would distinguish only "the sheet would
//  appear" (never asked) from "it wouldn't" (already answered, either way) —
//  not granted from refused — so it answers nothing the UI can act on and
//  isn't used. After the sheet, a refused read and a genuinely empty day are
//  identical: both return no samples.
//
//  This is why the design's "Health data paused" state isn't built as
//  described — the app cannot know it's paused. `EnergyReading` separates "no
//  samples" from a number, and the UI says there's no data rather than
//  claiming permission was refused, which is a claim this API can't support.
//

import Foundation
import HealthKit

/// What an active-energy query could actually determine.
enum EnergyReading: Equatable {
    /// Health returned samples totalling this many kilocalories.
    case kilocalories(Double)
    /// Health returned nothing. Either permission was refused or there are no
    /// samples — HealthKit does not let a reader tell these apart.
    case noData
}

/// Whether the user has opted into Health at all.
///
/// Separate from HealthKit's own permission because the two answer different
/// questions: HealthKit knows whether the sheet has been shown, this knows
/// whether the user asked for the feature. Without it the app would query
/// Health on every load for people who never wanted it — and, since a refused
/// read is indistinguishable from an empty one, would do so silently forever.
enum HealthSync {
    static let defaultsKey = "healthSyncEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

protocol HealthKitReading {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    func activeEnergy(on date: Date) async throws -> EnergyReading
}

final class HealthKitService: HealthKitReading {
    static let shared = HealthKitService()

    private let store = HKHealthStore()
    private let energyType = HKQuantityType(.activeEnergyBurned)

    private var readTypes: Set<HKObjectType> { [energyType] }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Presents the permission sheet. Returning without throwing means the
    /// sheet was shown and dismissed — NOT that access was granted, which
    /// HealthKit won't disclose.
    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// Total active energy recorded for the calendar day containing `date`.
    func activeEnergy(on date: Date) async throws -> EnergyReading {
        guard isAvailable else { return .noData }

        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return .noData }

        let range = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: energyType, predicate: range),
            options: .cumulativeSum
        )

        // A refused read arrives here as an empty result rather than an error,
        // which is the whole reason EnergyReading has a `noData` case.
        guard let sum = try await descriptor.result(for: store)?.sumQuantity() else {
            return .noData
        }
        let kilocalories = sum.doubleValue(for: .kilocalorie())
        return kilocalories > 0 ? .kilocalories(kilocalories) : .noData
    }
}
