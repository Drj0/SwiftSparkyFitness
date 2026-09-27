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
//  `statusForAuthorizationRequest` distinguishes only "the sheet would appear"
//  (never asked) from "it wouldn't" (already answered, either way) — not
//  granted from refused. After the sheet, a refused read and a genuinely empty
//  day are identical: both return no samples.
//
//  This is why the design's "Health data paused" state isn't built as
//  described — the app cannot know it's paused. `EnergyReading` separates "no
//  samples" from a number, and the UI says there's no data rather than
//  claiming permission was refused, which is a claim this API can't support.
//
//  WHAT THE SWITCH CAN STILL LEARN
//  -------------------------------
//  The switch used to stay on whatever happened, which made it a claim the app
//  couldn't back. There are two things it *can* find out, and it now does:
//
//    1. **Was the question even answered?** If the sheet is swiped away, the
//       status stays `.shouldRequest`. That is a definite "no permission was
//       granted", so the switch turns itself back off. (An explicit "Don't
//       Allow" reads as `.unnecessary`, exactly like "Allow" — that one is
//       genuinely undetectable, by design.)
//    2. **Is any data actually arriving?** `hasRecentEnergy` asks for a week
//       at once. Nothing coming back does NOT prove refusal — a sedentary
//       week and a new iPhone look the same — so it does not flip the switch.
//       It changes what the row *says*, from implying it works to admitting
//       nothing has arrived, which is the honest version of the same fact.
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

/// What asking for permission established. Deliberately not "granted" and
/// "denied": HealthKit won't say which, and a type that pretended otherwise
/// would invite the UI to claim it.
enum HealthAuthorizationOutcome: Equatable {
    /// The sheet was shown and the user responded — allow or deny, unknowable.
    case answered
    /// The question is still outstanding: the sheet was dismissed without an
    /// answer, or couldn't be shown. Nothing was granted.
    case unanswered
}

protocol HealthKitReading {
    var isAvailable: Bool { get }
    func requestAuthorization() async throws -> HealthAuthorizationOutcome
    func activeEnergy(on date: Date) async throws -> EnergyReading
    /// Whether Health has handed over any active energy in the last `days`.
    /// False means "nothing arrived", never "you were refused".
    func hasRecentEnergy(days: Int) async -> Bool
    func workouts(on date: Date) async throws -> [HealthWorkout]
}

extension HealthKitReading {
    func workouts(on date: Date) async throws -> [HealthWorkout] { [] }
}

/// One workout recorded in Health (Apple Watch, or any app that writes
/// there), reduced to what an exercise entry needs. Calories are Health's
/// own measured figure — the top of ExerciseCatalog's source priority.
struct HealthWorkout: Equatable {
    let id: UUID
    /// ExerciseCatalog name this workout type maps to.
    let catalogName: String
    let start: Date
    let durationMinutes: Double
    let kilocalories: Double?
    let distanceMeters: Double?
}

final class HealthKitService: HealthKitReading {
    static let shared = HealthKitService()

    private let store = HKHealthStore()
    private let energyType = HKQuantityType(.activeEnergyBurned)

    /// Workouts and their distances, alongside active energy: an imported
    /// workout's calories and distance are read from its statistics, which
    /// needs read access to those quantity types too.
    private var readTypes: Set<HKObjectType> {
        [energyType, .workoutType(),
         HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Presents the permission sheet and reports whether it was answered at
    /// all. Never reports *how* — see the note at the top of this file.
    func requestAuthorization() async throws -> HealthAuthorizationOutcome {
        guard isAvailable else { return .unanswered }
        try await store.requestAuthorization(toShare: [], read: readTypes)

        // Still `.shouldRequest` means the sheet came and went without a
        // choice, so there is definitely no permission to act on.
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status == .shouldRequest ? .unanswered : .answered
    }

    /// One statistics query across the whole window rather than a query per
    /// day — this runs right after the permission sheet, while the user is
    /// still looking at the switch.
    func hasRecentEnergy(days: Int) async -> Bool {
        guard isAvailable else { return false }

        let calendar = Calendar(identifier: .gregorian)
        let end = calendar.startOfDay(for: Date().addingTimeInterval(86_400))
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else { return false }

        let range = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: energyType, predicate: range),
            options: .cumulativeSum
        )
        guard let sum = try? await descriptor.result(for: store)?.sumQuantity() else { return false }
        return sum.doubleValue(for: .kilocalorie()) > 0
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

extension HealthKitService {
    func workouts(on date: Date) async throws -> [HealthWorkout] {
        guard isAvailable else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let distanceTypes = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
        return try await descriptor.result(for: store).map { workout in
            HealthWorkout(
                id: workout.uuid,
                catalogName: Self.catalogName(for: workout.workoutActivityType),
                start: workout.startDate,
                durationMinutes: workout.duration / 60,
                kilocalories: workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                distanceMeters: distanceTypes.lazy
                    .compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
                    .first { $0 > 0 }
            )
        }
    }

    /// Health's workout types onto ExerciseCatalog names. Anything without a
    /// match lands on the catalog's generic "Workout" rather than being
    /// dropped — the calories are real either way.
    static func catalogName(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "Walking"
        case .running: return "Running"
        case .hiking: return "Hiking"
        case .cycling: return "Cycling"
        case .handCycling: return "Hand Cycling"
        case .swimming: return "Swimming"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        case .stairClimbing: return "Stair Climber"
        case .stairs: return "Stair Climbing"
        case .stepTraining: return "Step Aerobics"
        case .jumpRope: return "Jump Rope"
        case .skatingSports: return "Skating"
        case .crossCountrySkiing: return "Cross-Country Skiing"
        case .downhillSkiing: return "Downhill Skiing"
        case .snowboarding: return "Snowboarding"
        case .mixedCardio: return "Mixed Cardio"
        case .highIntensityIntervalTraining: return "HIIT"
        case .crossTraining: return "Circuit Training"
        case .cardioDance, .socialDance: return "Dance Workout"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .flexibility: return "Stretching"
        case .barre: return "Barre"
        case .taiChi: return "Tai Chi"
        case .cooldown: return "Cooldown"
        case .mindAndBody: return "Mind & Body"
        case .traditionalStrengthTraining: return "Strength Training"
        case .functionalStrengthTraining: return "Functional Strength Training"
        case .coreTraining: return "Core Training"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .tennis: return "Tennis"
        case .badminton: return "Badminton"
        case .cricket: return "Cricket"
        case .volleyball: return "Volleyball"
        case .tableTennis: return "Table Tennis"
        case .squash: return "Squash"
        case .pickleball: return "Pickleball"
        case .golf: return "Golf"
        case .baseball: return "Baseball"
        case .hockey: return "Hockey"
        case .rugby: return "Rugby"
        case .americanFootball: return "American Football"
        case .climbing: return "Climbing"
        case .boxing: return "Boxing"
        case .kickboxing: return "Kickboxing"
        case .martialArts: return "Martial Arts"
        case .wrestling: return "Wrestling"
        case .surfingSports: return "Surfing"
        case .bowling: return "Bowling"
        case .gymnastics: return "Gymnastics"
        default: return "Workout"
        }
    }
}
