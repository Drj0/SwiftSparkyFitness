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

    /// This account's links, loaded once per apply and kept current as rows
    /// are linked, so no row costs a fetch to look up.
    private struct Links {
        var byLocal: [String: LocalSyncLink] = [:]
        var byServer: [String: String] = [:]

        static func key(_ kind: String, _ id: String) -> String { "\(kind)|\(id)" }

        func link(_ kind: String, local: String) -> LocalSyncLink? { byLocal[Self.key(kind, local)] }
        func localKey(_ kind: String, server: String) -> String? { byServer[Self.key(kind, server)] }
    }

    private var links = Links()
    private var tombstones: [String: Set<String>] = [:]

    private func apply(_ snapshot: Snapshot) throws -> Report {
        var report = Report()
        let now = Date()
        let dayKeys = Set(snapshot.days.map(\.key))

        links = Links()
        for link in store.all(LocalSyncLink.self) where link.serverAccount == account {
            links.byLocal[Links.key(link.kind, link.localKey)] = link
            links.byServer[Links.key(link.kind, link.serverId)] = link.localKey
        }
        tombstones = [:]
        for tombstone in store.all(LocalTombstone.self) { tombstones[tombstone.kind, default: []].insert(tombstone.localKey) }

        try store.applyingRemoteChanges {
            let meals = applyMealTypes(snapshot.mealTypes, now: now, report: &report)
            if let preferences = snapshot.preferences { applyPreferences(preferences, now: now) }
            applyFoodEntries(snapshot.days, dayKeys: dayKeys, meals: meals, now: now, report: &report)
            applyExerciseEntries(snapshot.days, dayKeys: dayKeys, now: now, report: &report)
            applyWater(snapshot.days, dayKeys: dayKeys, now: now, report: &report)
            applyCheckIns(snapshot.body, dayKeys: dayKeys, now: now, report: &report)
            applyGoals(snapshot.goals, now: now, report: &report)
            // One save for the whole range: until it lands, nothing here has
            // changed, and a failure rolls all of it back.
            guard store.save() else {
                store.context.rollback()
                throw ServerPush.LocalSaveFailure(underlying: store.lastSaveError)
            }
        }
        return report
    }

    private func link<Row: SyncTracked>(for row: Row) -> LocalSyncLink? {
        links.link(Row.syncKind, local: row.syncKey)
    }

    /// Unsent, or edited here since it last matched the server.
    private func dirty<Row: SyncTracked>(_ row: Row) -> Bool {
        guard let link = link(for: row) else { return true }
        return row.updatedAt > link.linkedAt
    }

    /// The row as the server has it now: stamped and linked at one instant,
    /// so it reads as in sync rather than as a local edit. Only for rows that
    /// were inserted, changed, or not yet linked — re-stamping unchanged
    /// rows would make every routine pull rewrite (and re-upload to iCloud)
    /// the whole range.
    private func markSynced<Row: SyncTracked>(_ row: Row, serverId: String, now: Date, serverVariantId: String? = nil) {
        row.updatedAt = now
        let link = store.setLink(kind: Row.syncKind, localKey: row.syncKey, serverId: serverId, account: account,
                                 serverVariantId: serverVariantId, version: now, save: false)
        links.byLocal[Links.key(Row.syncKind, row.syncKey)] = link
        links.byServer[Links.key(Row.syncKind, serverId)] = row.syncKey
    }

    private func isTombstoned(_ kind: String, _ localKey: String?) -> Bool {
        guard let localKey else { return false }
        return tombstones[kind]?.contains(localKey) ?? false
    }

    /// Removes a row the server deleted, and its link, without a tombstone.
    private func deleteLocally<Row: SyncTracked>(_ row: Row) {
        let key = Links.key(Row.syncKind, row.syncKey)
        if let link = links.byLocal.removeValue(forKey: key) {
            links.byServer[Links.key(Row.syncKind, link.serverId)] = nil
            store.context.delete(link)
        }
        store.context.delete(row)
    }

    // MARK: Meal types

    /// Returns server meal id → (local id, local name).
    private func applyMealTypes(_ serverMeals: [MealType], now: Date, report: inout Report) -> [String: (id: String, name: String)] {
        let kind = LocalMealType.syncKind
        var mapping: [String: (id: String, name: String)] = [:]
        var locals = store.all(LocalMealType.self)
        for meal in serverMeals {
            let linkedKey = links.localKey(kind, server: meal.id)
            // Deleted here, waiting to be deleted there.
            if isTombstoned(kind, linkedKey) { continue }
            let isSystem = meal.userId == nil
            // A linked row first; otherwise only an *unlinked* row may be
            // matched — the server's four by their seeded id (renaming a seed
            // here must not make the server's one look new), custom ones by
            // name.
            let row = linkedKey.flatMap { key in locals.first { $0.id == key } }
                ?? locals.first { local in
                    guard link(for: local) == nil else { return false }
                    return isSystem
                        ? local.isSystemDefault && (local.id == meal.name.lowercased() || local.name.caseInsensitiveCompare(meal.name) == .orderedSame)
                        : local.name.caseInsensitiveCompare(meal.name) == .orderedSame
                }
            if let row {
                mapping[meal.id] = (row.id, row.name)
                let isLinked = link(for: row) != nil
                // A seeded row nobody touched carries no intent; an unlinked
                // edited one is waiting to be pushed.
                guard isLinked ? !dirty(row) : row.updatedAt == .distantPast else { continue }
                var changed = false
                // The server's four keep this device's capitalised names.
                if !row.isSystemDefault, row.name != meal.name || row.sortOrder != meal.sortOrder {
                    row.name = meal.name
                    row.sortOrder = meal.sortOrder
                    changed = true
                }
                if let visible = meal.isVisible, visible != row.isVisible {
                    row.isVisible = visible
                    changed = true
                }
                if changed { report.updated += 1 }
                if changed || !isLinked { markSynced(row, serverId: meal.id, now: now) }
                mapping[meal.id] = (row.id, row.name)
            } else {
                let created = LocalMealType(id: meal.id, name: meal.name, sortOrder: meal.sortOrder,
                                            isVisible: meal.isVisible ?? true, isSystemDefault: isSystem)
                store.context.insert(created)
                locals.append(created)
                markSynced(created, serverId: meal.id, now: now)
                mapping[meal.id] = (created.id, created.name)
                report.added += 1
            }
        }
        return mapping
    }

    private func localMeal(serverId: String?, name: String, mapping: [String: (id: String, name: String)]) -> (id: String, name: String) {
        if let serverId, let local = mapping[serverId] { return local }
        if let match = mapping.values.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        return mapping.values.first ?? ("", name)
    }

    // MARK: Preferences

    private func applyPreferences(_ server: UserPreferences, now: Date) {
        let row = store.all(LocalPreferences.self).first ?? {
            let fresh = LocalPreferences()
            store.context.insert(fresh)
            return fresh
        }()
        let isLinked = link(for: row) != nil
        guard isLinked ? !dirty(row) : row.updatedAt == .distantPast else { return }
        let before = DiaryArchive.archived(row)
        for setting in UserPreferences.Setting.allCases {
            LocalAPIClient.apply(setting, server.value(for: setting), to: row)
        }
        if DiaryArchive.archived(row) != before || !isLinked { markSynced(row, serverId: row.id, now: now) }
    }

    // MARK: Food entries

    private func applyFoodEntries(_ days: [Day], dayKeys: Set<String>, meals: [String: (id: String, name: String)], now: Date, report: inout Report) {
        let kind = LocalFoodEntry.syncKind
        var rowsById: [String: LocalFoodEntry] = [:]
        for row in store.all(LocalFoodEntry.self) { rowsById[row.id] = row }
        var seen: Set<String> = []

        for day in days {
            for entry in day.summary.foodEntries {
                seen.insert(entry.id)
                let localKey = links.localKey(kind, server: entry.id)
                if isTombstoned(kind, localKey) { continue }
                let meal = localMeal(serverId: entry.mealTypeId, name: entry.mealType, mapping: meals)
                if let localKey, let row = rowsById[localKey] {
                    guard !dirty(row) else { continue }
                    let foodId = localFood(for: entry, now: now) ?? row.foodId
                    if Self.differs(row, entry, dayKey: day.key, meal: meal, foodId: foodId) {
                        Self.fill(row, entry, day: day, meal: meal, foodId: foodId)
                        report.updated += 1
                        markSynced(row, serverId: entry.id, now: now)
                    }
                } else if localKey == nil {
                    let foodId = localFood(for: entry, now: now) ?? "imported-\(entry.id)"
                    let row = LocalFoodEntry(id: entry.id, entryDate: day.date, foodId: foodId,
                                             foodName: entry.foodName, mealTypeId: meal.id, mealTypeName: meal.name,
                                             quantity: entry.quantity, unit: entry.unit, servingSize: 0, servingUnit: "",
                                             calories: 0, protein: 0, carbs: 0, fat: 0)
                    Self.fill(row, entry, day: day, meal: meal, foodId: foodId)
                    store.context.insert(row)
                    markSynced(row, serverId: entry.id, now: now)
                    rowsById[row.id] = row
                    report.added += 1
                }
            }
        }
        // Linked rows inside the range the server no longer has.
        for (key, link) in links.byLocal where link.kind == kind && !seen.contains(link.serverId) {
            let localKey = String(key.dropFirst(kind.count + 1))
            guard let row = rowsById[localKey], dayKeys.contains(row.dayKey), !dirty(row) else { continue }
            deleteLocally(row)
            report.deleted += 1
        }
    }

    private static func differs(_ row: LocalFoodEntry, _ entry: FoodEntrySummary, dayKey: String, meal: (id: String, name: String), foodId: String) -> Bool {
        row.dayKey != dayKey || row.mealTypeId != meal.id || row.foodId != foodId
            || abs(row.quantity - entry.quantity) > 0.0001 || row.unit != entry.unit
            || abs(row.calories - entry.calories) > 0.0001
            || abs(row.protein - (entry.protein ?? 0)) > 0.0001 || abs(row.carbs - (entry.carbs ?? 0)) > 0.0001
            || abs(row.fat - (entry.fat ?? 0)) > 0.0001 || row.foodName != entry.foodName
    }

    /// Nutrition is stored as the server reports it for the entry — the same
    /// numbers server mode has always displayed for it.
    private static func fill(_ row: LocalFoodEntry, _ entry: FoodEntrySummary, day: Day, meal: (id: String, name: String), foodId: String) {
        row.dayKey = day.key
        row.entryDate = day.date
        row.foodId = foodId
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

    /// The local food behind a server entry's food, so it shows in recents
    /// and can be logged again offline. Through the food links first — a food
    /// this device created and pushed is the same food, under its local id —
    /// then a local food already under the server's id, then a new one.
    private func localFood(for entry: FoodEntrySummary, now: Date) -> String? {
        let kind = LocalFood.syncKind
        guard let serverFoodId = entry.foodId else { return nil }
        if let key = links.localKey(kind, server: serverFoodId),
           !store.fetch(LocalFood.self, where: #Predicate { $0.id == key }).isEmpty {
            return key
        }
        if let existing = store.fetch(LocalFood.self, where: #Predicate { $0.id == serverFoodId }).first {
            if link(for: existing) == nil { markSynced(existing, serverId: serverFoodId, now: now, serverVariantId: entry.variantId) }
            return existing.id
        }
        let serving = entry.servingSize ?? entry.quantity
        let scale = entry.quantity > 0 ? serving / entry.quantity : 1
        let food = LocalFood(id: serverFoodId, name: entry.foodName, brand: entry.brandName,
                             servingSize: serving, servingUnit: entry.servingUnit ?? entry.unit,
                             calories: entry.calories * scale, protein: (entry.protein ?? 0) * scale,
                             carbs: (entry.carbs ?? 0) * scale, fat: (entry.fat ?? 0) * scale, isCustom: false)
        store.context.insert(food)
        markSynced(food, serverId: serverFoodId, now: now, serverVariantId: entry.variantId)
        return food.id
    }

    // MARK: Exercise

    private func applyExerciseEntries(_ days: [Day], dayKeys: Set<String>, now: Date, report: inout Report) {
        let kind = LocalExerciseEntry.syncKind
        var rowsById: [String: LocalExerciseEntry] = [:]
        var sentinels: [String: LocalExerciseEntry] = [:]
        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        for row in store.all(LocalExerciseEntry.self) {
            rowsById[row.id] = row
            if row.name == sentinel { sentinels[row.dayKey] = row }
        }
        var exercises: [String: LocalExercise] = [:]
        for exercise in store.all(LocalExercise.self) { exercises[exercise.id] = exercise }
        var seen: Set<String> = []

        for day in days {
            for session in day.summary.exerciseSessions {
                if session.isHealthActiveEnergy {
                    applyActiveEnergy(session, day: day, sentinels: &sentinels, exercises: &exercises, now: now, report: &report)
                    continue
                }
                seen.insert(session.id)
                let localKey = links.localKey(kind, server: session.id)
                if isTombstoned(kind, localKey) { continue }
                if let localKey, let row = rowsById[localKey] {
                    guard !dirty(row) else { continue }
                    let exerciseId = localExercise(for: session, exercises: &exercises, now: now)
                    if Self.differs(row, session, dayKey: day.key, exerciseId: exerciseId) {
                        Self.fill(row, session, day: day, exerciseId: exerciseId)
                        report.updated += 1
                        markSynced(row, serverId: session.id, now: now)
                    }
                } else if localKey == nil {
                    let exerciseId = localExercise(for: session, exercises: &exercises, now: now)
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
        for (key, link) in links.byLocal where link.kind == kind && !seen.contains(link.serverId) && !link.serverId.hasPrefix("active-energy:") {
            let localKey = String(key.dropFirst(kind.count + 1))
            guard let row = rowsById[localKey], dayKeys.contains(row.dayKey), !dirty(row) else { continue }
            deleteLocally(row)
            report.deleted += 1
        }
    }

    /// Health's figure is one per day on both sides, whatever each side's id.
    private func applyActiveEnergy(_ session: ExerciseSessionSummary, day: Day, sentinels: inout [String: LocalExerciseEntry],
                                   exercises: inout [String: LocalExercise], now: Date, report: inout Report) {
        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        let serverId = "active-energy:\(day.key)"
        let calories = session.caloriesBurned ?? 0
        if let row = sentinels[day.key] {
            // Unsent or edited here: this device's figure goes out next push.
            guard !dirty(row) else { return }
            if abs(row.caloriesBurned - calories) > 0.0001 {
                row.caloriesBurned = calories
                report.updated += 1
                markSynced(row, serverId: serverId, now: now)
            }
        } else {
            let exerciseId = exercises.values.first { $0.name == sentinel }?.id ?? {
                let created = LocalExercise(name: sentinel, category: "Cardio")
                store.context.insert(created)
                exercises[created.id] = created
                return created.id
            }()
            let row = LocalExerciseEntry(entryDate: day.date, exerciseId: exerciseId, name: sentinel,
                                         durationMinutes: 0, caloriesBurned: calories)
            store.context.insert(row)
            markSynced(row, serverId: serverId, now: now)
            sentinels[day.key] = row
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

    /// The local exercise for a server session's exercise: through the links
    /// (one this device created and pushed), then one already under the
    /// server's id, then a new one.
    private func localExercise(for session: ExerciseSessionSummary, exercises: inout [String: LocalExercise], now: Date) -> String {
        let exercise = session.asExercise
        let serverId = session.exerciseId ?? exercise.id
        if let key = links.localKey(LocalExercise.syncKind, server: serverId), exercises[key] != nil {
            return key
        }
        if let existing = exercises[serverId] {
            if link(for: existing) == nil { markSynced(existing, serverId: serverId, now: now) }
            return existing.id
        }
        let created = LocalExercise(id: serverId, name: exercise.name, category: exercise.category,
                                    modality: session.effectiveModality.rawValue)
        store.context.insert(created)
        exercises[created.id] = created
        markSynced(created, serverId: serverId, now: now)
        return created.id
    }

    // MARK: Water

    private func applyWater(_ days: [Day], dayKeys: Set<String>, now: Date, report: inout Report) {
        let kind = LocalWaterEntry.syncKind
        var rowsById: [String: LocalWaterEntry] = [:]
        for row in store.all(LocalWaterEntry.self) { rowsById[row.id] = row }
        var seen: Set<String> = []

        for day in days {
            for drink in day.water {
                seen.insert(drink.id)
                let localKey = links.localKey(kind, server: drink.id)
                if isTombstoned(kind, localKey) { continue }
                if let localKey, let row = rowsById[localKey] {
                    guard !dirty(row) else { continue }
                    if abs(row.waterMl - drink.waterMl) > 0.0001 || row.dayKey != day.key {
                        row.waterMl = drink.waterMl
                        row.dayKey = day.key
                        report.updated += 1
                        markSynced(row, serverId: drink.id, now: now)
                    }
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
        for (key, link) in links.byLocal where link.kind == kind && !seen.contains(link.serverId) {
            let localKey = String(key.dropFirst(kind.count + 1))
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
        let kind = LocalCheckIn.syncKind
        var byDay: [String: LocalCheckIn] = [:]
        for row in store.all(LocalCheckIn.self) { byDay[row.dayKey] = row }
        var seenDays: Set<String> = []

        for dated in rows {
            let key = String(dated.entryDate.prefix(10))
            seenDays.insert(key)
            let values = dated.measurements
            let serverId = values.id ?? key
            if isTombstoned(kind, links.localKey(kind, server: serverId)) { continue }
            if let row = byDay[key] {
                // Unlinked means logged here and not yet sent: newer.
                guard link(for: row) != nil, !dirty(row) else { continue }
                if LocalAPIClient.measurements(row) != Self.withId(values, row.id) {
                    Self.fill(row, values)
                    report.updated += 1
                    markSynced(row, serverId: serverId, now: now)
                }
            } else {
                let row = LocalCheckIn(id: serverId, dayKey: key)
                Self.fill(row, values)
                store.context.insert(row)
                markSynced(row, serverId: serverId, now: now)
                byDay[key] = row
                report.added += 1
            }
        }
        for row in byDay.values where dayKeys.contains(row.dayKey) && !seenDays.contains(row.dayKey) {
            guard link(for: row) != nil, !dirty(row) else { continue }
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
    /// means "from this day on". So only days where the *server's* goal
    /// changes are considered, and a row is written there only when it
    /// differs from what this device would already show. A goal set here and
    /// not yet sent is never overwritten, and — because only the server's
    /// own change days are looked at — never undone on the days after it.
    private func applyGoals(_ serverGoals: [String: NutritionGoals], now: Date, report: inout Report) {
        var rows: [String: LocalGoalRow] = [:]
        for row in store.all(LocalGoalRow.self) { rows[row.dayKey] = row }

        func governing(_ key: String) -> LocalGoalRow? {
            rows.keys.filter { $0 <= key }.max().flatMap { rows[$0] }
        }

        var previous: [String: JSONValue]?
        for key in serverGoals.keys.sorted() {
            guard let server = serverGoals[key], server.isSet else { continue }
            let serverBag = LocalAPIClient.bag(from: server, dayKey: key)
            defer { previous = serverBag }
            if let previous, previous == serverBag { continue }

            if let current = governing(key) {
                // The row in force here is waiting to be sent: it wins.
                if dirty(current) && current.dayKey == key { continue }
                let localBag = LocalAPIClient.bag(from: LocalAPIClient.goals(from: current), dayKey: key)
                // An unsent goal from an earlier day doesn't block this one:
                // the server changed its goal later, from this day on.
                if localBag == serverBag { continue }
            }
            let data = (try? JSONEncoder().encode(serverBag)) ?? Data()
            if let row = rows[key] {
                row.rawJSON = data
                markSynced(row, serverId: key, now: now)
                report.updated += 1
            } else {
                let row = LocalGoalRow(dayKey: key, rawJSON: data)
                store.context.insert(row)
                markSynced(row, serverId: key, now: now)
                rows[key] = row
                report.added += 1
            }
        }
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
