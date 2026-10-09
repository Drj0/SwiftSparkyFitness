//
//  LocalAPIClient+Wellbeing.swift
//  SwiftSparkyFitness
//
//  Water, body measurements, goals and the Progress range reads.
//

import Foundation
import SwiftData

extension LocalAPIClient {

    // MARK: - Day helpers

    /// Every `yyyy-MM-dd` key from `start` to `end` inclusive. Day keys sort
    /// lexicographically, which is why ranges below compare them as strings
    /// rather than reconstructing Dates.
    func dayKeys(from start: Date, to end: Date) -> [String] {
        var keys: [String] = []
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            keys.append(LocalDay.key(day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }

    // MARK: - Goals

    /// The goal bag, minus the write-only prefixes.
    ///
    /// `NutritionGoals` keeps its bag private and is Decodable-only, so the
    /// round trip goes out through `writePayload` and has the `p_` stripped
    /// back off. That looks indirect, but it's the one accessor that exposes
    /// every key — including the two dozen columns this app never models but
    /// must not drop — and it avoids widening the model's API for local mode.
    static func bag(from goals: NutritionGoals, dayKey: String) -> [String: JSONValue] {
        var bag: [String: JSONValue] = [:]
        for (key, value) in goals.writePayload(startingOn: dayKey) where key != "p_start_date" {
            bag[key.hasPrefix("p_") ? String(key.dropFirst(2)) : key] = value
        }
        return bag
    }

    static func goals(from row: LocalGoalRow) -> NutritionGoals {
        let bag = (try? JSONDecoder().decode([String: JSONValue].self, from: row.rawJSON)) ?? [:]
        return NutritionGoals(raw: bag)
    }

    /// The row in force on `date`: the most recent one effective **on or
    /// before** it, not an exact match.
    ///
    /// Goals are date-versioned and carried forward — the server does that
    /// expansion on read, and `ProgressViewModel` looks each day up directly
    /// with no carry-forward of its own. Matching exactly here would leave
    /// every day between two goal changes with no goal at all, which shows up
    /// as a chart line that quietly disappears rather than an error.
    func goals(date: Date) async throws -> NutritionGoals {
        let key = LocalDay.key(date)
        let rows = store.all(LocalGoalRow.self, sortBy: [SortDescriptor(\.dayKey)])
        guard let row = rows.last(where: { $0.dayKey <= key }) else {
            return NutritionGoals(raw: [:])
        }
        return Self.goals(from: row)
    }

    func saveGoals(_ goals: NutritionGoals, startingOn date: Date) async throws {
        let key = LocalDay.key(date)
        let data = (try? JSONEncoder().encode(Self.bag(from: goals, dayKey: key))) ?? Data()
        if let existing = store.fetch(LocalGoalRow.self, where: #Predicate { $0.dayKey == key }).first {
            existing.rawJSON = data
            store.save()
        } else {
            store.insert(LocalGoalRow(dayKey: key, rawJSON: data))
        }
    }

    /// One entry per day in the range, each carrying the goal in force that
    /// day — the carry-forward expansion described above.
    func goals(from start: Date, to end: Date) async throws -> [String: NutritionGoals] {
        let rows = store.all(LocalGoalRow.self, sortBy: [SortDescriptor(\.dayKey)])
        guard !rows.isEmpty else { return [:] }

        var result: [String: NutritionGoals] = [:]
        var index = 0
        var inForce: NutritionGoals?
        for key in dayKeys(from: start, to: end) {
            while index < rows.count, rows[index].dayKey <= key {
                inForce = Self.goals(from: rows[index])
                index += 1
            }
            if let inForce { result[key] = inForce }
        }
        return result
    }

    // MARK: - Water

    func waterTotals(date: Date) async throws -> WaterTotals {
        totals(forDayKey: LocalDay.key(date))
    }

    func totals(forDayKey key: String) -> WaterTotals {
        let rows = store.fetch(LocalWaterEntry.self, where: #Predicate { $0.dayKey == key })
        let ledger = rows.reduce(0.0) { $0 + $1.waterMl }
        let manual = rows.filter { $0.source == "manual" }.reduce(0.0) { $0 + $1.waterMl }
        let food = rows.filter { $0.source == "food" }.reduce(0.0) { $0 + $1.waterMl }
        return WaterTotals(waterMl: ledger, manualMl: manual, ledgerMl: ledger, foodMl: food)
    }

    func waterLog(date: Date) async throws -> [WaterLogEntry] {
        let key = LocalDay.key(date)
        return store
            .fetch(LocalWaterEntry.self, where: #Predicate { $0.dayKey == key }, sortBy: [SortDescriptor(\.loggedAt)])
            .map {
                WaterLogEntry(
                    id: $0.id,
                    waterMl: $0.waterMl,
                    containerName: $0.containerName,
                    source: $0.source,
                    loggedAt: $0.loggedAt
                )
            }
    }

    func adjustWater(date: Date, drinks: Int) async throws -> WaterTotals {
        try await adjustWater(date: date, drinks: drinks, containerId: nil)
    }

    /// Positive adds that many drinks; negative removes that many of the most
    /// recent **manual** rows.
    ///
    /// The asymmetry is the server's and it matters: provider-synced water
    /// belongs to its provider, so the "−" control can only ever take back
    /// what was tapped in by hand. Removing more than exists clamps at zero
    /// rather than erroring, and decrementing an empty day is a no-op — both
    /// are relied on by the optimistic water card, which fires requests ahead
    /// of knowing the true count.
    func adjustWater(date: Date, drinks: Int, containerId: Int?) async throws -> WaterTotals {
        let key = LocalDay.key(date)

        if drinks > 0 {
            let container = containerId.flatMap { id in
                store.fetch(LocalWaterContainer.self, where: #Predicate { $0.id == id }).first
            }
            // mlPerServing carries the oz/litre conversions the server would
            // otherwise apply, so the unit maths lives in exactly one place.
            let millilitres = container.map { Self.container($0).mlPerServing } ?? Water.defaultMlPerDrink
            for _ in 0..<min(drinks, Water.maxDrinksPerRequest) {
                store.context.insert(
                    LocalWaterEntry(
                        dayKey: key,
                        waterMl: millilitres,
                        source: "manual",
                        containerName: container?.name
                    )
                )
            }
            store.save()
        } else if drinks < 0 {
            let manual = store
                .fetch(LocalWaterEntry.self, where: #Predicate { $0.dayKey == key && $0.source == "manual" })
                .sorted { ($0.loggedAt) > ($1.loggedAt) }
            for row in manual.prefix(-drinks) {
                store.context.delete(row)
            }
            store.save()
        }

        return totals(forDayKey: key)
    }

    /// The exact-millilitre write. On the server this needs a throwaway
    /// container, because there is no raw-millilitre endpoint; locally the
    /// ledger row simply carries the number.
    func logWaterAmount(date: Date, milliliters: Double) async throws -> WaterTotals {
        let key = LocalDay.key(date)
        store.insert(LocalWaterEntry(dayKey: key, waterMl: milliliters, source: "manual"))
        return totals(forDayKey: key)
    }

    func deleteWaterLogEntry(id: String) async throws {
        guard let row = store.fetch(LocalWaterEntry.self, where: #Predicate { $0.id == id }).first else { return }
        store.delete(row)
    }

    // MARK: - Water containers

    static func container(_ row: LocalWaterContainer) -> WaterContainer {
        WaterContainer(
            id: row.id,
            name: row.name,
            volume: row.volume,
            unit: row.unit,
            isPrimary: row.isPrimary,
            servingsPerContainer: row.servingsPerContainer
        )
    }

    func waterContainers() async throws -> [WaterContainer] {
        store.all(LocalWaterContainer.self, sortBy: [SortDescriptor(\.id)]).map(Self.container)
    }

    /// The first container added becomes primary on its own. Without that,
    /// adding one appears to do nothing — the quick-add keeps logging the
    /// default 250 ml until a second, separate action makes it primary.
    func createWaterContainer(_ input: WaterContainerInput) async throws -> WaterContainer {
        let existing = store.all(LocalWaterContainer.self)
        let row = LocalWaterContainer(
            id: (existing.map(\.id).max() ?? 0) + 1,
            name: input.name,
            volume: input.volume,
            unit: input.unit,
            isPrimary: existing.isEmpty,
            servingsPerContainer: input.servingsPerContainer
        )
        store.insert(row)
        return Self.container(row)
    }

    func setPrimaryWaterContainer(id: Int) async throws {
        for row in store.all(LocalWaterContainer.self) {
            row.isPrimary = row.id == id
        }
        store.save()
    }

    func deleteWaterContainer(id: Int) async throws {
        guard let row = store.fetch(LocalWaterContainer.self, where: #Predicate { $0.id == id }).first else { return }
        let wasPrimary = row.isPrimary
        store.delete(row)
        // Leaving no primary behind would silently drop the quick-add back to
        // the generic 250 ml with nothing on screen explaining why.
        if wasPrimary, let next = store.all(LocalWaterContainer.self, sortBy: [SortDescriptor(\.id)]).first {
            next.isPrimary = true
            store.save()
        }
    }

    // MARK: - Body

    static func measurements(_ row: LocalCheckIn) -> BodyMeasurements {
        BodyMeasurements(
            id: row.id,
            weight: row.weight,
            neck: row.neck,
            waist: row.waist,
            hips: row.hips,
            height: row.height,
            bodyFatPercentage: row.bodyFatPercentage,
            muscleMassKg: row.muscleMassKg,
            boneMassKg: row.boneMassKg,
            bodyWaterPercentage: row.bodyWaterPercentage,
            bmr: row.bmr
        )
    }

    static func set(_ field: BodyField, _ value: Double?, on row: LocalCheckIn) {
        switch field {
        case .weight: row.weight = value
        case .waist: row.waist = value
        case .hips: row.hips = value
        case .neck: row.neck = value
        case .height: row.height = value
        case .bodyFatPercentage: row.bodyFatPercentage = value
        case .muscleMassKg: row.muscleMassKg = value
        case .boneMassKg: row.boneMassKg = value
        case .bodyWaterPercentage: row.bodyWaterPercentage = value
        case .bmr: row.bmr = value
        }
    }

    static func fill(_ row: LocalCheckIn, _ values: BodyMeasurements) {
        for field in BodyField.allCases { set(field, values.value(for: field), on: row) }
    }

    func bodyMeasurements(date: Date) async throws -> BodyMeasurements {
        let key = LocalDay.key(date)
        guard let row = store.fetch(LocalCheckIn.self, where: #Predicate { $0.dayKey == key }).first else {
            return .none
        }
        return Self.measurements(row)
    }

    /// Per-field upsert, exactly like the server's.
    ///
    /// A field absent from `values` is left untouched; a field present with
    /// nil is cleared. That distinction is the whole reason the weight sheet
    /// and the measurements sheet can both write the same day's row without
    /// one blanking the other's numbers.
    func upsertBodyMeasurements(_ input: BodyMeasurementsInput) async throws -> BodyMeasurements {
        // Matches the server, which answers a literal `null` for a body with
        // no measurement keys because it has nothing to upsert.
        guard !input.values.isEmpty else { throw APIError.invalidResponse }

        let key = LocalDay.key(input.date)
        let row = store.fetch(LocalCheckIn.self, where: #Predicate { $0.dayKey == key }).first ?? {
            let fresh = LocalCheckIn(dayKey: key)
            store.context.insert(fresh)
            return fresh
        }()

        for (field, value) in input.values { Self.set(field, value, on: row) }
        store.save()
        return Self.measurements(row)
    }

    /// Deletes the whole day's row, which is the only delete the server
    /// offers — there is no per-field delete, only a per-field clear.
    func deleteBodyMeasurements(id: String) async throws {
        guard let row = store.fetch(LocalCheckIn.self, where: #Predicate { $0.id == id }).first else { return }
        store.delete(row)
    }

    // MARK: - Progress ranges

    /// Raw per-entry rows, unaggregated — the same shape Progress sums
    /// itself. Nutrition is deliberately not pre-totalled here: the server's
    /// aggregates re-scale by quantity a second time, and summing the rows is
    /// what keeps a chart point agreeing with the Diary day behind it.
    func foodEntries(from start: Date, to end: Date) async throws -> [FoodEntryRangeRow] {
        let startKey = LocalDay.key(start)
        let endKey = LocalDay.key(end)
        return store
            .fetch(
                LocalFoodEntry.self,
                where: #Predicate { $0.dayKey >= startKey && $0.dayKey <= endKey },
                sortBy: [SortDescriptor(\.dayKey)]
            )
            .map {
                FoodEntryRangeRow(
                    entryDate: $0.dayKey,
                    calories: $0.calories,
                    protein: $0.protein,
                    carbs: $0.carbs,
                    fat: $0.fat
                )
            }
    }

    func bodyMeasurements(from start: Date, to end: Date) async throws -> [DatedBodyMeasurements] {
        let startKey = LocalDay.key(start)
        let endKey = LocalDay.key(end)
        return store
            .fetch(
                LocalCheckIn.self,
                where: #Predicate { $0.dayKey >= startKey && $0.dayKey <= endKey },
                sortBy: [SortDescriptor(\.dayKey, order: .reverse)]
            )
            .map { DatedBodyMeasurements(entryDate: $0.dayKey, measurements: Self.measurements($0)) }
    }

    /// The aggregate `/api/exercise-stats/summary` would return.
    ///
    /// The Health "Active Calories" sentinel is excluded, which the server
    /// does in SQL. It's a real entry row with zero duration, so counting it
    /// would inflate both the calorie total and the workout count on every
    /// day Health has synced. The exclusion compares against the one shared
    /// `healthActiveEnergyName`, so there is one definition of what that row is.
    ///
    /// Buckets are emitted only for days that have exercise; padding the rest
    /// to zero is the view model's job and it already does it.
    func exerciseSummary(from start: Date, to end: Date) async throws -> ExerciseRangeSummary {
        let startKey = LocalDay.key(start)
        let endKey = LocalDay.key(end)
        let rows = store.fetch(
            LocalExerciseEntry.self,
            where: #Predicate { $0.dayKey >= startKey && $0.dayKey <= endKey },
            sortBy: [SortDescriptor(\.dayKey)]
        )

        var byDay: [String: [LocalExerciseEntry]] = [:]
        // The shared name, not a summary built per row: building one decoded
        // the row's sets JSON just to read its name.
        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        for row in rows where row.name != sentinel {
            byDay[row.dayKey, default: []].append(row)
        }

        let buckets = byDay.keys.sorted().map { key -> ExerciseRangeSummary.Bucket in
            let day = byDay[key] ?? []
            let distance = day.reduce(0.0) { $0 + ($1.distance ?? 0) }
            return ExerciseRangeSummary.Bucket(
                startDate: key,
                durationMinutes: day.reduce(0.0) { $0 + $1.durationMinutes },
                caloriesBurned: day.reduce(0.0) { $0 + $1.caloriesBurned },
                workoutCount: day.count,
                // The server reports distance in meters; local mode logs it
                // in the user's own distance unit, same "no conversion"
                // rule Module 5 already applies to weight/measurements — so
                // this total is unit-less and the card should treat it as
                // such, not assume meters.
                distanceMeters: distance > 0 ? distance : nil,
                totalLiftedVolumeKg: nil
            )
        }

        return ExerciseRangeSummary(
            totals: .init(
                totalDurationMinutes: buckets.reduce(0.0) { $0 + $1.durationMinutes },
                totalCaloriesBurned: buckets.reduce(0.0) { $0 + $1.caloriesBurned },
                workoutCount: buckets.reduce(0) { $0 + $1.workoutCount },
                totalDistanceMeters: buckets.compactMap(\.distanceMeters).reduce(0, +),
                totalLiftedVolumeKg: nil
            ),
            intervalsBreakdown: buckets
        )
    }
}
