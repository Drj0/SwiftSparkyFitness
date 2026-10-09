//
//  LocalAPIClient+Health.swift
//  SwiftSparkyFitness
//
//  Apple Health data in this iPhone's diary is read, never stored.
//
//  The diary mirrors to the user's iCloud, and App Store guideline 5.1.3(ii)
//  says personal health information may not be stored there. So in this
//  mode the day's active energy and its Health workouts are read from Health
//  each time a day (or a Progress range) is assembled, and added to what the
//  diary holds. Health already keeps them in step across the user's devices.
//
//  Server mode still stores them: that copy goes to the user's own server,
//  not iCloud, and the server needs the rows for its own totals and web app.
//  It uses `LocalAPIClient` too, over its own store, with `health` nil.
//

import Foundation
import SwiftData

extension LocalAPIClient {
    /// True for this iPhone's iCloud diary: Health data is read live, and
    /// anything from Health found stored in it is ignored and removed.
    var readsHealthLive: Bool { health != nil }

    /// A row that came from Health: the day's "Active Calories" figure or an
    /// imported workout. Kept out of an iCloud diary.
    static func isFromHealth(_ row: LocalExerciseEntry) -> Bool {
        row.name == ExerciseSessionSummary.healthActiveEnergyName || row.notes == HealthWorkoutImporter.note
    }

    /// The day's active energy (as the same "Active Calories" session the
    /// stored row used to be, so `dayBurn` and the cards read it unchanged)
    /// and, if workout import is on, its workouts. Empty with Health off.
    func healthSessions(on date: Date) async -> [ExerciseSessionSummary] {
        guard let health, HealthSync.isEnabled, health.isAvailable else { return [] }
        var sessions: [ExerciseSessionSummary] = []
        if case .kilocalories(let kilocalories)? = try? await health.activeEnergy(on: date) {
            sessions.append(ExerciseSessionSummary(
                id: ExerciseSessionSummary.readFromHealthPrefix + "energy-" + LocalDay.key(date),
                name: ExerciseSessionSummary.healthActiveEnergyName,
                caloriesBurned: kilocalories,
                durationMinutes: 0,
                exerciseId: nil,
                entryDate: LocalDay.key(date)
            ))
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        if let end = calendar.date(byAdding: .day, value: 1, to: start) {
            sessions += await healthWorkoutSessions(from: start, to: end)
        }
        return sessions
    }

    /// Health workouts that started in [start, end), as read-only sessions.
    ///
    /// Filtered on the start here: HealthKit's range matches any workout
    /// that *overlaps* it, so a run from 23:30 to 00:30 came back for both
    /// days and was counted on each. Stored imports never had this — each
    /// was saved once, on its start day — and a live read has no such memory.
    func healthWorkoutSessions(from start: Date, to end: Date) async -> [ExerciseSessionSummary] {
        guard let health, HealthSync.isEnabled, HealthSync.importsWorkouts, health.isAvailable,
              let workouts = try? await health.workouts(from: start, to: end)
                .filter({ $0.start >= start && $0.start < end }),
              !workouts.isEmpty else { return [] }
        let preferences = (try? await userPreferences()) ?? .serverDefaults
        return workouts.map { HealthWorkoutImporter.session(for: $0, preferences: preferences) }
    }

    /// Once per launch: Health rows written by earlier versions (or brought
    /// in by a restore or a move from a server) leave this diary, and with
    /// it the user's iCloud.
    func removeStoredHealthRowsOnce() {
        guard readsHealthLive, !didRemoveStoredHealthRows else { return }
        didRemoveStoredHealthRows = true
        store.removeHealthRows()
    }
}

extension LocalStore {
    /// Deletes rows that came from Apple Health. As a copy of nothing, like a
    /// server's own delete: no tombstone, so a server this diary once moved
    /// from keeps its copy. The deletes still reach iCloud, which is the
    /// point. Returns how many went.
    @discardableResult
    func removeHealthRows() -> Int {
        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        let note: String? = HealthWorkoutImporter.note
        let rows = fetch(LocalExerciseEntry.self, where: #Predicate { $0.name == sentinel || $0.notes == note })
        guard !rows.isEmpty else { return 0 }
        let removed = applyingRemoteChanges {
            rows.forEach(context.delete)
            guard save() else {
                context.rollback()
                return 0
            }
            return rows.count
        }
        // The importer remembers what it has imported, on this device, to
        // never log a workout twice. With the rows gone, that memory would
        // stop server mode re-importing them after a move to a server; its
        // own check against the server's day still prevents duplicates.
        if removed > 0, self === LocalStore.shared { HealthWorkoutImporter.forgetImported() }
        return removed
    }
}
