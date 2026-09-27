//
//  HealthWorkoutImporter.swift
//  SwiftSparkyFitness
//
//  Brings workouts recorded in Apple Health into the day's exercise log, with
//  Health's measured calories — the top of ExerciseCatalog's source priority.
//
//  Calories aren't double-counted: both the server and local mode take
//  `burned` as max(Health active energy, logged exercise), not the sum,
//  because active energy already includes every workout.
//
//  Each workout is imported once. Its Health UUID is remembered on this
//  device, so deleting an imported entry keeps it deleted; an entry already
//  on the day with the same name, start time and Health note (another device
//  imported it) is also skipped.
//

import Foundation

@MainActor
enum HealthWorkoutImporter {
    /// Written into the entry's notes; how lists recognise an imported
    /// workout to badge it.
    static let note = "Imported from Apple Health"

    private static let importedKey = "healthImportedWorkoutIDs"
    private static let authorizationKey = "healthWorkoutsAuthorizationRequested"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Returns true when at least one workout was added, so the caller knows
    /// its summary needs (re)loading. Silent on every failure: this runs on
    /// every load, and a missing permission or an empty day isn't news.
    @discardableResult
    static func importWorkouts(
        on date: Date,
        apiClient: APIClientProtocol = AppServices.client,
        health: HealthKitReading = HealthKitService.shared
    ) async -> Bool {
        // Today and Diary (and pull-to-refresh) can load the same day at
        // once. Both would read "not imported yet" before either wrote, and
        // log the workout twice — so a second call joins the first.
        let day = LocalDay.key(date)
        if let running = inFlight[day] { return await running.value }
        let task = Task { await run(on: date, apiClient: apiClient, health: health) }
        inFlight[day] = task
        defer { inFlight[day] = nil }
        return await task.value
    }

    private static var inFlight: [String: Task<Bool, Never>] = [:]

    private static func run(on date: Date, apiClient: APIClientProtocol, health: HealthKitReading) async -> Bool {
        guard HealthSync.isEnabled, health.isAvailable else { return false }

        // Anyone who connected Health before workouts were read has only
        // granted active energy. Ask once for the newer types; HealthKit
        // shows the sheet only for types not yet asked about.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: authorizationKey) {
            _ = try? await health.requestAuthorization()
            defaults.set(true, forKey: authorizationKey)
        }

        guard let workouts = try? await health.workouts(on: date), !workouts.isEmpty else { return false }
        var imported = Set(defaults.stringArray(forKey: importedKey) ?? [])
        let fresh = workouts.filter { !imported.contains($0.id.uuidString) }
        guard !fresh.isEmpty else { return false }

        let existing = (try? await apiClient.dailySummary(date: date))?.exerciseSessions ?? []
        let preferences = (try? await apiClient.userPreferences()) ?? .serverDefaults
        var didImport = false

        for workout in fresh {
            let time = timeFormatter.string(from: workout.start)
            let alreadyLogged = existing.contains { isSameImport($0, workout: workout, time: time) }
            if !alreadyLogged {
                guard await create(workout, time: time, preferences: preferences, apiClient: apiClient) else { continue }
                didImport = true
            }
            imported.insert(workout.id.uuidString)
        }
        // ponytail: grows by one UUID per workout forever (~40 bytes each);
        // prune entries older than the account's history if it ever matters.
        defaults.set(Array(imported), forKey: importedKey)
        return didImport
    }

    private static func isSameImport(_ session: ExerciseSessionSummary, workout: HealthWorkout, time: String) -> Bool {
        guard session.isHealthWorkout, session.name == workout.catalogName, let logged = session.entryTime else { return false }
        return logged.prefix(5) == time.prefix(5)
    }

    private static func create(
        _ workout: HealthWorkout, time: String, preferences: UserPreferences, apiClient: APIClientProtocol
    ) async -> Bool {
        guard let entry = ExerciseCatalog.entry(named: workout.catalogName),
              let exercise = try? await apiClient.libraryExercise(for: entry) else { return false }
        // Health's measured figure; the catalog estimate only if Health
        // recorded none.
        let calories = workout.kilocalories
            ?? entry.caloriesPerHour(weightKg: ExerciseCatalog.fallbackWeightKg) * workout.durationMinutes / 60
        let distance = workout.distanceMeters.map {
            preferences.defaultDistanceUnit == "miles" ? $0 / 1609.344 : $0 / 1000
        }
        let input = ExerciseEntryInput(
            exerciseId: exercise.id,
            modality: distance == nil ? .duration : .durationDistance,
            entryDate: workout.start,
            entryTime: time,
            durationMinutes: workout.durationMinutes.rounded(),
            caloriesBurned: calories.rounded(),
            distance: distance.map { ($0 * 100).rounded() / 100 },
            notes: note
        )
        return (try? await apiClient.createExerciseEntry(input)) != nil
    }
}

extension ExerciseSessionSummary {
    var isHealthWorkout: Bool { notes == HealthWorkoutImporter.note }
}
