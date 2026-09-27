//
//  ServerDataImport.swift
//  SwiftSparkyFitness
//
//  Copies a server account's diary into the local store, for switching to
//  "this device only" without leaving the history behind.
//
//  Two phases, on purpose. Everything is read from the server first and held
//  in memory; only once every read has succeeded is the local store touched.
//  A dropped connection halfway through therefore leaves this iPhone exactly
//  as it was, instead of half a diary that looks complete.
//
//  Writes go through `LocalAPIClient`'s own methods — the same ones the app
//  logs with — so imported rows can't disagree with ones logged by hand
//  (serving scaling, meal names, recents counters all come out identical).
//
//  Not carried: water containers (the local defaults stand in) and Health's
//  "Active Calories" rows, which local mode rebuilds from Health itself.
//

import Foundation

struct ServerDataImport {
    let server: APIClientProtocol
    let local: LocalAPIClient

    init(server: APIClientProtocol = APIClient.shared, local: LocalAPIClient = .shared) {
        self.server = server
        self.local = local
    }

    /// Days fetched at once. Each day is one request (two with water); this
    /// keeps a year's import to seconds without hammering a home server.
    private static let concurrentDays = 6

    struct Progress: Equatable {
        var daysRead: Int
        var totalDays: Int
    }

    /// Everything the server had, in memory, before any of it is written.
    private struct Snapshot {
        var days: [(date: Date, summary: DailySummary, water: [WaterLogEntry])] = []
        var mealTypes: [MealType] = []
        var body: [DatedBodyMeasurements] = []
        var goals: [String: NutritionGoals] = [:]
        var preferences: UserPreferences?
    }

    /// True when this device already holds a diary of its own — the choice
    /// then has to say that copying replaces it.
    static func localStoreHasEntries(_ store: LocalStore = .shared) -> Bool {
        !store.all(LocalFoodEntry.self).isEmpty
            || !store.all(LocalExerciseEntry.self).isEmpty
            || !store.all(LocalWaterEntry.self).isEmpty
            || !store.all(LocalCheckIn.self).isEmpty
    }

    /// Replaces the local store with the account's history from `start`
    /// through today. Throws before writing anything if a read fails.
    func run(from start: Date, onProgress: @escaping (Progress) -> Void) async throws {
        let snapshot = try await read(from: start, onProgress: onProgress)
        try Task.checkCancellation()
        do {
            try await write(snapshot, from: start)
        } catch {
            // Local writes don't fail in practice, but if one does, a
            // partial copy mustn't pass for the whole diary.
            try? local.store.deleteEverything()
            throw error
        }
    }

    // MARK: - Read

    private func read(from start: Date, onProgress: @escaping (Progress) -> Void) async throws -> Snapshot {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: start)
        let today = calendar.startOfDay(for: Date())
        var dates: [Date] = []
        var day = first
        while day <= today {
            dates.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        var snapshot = Snapshot()
        async let mealTypes = server.mealTypes()
        async let body = server.bodyMeasurements(from: first, to: today)
        async let goals = server.goals(from: first, to: today)
        async let preferences = try? server.userPreferences()

        onProgress(Progress(daysRead: 0, totalDays: dates.count))
        let server = self.server
        try await withThrowingTaskGroup(of: (Date, DailySummary, [WaterLogEntry]).self) { group in
            var pending = dates[...]
            func startNext() {
                guard let date = pending.popFirst() else { return }
                group.addTask {
                    let summary = try await server.dailySummary(date: date)
                    let water = summary.waterIntake > 0 ? try await server.waterLog(date: date) : []
                    return (date, summary, water)
                }
            }
            for _ in 0..<Self.concurrentDays { startNext() }
            while let result = try await group.next() {
                snapshot.days.append((date: result.0, summary: result.1, water: result.2))
                onProgress(Progress(daysRead: snapshot.days.count, totalDays: dates.count))
                startNext()
            }
        }
        snapshot.days.sort { $0.date < $1.date }
        snapshot.mealTypes = try await mealTypes
        snapshot.body = try await body
        snapshot.goals = try await goals
        snapshot.preferences = await preferences
        return snapshot
    }

    // MARK: - Write

    private func write(_ snapshot: Snapshot, from start: Date) async throws {
        try local.store.deleteEverything()

        // Meal types by name: the wipe reseeded the defaults, so only the
        // account's own extras need creating. Order and visibility follow
        // the server's.
        var mealTypeIds: [String: String] = [:]
        var localMealTypes = try await local.mealTypes()
        for serverType in snapshot.mealTypes.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let key = serverType.name.lowercased()
            if let existing = localMealTypes.first(where: { $0.name.lowercased() == key }) {
                mealTypeIds[key] = existing.id
            } else {
                let created = try await local.createMealType(name: serverType.name, sortOrder: serverType.sortOrder)
                localMealTypes.append(created)
                mealTypeIds[key] = created.id
            }
        }
        let fallbackMealTypeId = localMealTypes.first?.id ?? ""

        var exerciseIds: [String: String] = [:]
        for day in snapshot.days {
            for entry in day.summary.foodEntries {
                let food = try await local.materializeExternalFood(Self.food(for: entry))
                try await local.createFoodEntry(FoodEntryInput(
                    food: food,
                    mealTypeId: mealTypeIds[entry.mealType.lowercased()] ?? fallbackMealTypeId,
                    quantity: entry.quantity,
                    entryDate: day.date
                ))
            }

            for session in day.summary.exerciseSessions.userLogged {
                let exercise = session.asExercise
                let key = ExerciseCatalog.normalized(exercise.name)
                let exerciseId: String
                if let known = exerciseIds[key] {
                    exerciseId = known
                } else {
                    exerciseId = try await local.createCustomExercise(CustomExerciseInput(
                        name: exercise.name,
                        category: exercise.category ?? "Other",
                        modality: session.effectiveModality
                    )).id
                    exerciseIds[key] = exerciseId
                }
                _ = try await local.createExerciseEntry(ExerciseEntryInput(
                    exerciseId: exerciseId,
                    modality: session.effectiveModality,
                    entryDate: day.date,
                    entryTime: session.entryTime,
                    durationMinutes: session.durationMinutes,
                    caloriesBurned: session.caloriesBurned ?? 0,
                    distance: session.distance,
                    avgHeartRate: session.avgHeartRate,
                    notes: session.notes,
                    sets: session.setsList.map {
                        ExerciseSetInput(setNumber: $0.setNumber, setType: $0.setType ?? "Working Set",
                                         reps: $0.reps, weight: $0.weight, rpe: $0.rpe, notes: $0.notes)
                    }
                ))
            }

            for drink in day.water where drink.waterMl > 0 {
                _ = try await local.logWaterAmount(date: day.date, milliliters: drink.waterMl)
            }
        }

        for row in snapshot.body {
            guard let date = LocalDay.date(row.entryDate) else { continue }
            var values: [BodyField: Double?] = [:]
            for field in BodyField.allCases {
                if let value = row.measurements.value(for: field) { values[field] = value }
            }
            guard !values.isEmpty else { continue }
            _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: date, values: values))
        }

        // Goals are stored locally as "from this day on", so only the days
        // they changed are written — not one row per day of history.
        var previous: NutritionGoals?
        for key in snapshot.goals.keys.sorted() {
            guard let goals = snapshot.goals[key], goals != previous, let date = LocalDay.date(key) else { continue }
            try await local.saveGoals(goals, startingOn: date)
            previous = goals
        }

        if let preferences = snapshot.preferences {
            for setting in UserPreferences.Setting.allCases {
                _ = try? await local.updateUserPreference(setting, to: preferences.value(for: setting))
            }
        }

        local.store.save()
        // Local mode floors day navigation on its first-use date; the
        // imported history has to be reachable.
        UserDefaults.standard.set(Calendar.current.startOfDay(for: start), forKey: LocalAPIClient.firstUseKey)
    }

    /// The server entry's food as a local one. Entries the server can
    /// describe as a full food keep its id — so a food logged on many days
    /// becomes one local food — and the rest are carried as a one-serving
    /// food of exactly what was logged, so the day's totals still match.
    static func food(for entry: FoodEntrySummary) -> Food {
        if let food = entry.editableFood { return food }
        let serving = entry.quantity > 0 ? entry.quantity : 1
        return Food(
            id: entry.foodId ?? "imported-\(entry.id)",
            name: entry.foodName,
            brand: entry.brandName,
            defaultVariant: FoodVariant(
                id: entry.variantId ?? "imported-\(entry.id)",
                servingSize: serving,
                servingUnit: entry.unit,
                calories: entry.calories,
                protein: entry.protein,
                carbs: entry.carbs,
                fat: entry.fat
            )
        )
    }
}
