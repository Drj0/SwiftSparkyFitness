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
        // Its own opt-in, asked for from Settings: see HealthSync.
        guard HealthSync.isEnabled, HealthSync.importsWorkouts, health.isAvailable else { return false }
        // This iPhone's diary mirrors to iCloud, where Health data may not be
        // stored (App Store guideline 5.1.3(ii)): it reads workouts from
        // Health as each day loads instead (`LocalAPIClient.healthSessions`).
        if (apiClient as? LocalAPIClient)?.readsHealthLive == true { return false }
        let defaults = UserDefaults.standard

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
        let figures = Figures(workout, entry: entry, preferences: preferences)
        let input = ExerciseEntryInput(
            exerciseId: exercise.id,
            modality: figures.distance == nil ? .duration : .durationDistance,
            entryDate: workout.start,
            entryTime: time,
            durationMinutes: workout.durationMinutes.rounded(),
            caloriesBurned: figures.calories,
            distance: figures.distance,
            notes: note
        )
        return (try? await apiClient.createExerciseEntry(input)) != nil
    }

    /// A workout as a session read straight from Health: shown and counted
    /// like an imported one, but stored nowhere, so there is nothing to edit
    /// or delete (no `exerciseId`, and `isReadFromHealth`).
    static func session(for workout: HealthWorkout, preferences: UserPreferences) -> ExerciseSessionSummary {
        let entry = ExerciseCatalog.entry(named: workout.catalogName)
        let figures = Figures(workout, entry: entry, preferences: preferences)
        return ExerciseSessionSummary(
            id: ExerciseSessionSummary.readFromHealthPrefix + workout.id.uuidString,
            name: workout.catalogName,
            caloriesBurned: figures.calories,
            durationMinutes: workout.durationMinutes.rounded(),
            exerciseId: nil,
            entryDate: LocalDay.key(workout.start),
            entryTime: timeFormatter.string(from: workout.start),
            notes: note,
            distance: figures.distance,
            modality: figures.distance == nil ? .duration : .durationDistance
        )
    }

    /// Health's measured calories, or the catalog's estimate when it recorded
    /// none; distance in the user's unit, to two places.
    private struct Figures {
        let calories: Double
        let distance: Double?

        init(_ workout: HealthWorkout, entry: CatalogExercise?, preferences: UserPreferences) {
            let estimate = entry.map {
                $0.caloriesPerHour(weightKg: ExerciseCatalog.fallbackWeightKg) * workout.durationMinutes / 60
            }
            calories = (workout.kilocalories ?? estimate ?? 0).rounded()
            distance = workout.distanceMeters.map {
                let converted = preferences.defaultDistanceUnit == "miles" ? $0 / 1609.344 : $0 / 1000
                return (converted * 100).rounded() / 100
            }
        }
    }
}

extension ExerciseSessionSummary {
    var isHealthWorkout: Bool { notes == HealthWorkoutImporter.note }

    /// Ids of sessions built from Health as the day loads, never stored.
    static let readFromHealthPrefix = "apple-health:"

    /// Read from Health for this screen, not stored in the diary: Health owns
    /// it, so it can't be edited or deleted here.
    var isReadFromHealth: Bool { id.hasPrefix(Self.readFromHealthPrefix) }
}
