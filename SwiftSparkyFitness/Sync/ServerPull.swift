//
//  ServerPull.swift
//  SwiftSparkyFitness
//
//  Brings a server's diary into a device store for a range of days, as a
//  merge — never a wipe. See docs/SYNC_SWITCHING_PLAN.md, steps 4 and 5.
//
//  The rules, which are the whole design:
//
//  - Rows this device hasn't sent yet, or has edited since, are left alone:
//    they're newer than the server's copy, and the next push sends them.
//  - A linked row the device hasn't touched takes the server's values.
//  - A linked row the server no longer has (inside the range) is deleted
//    here too — without a tombstone, since the server did it first.
//  - A server row the device has never seen is added, under the server's id,
//    and linked.
//  - A row deleted here and waiting to be deleted on the server stays
//    deleted.
//
//  Two phases, like the import it replaces: everything is read first, then
//  applied in one save. A connection dropped mid-read changes nothing here.
//
//  The server has no "changed since" feed and no record of deletes, so the
//  range is the only way to see either. Callers pick it: the whole account
//  for a move to this device, recent days for a routine sync, one day when
//  the user opens it.
//

import Foundation
import SwiftData

@MainActor
final class ServerPull {
    struct Progress: Equatable {
        var daysRead: Int
        var totalDays: Int
    }

    struct Report: Equatable {
        var added = 0
        var updated = 0
        var deleted = 0
    }

    let store: LocalStore
    let server: SyncServer
    let account: String

    /// Days fetched at once. Each day is two requests; this keeps a year to
    /// seconds without hammering a home server.
    private static let concurrentDays = 6

    init(store: LocalStore, server: SyncServer, account: String) {
        self.store = store
        self.server = server
        self.account = account
    }

    // MARK: - Read

    private struct Day {
        let key: String
        let date: Date
        let summary: DailySummary
        let water: [WaterLogEntry]
    }

    private struct Snapshot {
        var days: [Day] = []
        var mealTypes: [MealType] = []
        var preferences: UserPreferences?
        var goals: [String: NutritionGoals] = [:]
        var body: [DatedBodyMeasurements] = []
    }

    func run(from start: Date, to end: Date = Date(), onProgress: ((Progress) -> Void)? = nil) async throws -> Report {
        let snapshot = try await read(from: start, to: end, onProgress: onProgress)
        try Task.checkCancellation()
        return try apply(snapshot)
    }

    private func read(from start: Date, to end: Date, onProgress: ((Progress) -> Void)?) async throws -> Snapshot {
        let calendar = Calendar.current
        var dates: [Date] = []
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            dates.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard let first = dates.first else { return Snapshot() }

        var snapshot = Snapshot()
        snapshot.mealTypes = try await server.mealTypes()
        snapshot.preferences = try? await server.userPreferences()
        snapshot.goals = try await server.goals(from: first, to: last)
        snapshot.body = try await server.bodyMeasurements(from: first, to: last)

        onProgress?(Progress(daysRead: 0, totalDays: dates.count))
        let server = self.server
        try await withThrowingTaskGroup(of: Day.self) { group in
            var pending = dates[...]
            func startNext() {
                guard let date = pending.popFirst() else { return }
                group.addTask { @MainActor in
                    let summary = try await server.dailySummary(date: date)
                    let water = try await server.waterLog(date: date)
                    return Day(key: LocalDay.key(date), date: date, summary: summary, water: water)
                }
            }
            for _ in 0..<Self.concurrentDays { startNext() }
            while let fetched = try await group.next() {
                snapshot.days.append(fetched)
                onProgress?(Progress(daysRead: snapshot.days.count, totalDays: dates.count))
                startNext()
            }
        }
        snapshot.days.sort { $0.key < $1.key }
        return snapshot
    }

    // MARK: - Apply

    private func apply(_ snapshot: Snapshot) throws -> Report {
        var report = Report()
        let now = Date()
        let dayKeys = Set(snapshot.days.map(\.key))

        try store.applyingRemoteChanges {
            let meals = applyMealTypes(snapshot.mealTypes, now: now, report: &report)
            if let preferences = snapshot.preferences { applyPreferences(preferences, now: now) }
            applyFoodEntries(snapshot.days, dayKeys: dayKeys, meals: meals, now: now, report: &report)
            applyExerciseEntries(snapshot.days, dayKeys: dayKeys, now: now, report: &report)
            applyWater(snapshot.days, dayKeys: dayKeys, now: now, report: &report)
            applyCheckIns(snapshot.body, dayKeys: dayKeys, now: now, report: &report)
            applyGoals(snapshot.goals, now: now, report: &report)
            guard store.save() else {
                store.context.rollback()
                throw ServerPush.LocalSaveFailure(underlying: store.lastSaveError)
            }
        }
        return report
    }

    /// The row as the server has it now: stamped and linked at one instant,
    /// so it reads as in sync rather than as a local edit.
    private func markSynced<Row: SyncTracked>(_ row: Row, serverId: String, now: Date, serverVariantId: String? = nil) {
        row.updatedAt = now
        store.setLink(row, serverId: serverId, account: account, serverVariantId: serverVariantId, version: now)
    }

    /// serverId → local key, for every row of a kind this account links.
    private func localKeys(kind: String) -> [String: String] {
        var keys: [String: String] = [:]
        for link in store.links(kind: kind, account: account) { keys[link.serverId] = link.localKey }
        return keys
    }

    /// Keys waiting to be deleted on the server: their server copies must not
    /// be brought back here in the meantime.
    private func tombstoned(kind: String) -> Set<String> {
        Set(store.tombstones(kind: kind).map(\.localKey))
    }

    private func dirty<Row: SyncTracked>(_ row: Row) -> Bool { store.needsPush(row, account: account) }

    /// Removes a row the server deleted, and its link, without a tombstone.
    private func deleteLocally<Row: SyncTracked>(_ row: Row) {
        if let link = store.link(for: row, account: account) { store.context.delete(link) }
        store.context.delete(row)
    }

    // MARK: Meal types

    /// Returns server meal id → local meal id.
    private func applyMealTypes(_ serverMeals: [MealType], now: Date, report: inout Report) -> [String: String] {
        var mapping: [String: String] = [:]
        let linked = localKeys(kind: LocalMealType.syncKind)
        let locals = store.all(LocalMealType.self)
        for meal in serverMeals {
            let row = linked[meal.id].flatMap { key in locals.first { $0.id == key } }
                ?? locals.first { $0.name.caseInsensitiveCompare(meal.name) == .orderedSame }
            if let row {
                mapping[meal.id] = row.id
                let isLinked = store.link(for: row, account: account) != nil
                // A seeded row nobody touched carries no intent; an unlinked
                // edited one is waiting to be pushed.
                let untouched = row.updatedAt == .distantPast
                if isLinked ? !dirty(row) : untouched {
                    // The server's four keep this device's capitalised names.
                    if !row.isSystemDefault { row.name = meal.name; row.sortOrder = meal.sortOrder }
                    if let visible = meal.isVisible, visible != row.isVisible { row.isVisible = visible; report.updated += 1 }
                    markSynced(row, serverId: meal.id, now: now)
                }
            } else {
                let created = LocalMealType(id: meal.id, name: meal.name, sortOrder: meal.sortOrder,
                                            isVisible: meal.isVisible ?? true, isSystemDefault: meal.userId == nil)
                store.context.insert(created)
                markSynced(created, serverId: meal.id, now: now)
                mapping[meal.id] = created.id
                report.added += 1
            }
        }
        return mapping
    }

    private func localMealId(serverId: String?, name: String, mapping: [String: String]) -> (id: String, name: String) {
        if let serverId, let local = mapping[serverId] {
            let localName = store.fetch(LocalMealType.self, where: #Predicate { $0.id == local }).first?.name ?? name
            return (local, localName)
        }
        if let match = store.all(LocalMealType.self).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return (match.id, match.name)
        }
        return (store.all(LocalMealType.self, sortBy: [SortDescriptor(\.sortOrder)]).first?.id ?? "", name)
    }

    // MARK: Preferences

    private func applyPreferences(_ server: UserPreferences, now: Date) {
        let row = store.all(LocalPreferences.self).first ?? {
            let fresh = LocalPreferences()
            store.context.insert(fresh)
            return fresh
        }()
        let isLinked = store.link(for: row, account: account) != nil
        guard isLinked ? !dirty(row) : row.updatedAt == .distantPast else { return }
        for setting in UserPreferences.Setting.allCases {
            LocalAPIClient.apply(setting, server.value(for: setting), to: row)
        }
        markSynced(row, serverId: row.id, now: now)
    }

    // MARK: Food entries

    private func applyFoodEntries(_ days: [Day], dayKeys: Set<String>, meals: [String: String], now: Date, report: inout Report) {
        let kind = LocalFoodEntry.syncKind
        let linked = localKeys(kind: kind)
        let pendingDelete = tombstoned(kind: kind)
        var rowsById: [String: LocalFoodEntry] = [:]
        for row in store.all(LocalFoodEntry.self) { rowsById[row.id] = row }
        var seen: Set<String> = []

        for day in days {
            for entry in day.summary.foodEntries {
                seen.insert(entry.id)
                let localKey = linked[entry.id]
                if let localKey, pendingDelete.contains(localKey) { continue }
                let meal = localMealId(serverId: entry.mealTypeId, name: entry.mealType, mapping: meals)
                if let localKey, let row = rowsById[localKey] {
                    guard !dirty(row) else { continue }
                    if Self.differs(row, entry, dayKey: day.key, meal: meal) {
                        Self.fill(row, entry, day: day, meal: meal)
                        report.updated += 1
                    }
                    markSynced(row, serverId: entry.id, now: now)
                } else if localKey == nil {
                    ensureFood(for: entry, now: now)
                    let row = LocalFoodEntry(id: entry.id, entryDate: day.date, foodId: entry.foodId ?? "imported-\(entry.id)",
                                             foodName: entry.foodName, mealTypeId: meal.id, mealTypeName: meal.name,
                                             quantity: entry.quantity, unit: entry.unit, servingSize: 0, servingUnit: "",
                                             calories: 0, protein: 0, carbs: 0, fat: 0)
                    Self.fill(row, entry, day: day, meal: meal)
                    store.context.insert(row)
                    markSynced(row, serverId: entry.id, now: now)
                    rowsById[row.id] = row
                    report.added += 1
                }
            }
        }
        // Linked rows inside the range the server no longer has.
        for (serverId, localKey) in linked where !seen.contains(serverId) {
            guard let row = rowsById[localKey], dayKeys.contains(row.dayKey), !dirty(row) else { continue }
            deleteLocally(row)
            report.deleted += 1
        }
    }

    private static func differs(_ row: LocalFoodEntry, _ entry: FoodEntrySummary, dayKey: String, meal: (id: String, name: String)) -> Bool {
        row.dayKey != dayKey || row.mealTypeId != meal.id || abs(row.quantity - entry.quantity) > 0.0001
            || row.unit != entry.unit || abs(row.calories - entry.calories) > 0.0001
            || abs(row.protein - (entry.protein ?? 0)) > 0.0001 || abs(row.carbs - (entry.carbs ?? 0)) > 0.0001
            || abs(row.fat - (entry.fat ?? 0)) > 0.0001 || row.foodName != entry.foodName
    }

    /// Nutrition is stored as the server reports it for the entry — the same
    /// numbers server mode has always displayed for it.
    private static func fill(_ row: LocalFoodEntry, _ entry: FoodEntrySummary, day: Day, meal: (id: String, name: String)) {
        row.dayKey = day.key
        row.entryDate = day.date
        if let foodId = entry.foodId { row.foodId = foodId }
        row.foodName = entry.foodName
        row.brandName = entry.brandName
        row.mealTypeId = meal.id
        row.mealTypeName = meal.name
        row.quantity = entry.quantity
        row.unit = entry.unit
        row.servingSize = entry.servingSize ?? entry.quantity
        row.servingUnit = entry.servingUnit ?? entry.unit
        row.calories = entry.calories
        row.protein = entry.protein ?? 0
        row.carbs = entry.carbs ?? 0
        row.fat = entry.fat ?? 0
    }

    /// The food an entry points at, so it shows in recents and can be logged
    /// again offline. Keyed by the server's food id and linked with its
    /// variant, so logging it again here reuses the same server food.
    private func ensureFood(for entry: FoodEntrySummary, now: Date) {
        guard let foodId = entry.foodId else { return }
        guard store.fetch(LocalFood.self, where: #Predicate { $0.id == foodId }).isEmpty else { return }
        let serving = entry.servingSize ?? entry.quantity
        let scale = entry.quantity > 0 ? serving / entry.quantity : 1
        let food = LocalFood(id: foodId, name: entry.foodName, brand: entry.brandName,
                             servingSize: serving, servingUnit: entry.servingUnit ?? entry.unit,
                             calories: entry.calories * scale, protein: (entry.protein ?? 0) * scale,
                             carbs: (entry.carbs ?? 0) * scale, fat: (entry.fat ?? 0) * scale, isCustom: false)
        store.context.insert(food)
        markSynced(food, serverId: foodId, now: now, serverVariantId: entry.variantId)
    }

    // MARK: Exercise

    private func applyExerciseEntries(_ days: [Day], dayKeys: Set<String>, now: Date, report: inout Report) {
        let kind = LocalExerciseEntry.syncKind
        let linked = localKeys(kind: kind)
        let pendingDelete = tombstoned(kind: kind)
        var rowsById: [String: LocalExerciseEntry] = [:]
        for row in store.all(LocalExerciseEntry.self) { rowsById[row.id] = row }
        var seen: Set<String> = []

        for day in days {
            for session in day.summary.exerciseSessions {
                if session.isHealthActiveEnergy {
                    applyActiveEnergy(session, day: day, rows: rowsById, now: now, report: &report)
                    continue
                }
                seen.insert(session.id)
                let localKey = linked[session.id]
                if let localKey, pendingDelete.contains(localKey) { continue }
                let exerciseId = ensureExercise(for: session, now: now)
                if let localKey, let row = rowsById[localKey] {
                    guard !dirty(row) else { continue }
                    if Self.differs(row, session, dayKey: day.key, exerciseId: exerciseId) {
                        Self.fill(row, session, day: day, exerciseId: exerciseId)
                        report.updated += 1
                    }
                    markSynced(row, serverId: session.id, now: now)
                } else if localKey == nil {
                    let row = LocalExerciseEntry(id: session.id, entryDate: day.date, exerciseId: exerciseId,
                                                 name: "", durationMinutes: 0, caloriesBurned: 0)
                    Self.fill(row, session, day: day, exerciseId: exerciseId)
                    store.context.insert(row)
                    markSynced(row, serverId: session.id, now: now)
                    rowsById[row.id] = row
                    report.added += 1
                }
            }
        }
        for (serverId, localKey) in linked where !seen.contains(serverId) && !serverId.hasPrefix("active-energy:") {
            guard let row = rowsById[localKey], dayKeys.contains(row.dayKey), !dirty(row) else { continue }
            deleteLocally(row)
            report.deleted += 1
        }
    }

    /// Health's figure is one per day on both sides, whatever each side's id.
    private func applyActiveEnergy(_ session: ExerciseSessionSummary, day: Day, rows: [String: LocalExerciseEntry], now: Date, report: inout Report) {
        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        let serverId = "active-energy:\(day.key)"
        let calories = session.caloriesBurned ?? 0
        if let row = rows.values.first(where: { $0.dayKey == day.key && $0.name == sentinel }) {
            // Unsent or edited here: this device's figure goes out next push.
            guard !dirty(row) else { return }
            if abs(row.caloriesBurned - calories) > 0.0001 { row.caloriesBurned = calories; report.updated += 1 }
            markSynced(row, serverId: serverId, now: now)
        } else {
            let exerciseId = store.all(LocalExercise.self).first { $0.name == sentinel }?.id ?? {
                let created = LocalExercise(name: sentinel, category: "Cardio")
                store.context.insert(created)
                return created.id
            }()
            let row = LocalExerciseEntry(entryDate: day.date, exerciseId: exerciseId, name: sentinel,
                                         durationMinutes: 0, caloriesBurned: calories)
            store.context.insert(row)
            markSynced(row, serverId: serverId, now: now)
            report.added += 1
        }
    }

    private static func differs(_ row: LocalExerciseEntry, _ session: ExerciseSessionSummary, dayKey: String, exerciseId: String) -> Bool {
        row.dayKey != dayKey || row.exerciseId != exerciseId
            || abs(row.durationMinutes - (session.durationMinutes ?? 0)) > 0.0001
            || abs(row.caloriesBurned - (session.caloriesBurned ?? 0)) > 0.0001
            || row.distance != session.distance || row.avgHeartRate != session.avgHeartRate
            || row.notes != session.notes || row.entryTime?.prefix(5) != session.entryTime?.prefix(5)
            || decodedSets(row.setsJSON) != decodedSets(setsJSON(session))
    }

    /// Compared as values, not as JSON text: key order in an encoded object
    /// isn't guaranteed, so equal sets can serialise differently.
    private static func decodedSets(_ json: String?) -> [ExerciseSetInput] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ExerciseSetInput].self, from: data)) ?? []
    }

    private static func fill(_ row: LocalExerciseEntry, _ session: ExerciseSessionSummary, day: Day, exerciseId: String) {
        row.dayKey = day.key
        row.entryDate = day.date
        row.exerciseId = exerciseId
        row.name = session.asExercise.name
        row.durationMinutes = session.durationMinutes ?? 0
        row.caloriesBurned = session.caloriesBurned ?? 0
        row.modality = session.effectiveModality.rawValue
        row.distance = session.distance
        row.avgHeartRate = session.avgHeartRate
        row.notes = session.notes
        row.entryTime = session.entryTime.map { String($0.prefix(5)) }
        row.setsJSON = setsJSON(session)
    }

    /// Sets in the same JSON local mode writes, so a synced session edits
    /// exactly like one logged here.
    private static func setsJSON(_ session: ExerciseSessionSummary) -> String? {
        let sets = session.setsList.map {
            ExerciseSetInput(setNumber: $0.setNumber, setType: $0.setType ?? "Working Set",
                             reps: $0.reps, weight: $0.weight, rpe: $0.rpe, notes: $0.notes)
        }
        guard !sets.isEmpty, let data = try? JSONEncoder().encode(sets) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The local exercise for a server session's exercise, created under the
    /// server's id the first time it is seen.
    private func ensureExercise(for session: ExerciseSessionSummary, now: Date) -> String {
        let exercise = session.asExercise
        let serverId = session.exerciseId ?? exercise.id
        if let key = store.links(kind: LocalExercise.syncKind, account: account).first(where: { $0.serverId == serverId })?.localKey,
           !store.fetch(LocalExercise.self, where: #Predicate { $0.id == key }).isEmpty {
            return key
        }
        if let existing = store.fetch(LocalExercise.self, where: #Predicate { $0.id == serverId }).first {
            markSynced(existing, serverId: serverId, now: now)
            return existing.id
        }
        let created = LocalExercise(id: serverId, name: exercise.name, category: exercise.category,
                                    modality: session.effectiveModality.rawValue)
        store.context.insert(created)
        markSynced(created, serverId: serverId, now: now)
        return created.id
    }

    // MARK: Water

    private func applyWater(_ days: [Day], dayKeys: Set<String>, now: Date, report: inout Report) {
        let kind = LocalWaterEntry.syncKind
        let linked = localKeys(kind: kind)
        let pendingDelete = tombstoned(kind: kind)
        var rowsById: [String: LocalWaterEntry] = [:]
        for row in store.all(LocalWaterEntry.self) { rowsById[row.id] = row }
        var seen: Set<String> = []

        for day in days {
            for drink in day.water {
                seen.insert(drink.id)
                let localKey = linked[drink.id]
                if let localKey, pendingDelete.contains(localKey) { continue }
                if let localKey, let row = rowsById[localKey] {
                    guard !dirty(row) else { continue }
                    if abs(row.waterMl - drink.waterMl) > 0.0001 || row.dayKey != day.key {
                        row.waterMl = drink.waterMl
                        row.dayKey = day.key
                        report.updated += 1
                    }
                    markSynced(row, serverId: drink.id, now: now)
                } else if localKey == nil {
                    let row = LocalWaterEntry(id: drink.id, dayKey: day.key, waterMl: drink.waterMl,
                                              source: Self.localWaterSource(drink.source),
                                              containerName: drink.containerName, loggedAt: drink.loggedAt ?? day.date)
                    store.context.insert(row)
                    markSynced(row, serverId: drink.id, now: now)
                    rowsById[row.id] = row
                    report.added += 1
                }
            }
        }
        for (serverId, localKey) in linked where !seen.contains(serverId) {
            guard let row = rowsById[localKey], dayKeys.contains(row.dayKey), !dirty(row) else { continue }
            deleteLocally(row)
            report.deleted += 1
        }
    }

    /// Local mode tells only "manual" (undoable) from "food". A drink this app
    /// sent comes back tagged with the sync source; it is still a manual one.
    private static func localWaterSource(_ source: String?) -> String {
        switch source {
        case nil, "manual", SyncServerSource.tag: return "manual"
        case let other?: return other
        }
    }

    // MARK: Check-ins

    private func applyCheckIns(_ rows: [DatedBodyMeasurements], dayKeys: Set<String>, now: Date, report: inout Report) {
        var byDay: [String: LocalCheckIn] = [:]
        for row in store.all(LocalCheckIn.self) { byDay[row.dayKey] = row }
        var seenDays: Set<String> = []
        let pendingDelete = tombstoned(kind: LocalCheckIn.syncKind)
        let linked = localKeys(kind: LocalCheckIn.syncKind)

        for dated in rows {
            let key = String(dated.entryDate.prefix(10))
            seenDays.insert(key)
            let values = dated.measurements
            let serverId = values.id ?? key
            if let row = byDay[key] {
                // Unlinked means logged here and not yet sent: newer.
                guard store.link(for: row, account: account) != nil, !dirty(row) else { continue }
                if LocalAPIClient.measurements(row) != Self.withId(values, row.id) {
                    Self.fill(row, values)
                    report.updated += 1
                }
                markSynced(row, serverId: serverId, now: now)
            } else if !(linked[serverId].map(pendingDelete.contains) ?? false) {
                let row = LocalCheckIn(id: serverId, dayKey: key)
                Self.fill(row, values)
                store.context.insert(row)
                markSynced(row, serverId: serverId, now: now)
                byDay[key] = row
                report.added += 1
            }
        }
        for row in byDay.values where dayKeys.contains(row.dayKey) && !seenDays.contains(row.dayKey) {
            guard store.link(for: row, account: account) != nil, !dirty(row) else { continue }
            deleteLocally(row)
            report.deleted += 1
        }
    }

    private static func withId(_ values: BodyMeasurements, _ id: String) -> BodyMeasurements {
        BodyMeasurements(id: id, weight: values.weight, neck: values.neck, waist: values.waist, hips: values.hips,
                         height: values.height, bodyFatPercentage: values.bodyFatPercentage,
                         muscleMassKg: values.muscleMassKg, boneMassKg: values.boneMassKg,
                         bodyWaterPercentage: values.bodyWaterPercentage, bmr: values.bmr)
    }

    private static func fill(_ row: LocalCheckIn, _ values: BodyMeasurements) {
        row.weight = values.weight
        row.neck = values.neck
        row.waist = values.waist
        row.hips = values.hips
        row.height = values.height
        row.bodyFatPercentage = values.bodyFatPercentage
        row.muscleMassKg = values.muscleMassKg
        row.boneMassKg = values.boneMassKg
        row.bodyWaterPercentage = values.bodyWaterPercentage
        row.bmr = values.bmr
    }

    // MARK: Goals

    /// The server answers per day with goals carried forward; locally a row
    /// means "from this day on". So a row is written only on a day where the
    /// server's goal differs from what this device would already show —
    /// never one per day, and never over a goal set here and not yet sent.
    private func applyGoals(_ serverGoals: [String: NutritionGoals], now: Date, report: inout Report) {
        let rows = store.all(LocalGoalRow.self, sortBy: [SortDescriptor(\.dayKey)])
        var effective: [(key: String, goals: NutritionGoals)] = rows.map { ($0.dayKey, LocalAPIClient.goals(from: $0)) }

        func localGoals(on key: String) -> NutritionGoals? {
            effective.last { $0.key <= key }?.goals
        }

        for key in serverGoals.keys.sorted() {
            guard let server = serverGoals[key], server.isSet else { continue }
            let local = localGoals(on: key)
            // Both through the same conversion the local store applies, so
            // equal goals compare equal whatever each side's raw bag holds.
            if let local, LocalAPIClient.bag(from: local, dayKey: key) == LocalAPIClient.bag(from: server, dayKey: key) { continue }
            if let row = store.fetch(LocalGoalRow.self, where: #Predicate { $0.dayKey == key }).first {
                guard !dirty(row) else { continue }
                row.rawJSON = Self.encode(server, dayKey: key)
                markSynced(row, serverId: key, now: now)
                report.updated += 1
            } else {
                let row = LocalGoalRow(dayKey: key, rawJSON: Self.encode(server, dayKey: key))
                store.context.insert(row)
                markSynced(row, serverId: key, now: now)
                report.added += 1
            }
            effective.append((key, server))
            effective.sort { $0.key < $1.key }
        }
    }

    private static func encode(_ goals: NutritionGoals, dayKey: String) -> Data {
        (try? JSONEncoder().encode(LocalAPIClient.bag(from: goals, dayKey: dayKey))) ?? Data()
    }
}

extension LocalStore {
    /// True when this device already holds a diary of its own — a choice to
    /// copy a server's diary here then has to say that the two merge.
    func hasDiaryEntries() -> Bool {
        !all(LocalFoodEntry.self).isEmpty || !all(LocalExerciseEntry.self).isEmpty
            || !all(LocalWaterEntry.self).isEmpty || !all(LocalCheckIn.self).isEmpty
    }
}
