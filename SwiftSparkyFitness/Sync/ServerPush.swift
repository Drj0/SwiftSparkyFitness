//
//  ServerPush.swift
//  SwiftSparkyFitness
//
//  Sends a device store's changes to a server: rows never sent, rows edited
//  since they were, and deletes of rows the server has. See
//  docs/SYNC_SWITCHING_PLAN.md, steps 3 and 5.
//
//  Safe to interrupt and safe to repeat, which is the whole design:
//
//  - Each row is linked the moment the server accepts it, so a run that dies
//    halfway resumes where it stopped.
//  - Writes that could land twice are made idempotent on the server's side:
//    food entries, foods and water carry a (source, source_id) the server
//    upserts on. Exercise entries can't — the server drops source_id on that
//    route — so an unlinked one is first matched against that day's server
//    entries, which catches the "sent, then crashed before linking" case.
//  - The link records the version that was sent, read before the request, so
//    an edit made while it was in flight goes out next time.
//  - Values are copied out of the models before every await: the user can
//    edit or delete rows while a push runs.
//
//  Stops (and rethrows) on the two failures that mean "not now": no
//  connection, and a 401. Anything else is one row the server refused; it is
//  reported and skipped, so one bad row can't block the rest forever.
//

import Foundation
import OSLog
import SwiftData

@MainActor
final class ServerPush {
    struct Plan: Equatable {
        var creates = 0
        var updates = 0
        var deletes = 0
        /// Linked rows for this account, for judging whether `deletes` is a
        /// plausible amount or a sign something went wrong locally.
        var linked = 0

        var total: Int { creates + updates + deletes }
        var isEmpty: Bool { total == 0 }

        /// The sanity valve: deleting more than a fifth of what the server
        /// has from this device is the shape of a local mistake (a wipe
        /// that didn't go through the wipe, a restored-over store), not of
        /// someone tidying their diary. The flow asks before doing it.
        var needsConfirmation: Bool { deletes > 20 && Double(deletes) > Double(max(linked, 1)) * 0.2 }
    }

    struct Failure: Equatable {
        let kind: String
        let key: String
        let message: String
    }

    struct Report: Equatable {
        var sent = 0
        var deleted = 0
        var failures: [Failure] = []
    }

    let store: LocalStore
    let server: SyncServer
    let account: String

    private var report = Report()
    private var serverMeals: [MealType]?
    private var mealIds: [String: String] = [:]
    private var foodRefs: [String: (food: String, variant: String)] = [:]
    private var exerciseIds: [String: String] = [:]
    private var serverDays: [String: DailySummary] = [:]
    private var onProgress: ((Int) -> Void)?

    private static let logger = Logger(subsystem: "drj.SwiftSparkyFitness", category: "ServerPush")

    init(store: LocalStore, server: SyncServer, account: String) {
        self.store = store
        self.server = server
        self.account = account
    }

    // MARK: - Plan

    func plan() -> Plan {
        var plan = Plan()
        func count<Row: SyncTracked>(_ rows: [Row], include: (Row) -> Bool = { _ in true }) {
            for row in rows where include(row) && store.needsPush(row, account: account) {
                if store.link(for: row, account: account) == nil { plan.creates += 1 } else { plan.updates += 1 }
            }
        }
        count(store.all(LocalMealType.self), include: Self.shouldPush)
        count(store.all(LocalFoodEntry.self))
        count(store.all(LocalExerciseEntry.self))
        count(store.all(LocalWaterEntry.self), include: Self.shouldPush)
        count(store.all(LocalCheckIn.self), include: Self.shouldPush)
        count(store.all(LocalGoalRow.self), include: Self.shouldPush)
        count(store.all(LocalPreferences.self), include: Self.shouldPush)
        plan.deletes = Set(store.all(LocalTombstone.self).filter {
            Self.deletableKinds.contains($0.kind) && store.link(kind: $0.kind, localKey: $0.localKey, account: account) != nil
        }.map { "\($0.kind)|\($0.localKey)" }).count
        plan.linked = store.all(LocalSyncLink.self).filter { $0.serverAccount == account }.count
        return plan
    }

    /// Seeded rows nobody has touched carry no information — the server has
    /// its own — so they are matched (meal types) or left alone
    /// (preferences), never sent over the server's real values.
    private static func shouldPush(_ meal: LocalMealType) -> Bool { !meal.isSystemDefault || meal.updatedAt > .distantPast }
    private static func shouldPush(_ prefs: LocalPreferences) -> Bool { prefs.updatedAt > .distantPast }
    /// Water derived from food entries is recomputed by the server from the
    /// food itself; sending it too would count it twice.
    private static func shouldPush(_ water: LocalWaterEntry) -> Bool { water.source != "food" }
    /// The server's check-in upsert has nothing to write for an empty day.
    private static func shouldPush(_ checkIn: LocalCheckIn) -> Bool {
        LocalDay.date(checkIn.dayKey) != nil
            && BodyField.allCases.contains { LocalAPIClient.measurements(checkIn).value(for: $0) != nil }
    }
    private static func shouldPush(_ goal: LocalGoalRow) -> Bool { LocalDay.date(goal.dayKey) != nil }

    // MARK: - Run

    /// Sends everything `plan()` counted. `progress` receives the number of
    /// rows handled so far.
    func run(progress: ((Int) -> Void)? = nil) async throws -> Report {
        report = Report()
        onProgress = progress
        try await pushMealTypes()
        try await pushFoodEntries()
        try await pushExerciseEntries()
        try await pushWater()
        try await pushCheckIns()
        try await pushGoals()
        try await pushPreferences()
        try await pushDeletes()
        return report
    }

    /// Runs one row's work. Connectivity and auth failures abort the run;
    /// anything else is recorded against the row and the run carries on.
    /// `counts` is false for work that only links rows the server already
    /// has — so "sent" matches the plan the user was shown.
    private func attempt(_ kind: String, _ key: String, counts: Bool = true, _ body: () async throws -> Void) async throws {
        do {
            try await body()
            if counts { report.sent += 1 }
        } catch {
            if error.isTransientFailure || error.isUnauthorized || error is LocalSaveFailure { throw error }
            Self.logger.error("Push of \(kind, privacy: .public) \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            report.failures.append(Failure(kind: kind, key: key, message: error.localizedDescription))
        }
        onProgress?(report.sent + report.deleted + report.failures.count)
    }

    struct LocalSaveFailure: LocalizedError {
        let underlying: Error?
        var errorDescription: String? { "Couldn't record the sync on this iPhone. \(underlying?.localizedDescription ?? "")" }
    }

    /// Links a sent row at the version that was sent. If the row was deleted
    /// while the request was in flight it had no link to tombstone, so the
    /// link and a tombstone are written here: the next push deletes the copy
    /// the server just made.
    private func record(kind: String, key: String, serverId: String, version: Date, stillExists: Bool, serverVariantId: String? = nil) throws {
        store.setLink(kind: kind, localKey: key, serverId: serverId, account: account, serverVariantId: serverVariantId, version: version)
        // A linked row deleted mid-request was already tombstoned by save().
        if !stillExists, store.fetch(LocalTombstone.self, where: #Predicate { $0.kind == kind && $0.localKey == key }).isEmpty {
            store.insert(LocalTombstone(kind: kind, localKey: key))
        }
        if let error = store.lastSaveError { throw LocalSaveFailure(underlying: error) }
    }

    private func day(_ dayKey: String, fallback: Date) -> Date { LocalDay.date(dayKey) ?? fallback }

    // MARK: - Meal types

    private func serverMealTypes() async throws -> [MealType] {
        if let serverMeals { return serverMeals }
        let fetched = try await server.mealTypes()
        serverMeals = fetched
        return fetched
    }

    private func pushMealTypes() async throws {
        struct Snapshot { let id, name: String; let sortOrder: Int; let isVisible, isSystem: Bool; let version: Date; let linkId: String?; let dirty, push: Bool }
        let meals = store.all(LocalMealType.self).map {
            Snapshot(id: $0.id, name: $0.name, sortOrder: $0.sortOrder, isVisible: $0.isVisible, isSystem: $0.isSystemDefault,
                     version: $0.updatedAt, linkId: store.link(for: $0, account: account)?.serverId,
                     dirty: store.needsPush($0, account: account), push: Self.shouldPush($0))
        }
        for meal in meals {
            if let linkId = meal.linkId {
                mealIds[meal.id] = linkId
                guard meal.dirty, meal.push else { continue }
                try await attempt(LocalMealType.syncKind, meal.id) {
                    // The server refuses renaming or reordering its own four.
                    let input = meal.isSystem
                        ? MealTypeInput(isVisible: meal.isVisible)
                        : MealTypeInput(name: meal.name, sortOrder: meal.sortOrder, isVisible: meal.isVisible)
                    _ = try await server.updateMealType(id: linkId, input)
                    try record(kind: LocalMealType.syncKind, key: meal.id, serverId: linkId, version: meal.version, stillExists: true)
                }
                continue
            }
            // Unlinked: the same name on the server is the same category —
            // the four defaults always, and a custom one made on both sides.
            let match = try await serverMealTypes().first { $0.name.caseInsensitiveCompare(meal.name) == .orderedSame }
            if let match {
                mealIds[meal.id] = match.id
                try await attempt(LocalMealType.syncKind, meal.id, counts: meal.push && match.isVisible != meal.isVisible) {
                    if meal.push, match.isVisible != meal.isVisible {
                        _ = try await server.updateMealType(id: match.id, MealTypeInput(isVisible: meal.isVisible))
                    }
                    try record(kind: LocalMealType.syncKind, key: meal.id, serverId: match.id, version: meal.version, stillExists: true)
                }
            } else if meal.push {
                try await attempt(LocalMealType.syncKind, meal.id) {
                    let created = try await server.createMealType(name: meal.name, sortOrder: meal.sortOrder)
                    serverMeals?.append(created)
                    mealIds[meal.id] = created.id
                    if !meal.isVisible { _ = try await server.updateMealType(id: created.id, MealTypeInput(isVisible: false)) }
                    try record(kind: LocalMealType.syncKind, key: meal.id, serverId: created.id, version: meal.version, stillExists: true)
                }
            }
        }
    }

    /// The server id for an entry's meal. Falls back to the name, for an
    /// entry whose category was deleted here but still exists there.
    private func serverMealId(localId: String, name: String) async throws -> String {
        if let id = mealIds[localId] { return id }
        if let match = try await serverMealTypes().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match.id
        }
        throw APIError.server(message: "The meal category “\(name)” doesn't exist on the server.", code: nil)
    }

    // MARK: - Foods and food entries

    private struct FoodEntrySnapshot {
        let id, dayKey, foodId, foodName, mealTypeId, mealTypeName, unit, servingUnit: String
        let brandName: String?
        let entryDate: Date
        let quantity, servingSize, calories, protein, carbs, fat: Double
        let version: Date
        let linkId: String?
    }

    private func pushFoodEntries() async throws {
        let entries = store.all(LocalFoodEntry.self)
            .filter { store.needsPush($0, account: account) }
            .map {
                FoodEntrySnapshot(id: $0.id, dayKey: $0.dayKey, foodId: $0.foodId, foodName: $0.foodName,
                                  mealTypeId: $0.mealTypeId, mealTypeName: $0.mealTypeName, unit: $0.unit,
                                  servingUnit: $0.servingUnit, brandName: $0.brandName, entryDate: $0.entryDate,
                                  quantity: $0.quantity, servingSize: $0.servingSize, calories: $0.calories,
                                  protein: $0.protein, carbs: $0.carbs, fat: $0.fat, version: $0.updatedAt,
                                  linkId: store.link(for: $0, account: account)?.serverId)
            }
        for entry in entries {
            try await attempt(LocalFoodEntry.syncKind, entry.id) {
                let ref = try await serverFood(for: entry)
                let input = try await foodEntryInput(entry, ref: ref)
                var serverId: String
                if let linkId = entry.linkId {
                    serverId = linkId
                    do {
                        try await server.updateFoodEntry(id: linkId, input)
                    } catch where error.isNotFound {
                        // Deleted on the server while edited here: the edit
                        // is the newer intent, so the entry comes back.
                        serverId = try await server.createFoodEntry(input)
                    }
                } else {
                    serverId = try await server.createFoodEntry(input)
                }
                let entryId = entry.id
                let exists = !store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == entryId }).isEmpty
                try record(kind: LocalFoodEntry.syncKind, key: entry.id, serverId: serverId, version: entry.version, stillExists: exists)
            }
        }
    }

    /// The server food an entry is logged against, creating it on first use.
    /// Created with the local food's id as its provider id, so asking twice
    /// returns the same server food.
    private func serverFood(for entry: FoodEntrySnapshot) async throws -> (food: String, variant: String) {
        if let cached = foodRefs[entry.foodId] { return cached }
        if let link = store.link(kind: LocalFood.syncKind, localKey: entry.foodId, account: account), let variant = link.serverVariantId {
            foodRefs[entry.foodId] = (link.serverId, variant)
            return (link.serverId, variant)
        }
        let foodId = entry.foodId
        let local = store.fetch(LocalFood.self, where: #Predicate { $0.id == foodId }).first
        // Without the food row (deleted since), the entry itself describes
        // one serving of what was logged.
        let perServing = entry.quantity > 0 ? entry.servingSize / entry.quantity : 1
        let input = CustomFoodInput(
            name: local?.name ?? entry.foodName,
            brand: local?.brand ?? entry.brandName,
            servingSize: local?.servingSize ?? entry.servingSize,
            servingUnit: local?.servingUnit ?? entry.servingUnit,
            calories: local?.calories ?? entry.calories * perServing,
            protein: local?.protein ?? entry.protein * perServing,
            carbs: local?.carbs ?? entry.carbs * perServing,
            fat: local?.fat ?? entry.fat * perServing,
            providerExternalId: entry.foodId,
            providerType: SyncServerSource.tag
        )
        let food = try await server.createCustomFood(input)
        guard let variant = food.defaultVariant?.id else { throw APIError.invalidResponse }
        foodRefs[entry.foodId] = (food.id, variant)
        store.setLink(kind: LocalFood.syncKind, localKey: entry.foodId, serverId: food.id, account: account,
                      serverVariantId: variant, version: local?.updatedAt ?? Date())
        if let error = store.lastSaveError { throw LocalSaveFailure(underlying: error) }
        return (food.id, variant)
    }

    /// Local rows hold nutrition already scaled for the quantity; the request
    /// is built from a per-serving variant and `APIClient` scales it back up,
    /// so the server ends up with exactly the numbers this device shows —
    /// the same body every entry logged in server mode is sent with.
    private func foodEntryInput(_ entry: FoodEntrySnapshot, ref: (food: String, variant: String)) async throws -> FoodEntryInput {
        // A zero serving size would make APIClient fall back to scale 1 and
        // send no calories; one serving of exactly what was logged is the
        // same totals.
        let serving = entry.servingSize > 0 ? entry.servingSize : max(entry.quantity, 1)
        let perServing = entry.quantity > 0 ? serving / entry.quantity : 0
        let food = Food(
            id: ref.food, name: entry.foodName, brand: entry.brandName,
            defaultVariant: FoodVariant(
                id: ref.variant, servingSize: serving, servingUnit: entry.unit,
                calories: entry.calories * perServing, protein: entry.protein * perServing,
                carbs: entry.carbs * perServing, fat: entry.fat * perServing
            )
        )
        return FoodEntryInput(
            food: food,
            mealTypeId: try await serverMealId(localId: entry.mealTypeId, name: entry.mealTypeName),
            quantity: entry.quantity,
            entryDate: day(entry.dayKey, fallback: entry.entryDate),
            source: SyncServerSource.tag,
            sourceId: entry.id
        )
    }

    // MARK: - Exercise

    private struct ExerciseEntrySnapshot {
        let id, dayKey, exerciseId, name: String
        let entryDate: Date
        let durationMinutes, caloriesBurned: Double
        let modality, notes, entryTime, setsJSON: String?
        let distance: Double?
        let avgHeartRate: Int?
        let version: Date
        let linkId: String?
    }

    private func pushExerciseEntries() async throws {
        let entries = store.all(LocalExerciseEntry.self)
            .filter { store.needsPush($0, account: account) }
            .map {
                ExerciseEntrySnapshot(id: $0.id, dayKey: $0.dayKey, exerciseId: $0.exerciseId, name: $0.name,
                                      entryDate: $0.entryDate, durationMinutes: $0.durationMinutes,
                                      caloriesBurned: $0.caloriesBurned, modality: $0.modality, notes: $0.notes,
                                      entryTime: $0.entryTime, setsJSON: $0.setsJSON, distance: $0.distance,
                                      avgHeartRate: $0.avgHeartRate, version: $0.updatedAt,
                                      linkId: store.link(for: $0, account: account)?.serverId)
            }
        let linkedServerIds = Set(store.links(kind: LocalExerciseEntry.syncKind, account: account).map(\.serverId))
        var claimed = linkedServerIds

        for entry in entries {
            try await attempt(LocalExerciseEntry.syncKind, entry.id) {
                let entryId = entry.id
                let date = day(entry.dayKey, fallback: entry.entryDate)
                // Health's daily active energy is one upserted figure per
                // day on the server, not an entry this device owns.
                if entry.name == ExerciseSessionSummary.healthActiveEnergyName {
                    try await server.syncActiveEnergy(kilocalories: entry.caloriesBurned, date: date)
                    let exists = !store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.id == entryId }).isEmpty
                    try record(kind: LocalExerciseEntry.syncKind, key: entry.id, serverId: "active-energy:\(entry.dayKey)",
                               version: entry.version, stillExists: exists)
                    return
                }
                let exerciseId = try await serverExercise(for: entry)
                let input = ExerciseEntryInput(
                    exerciseId: exerciseId,
                    modality: ExerciseModality(rawValue: entry.modality ?? "") ?? .duration,
                    entryDate: date,
                    entryTime: entry.entryTime.map { String($0.prefix(5)) },
                    durationMinutes: entry.durationMinutes,
                    caloriesBurned: entry.caloriesBurned,
                    distance: entry.distance,
                    avgHeartRate: entry.avgHeartRate,
                    notes: entry.notes,
                    sets: Self.sets(entry.setsJSON)
                )
                var serverId: String
                if let linkId = entry.linkId {
                    serverId = linkId
                    do {
                        serverId = try await server.updateExerciseEntry(id: linkId, input).id
                    } catch where error.isNotFound {
                        serverId = try await server.createExerciseEntry(input).id
                    }
                } else if let match = try await unclaimedServerSession(matching: entry, exerciseId: exerciseId, date: date, claimed: claimed) {
                    // Sent by a run that died before it could link it.
                    serverId = match
                } else {
                    serverId = try await server.createExerciseEntry(input).id
                }
                claimed.insert(serverId)
                let exists = !store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.id == entryId }).isEmpty
                try record(kind: LocalExerciseEntry.syncKind, key: entry.id, serverId: serverId, version: entry.version, stillExists: exists)
            }
        }
    }

    private static func sets(_ json: String?) -> [ExerciseSetInput] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ExerciseSetInput].self, from: data)) ?? []
    }

    /// A server session on the same day, same exercise, same numbers, that no
    /// other local row is linked to.
    private func unclaimedServerSession(matching entry: ExerciseEntrySnapshot, exerciseId: String, date: Date, claimed: Set<String>) async throws -> String? {
        let summary: DailySummary
        if let cached = serverDays[entry.dayKey] {
            summary = cached
        } else {
            summary = try await server.dailySummary(date: date)
            serverDays[entry.dayKey] = summary
        }
        return summary.exerciseSessions.userLogged.first { session in
            !claimed.contains(session.id)
                && session.exerciseId == exerciseId
                && abs((session.durationMinutes ?? 0) - entry.durationMinutes) < 0.01
                && abs((session.caloriesBurned ?? 0) - entry.caloriesBurned) < 0.5
                && (entry.entryTime == nil || session.entryTime?.prefix(5) == entry.entryTime?.prefix(5))
        }?.id
    }

    /// The server exercise for a local one: the user's own library entry of
    /// the same name if there is one, otherwise a new custom exercise.
    private func serverExercise(for entry: ExerciseEntrySnapshot) async throws -> String {
        if let cached = exerciseIds[entry.exerciseId] { return cached }
        if let link = store.link(kind: LocalExercise.syncKind, localKey: entry.exerciseId, account: account) {
            exerciseIds[entry.exerciseId] = link.serverId
            return link.serverId
        }
        let exerciseId = entry.exerciseId
        let local = store.fetch(LocalExercise.self, where: #Predicate { $0.id == exerciseId }).first
        let name = local?.name ?? entry.name
        let key = ExerciseCatalog.normalized(name)
        let serverId: String
        if let match = try await server.searchExercises(query: name).first(where: { ExerciseCatalog.normalized($0.name) == key }) {
            serverId = match.id
        } else {
            serverId = try await server.createCustomExercise(CustomExerciseInput(
                name: name,
                category: local?.category ?? "Other",
                modality: ExerciseModality(rawValue: local?.modality ?? entry.modality ?? "") ?? .duration
            )).id
        }
        exerciseIds[entry.exerciseId] = serverId
        store.setLink(kind: LocalExercise.syncKind, localKey: entry.exerciseId, serverId: serverId, account: account,
                      version: local?.updatedAt ?? Date())
        if let error = store.lastSaveError { throw LocalSaveFailure(underlying: error) }
        return serverId
    }

    // MARK: - Water

    private func pushWater() async throws {
        struct Snapshot { let id, dayKey: String; let ml: Double; let loggedAt, version: Date }
        let drinks = store.all(LocalWaterEntry.self)
            .filter { Self.shouldPush($0) && store.needsPush($0, account: account) }
            .map { Snapshot(id: $0.id, dayKey: $0.dayKey, ml: $0.waterMl, loggedAt: $0.loggedAt, version: $0.updatedAt) }
        for drink in drinks {
            try await attempt(LocalWaterEntry.syncKind, drink.id) {
                // An upsert on the drink's own id: resending is harmless.
                let serverId = try await server.pushWater(milliliters: drink.ml, date: day(drink.dayKey, fallback: drink.loggedAt), sourceId: drink.id)
                let drinkId = drink.id
                let exists = !store.fetch(LocalWaterEntry.self, where: #Predicate { $0.id == drinkId }).isEmpty
                try record(kind: LocalWaterEntry.syncKind, key: drink.id, serverId: serverId, version: drink.version, stillExists: exists)
            }
        }
    }

    // MARK: - Body, goals, preferences

    private func pushCheckIns() async throws {
        struct Snapshot { let id, dayKey: String; let values: [BodyField: Double?]; let version: Date }
        let checkIns = store.all(LocalCheckIn.self)
            .filter { Self.shouldPush($0) && store.needsPush($0, account: account) }
            .map { row -> Snapshot in
                let measurements = LocalAPIClient.measurements(row)
                var values: [BodyField: Double?] = [:]
                // Every field, nil included: the upsert clears what's absent
                // here, so the server's day ends up identical to this one.
                for field in BodyField.allCases { values[field] = .some(measurements.value(for: field)) }
                return Snapshot(id: row.id, dayKey: row.dayKey, values: values, version: row.updatedAt)
            }
        for checkIn in checkIns {
            guard checkIn.values.values.contains(where: { $0 != nil }), let date = LocalDay.date(checkIn.dayKey) else { continue }
            try await attempt(LocalCheckIn.syncKind, checkIn.id) {
                let saved = try await server.upsertBodyMeasurements(BodyMeasurementsInput(date: date, values: checkIn.values))
                let checkInId = checkIn.id
                let exists = !store.fetch(LocalCheckIn.self, where: #Predicate { $0.id == checkInId }).isEmpty
                try record(kind: LocalCheckIn.syncKind, key: checkIn.id, serverId: saved.id ?? checkIn.dayKey,
                           version: checkIn.version, stillExists: exists)
            }
        }
    }

    private func pushGoals() async throws {
        struct Snapshot { let dayKey: String; let goals: NutritionGoals; let version: Date }
        let rows = store.all(LocalGoalRow.self, sortBy: [SortDescriptor(\.dayKey)])
            .filter { Self.shouldPush($0) && store.needsPush($0, account: account) }
            .map { Snapshot(dayKey: $0.dayKey, goals: LocalAPIClient.goals(from: $0), version: $0.updatedAt) }
        for row in rows {
            guard let date = LocalDay.date(row.dayKey) else { continue }
            try await attempt(LocalGoalRow.syncKind, row.dayKey) {
                // One date only — `saveGoals` never sends the server's
                // cascade flag, which would overwrite six months of goals.
                try await server.saveGoals(row.goals, startingOn: date)
                try record(kind: LocalGoalRow.syncKind, key: row.dayKey, serverId: row.dayKey, version: row.version, stillExists: true)
            }
        }
    }

    private func pushPreferences() async throws {
        guard let prefs = store.all(LocalPreferences.self).first,
              Self.shouldPush(prefs), store.needsPush(prefs, account: account) else { return }
        let key = prefs.id
        let version = prefs.updatedAt
        try await attempt(LocalPreferences.syncKind, key) {
            let values = try await LocalAPIClient(store: store).userPreferences()
            for setting in UserPreferences.Setting.allCases {
                _ = try await server.updateUserPreference(setting, to: values.value(for: setting))
            }
            try record(kind: LocalPreferences.syncKind, key: key, serverId: key, version: version, stillExists: true)
        }
    }

    // MARK: - Deletes

    /// Kinds the server can delete. The app can't delete foods, exercises,
    /// goals or preferences locally either, so those tombstones only ever
    /// come from a row being replaced; they are cleared without a request.
    static let deletableKinds: Set<String> = [
        LocalFoodEntry.syncKind, LocalExerciseEntry.syncKind, LocalWaterEntry.syncKind,
        LocalCheckIn.syncKind, LocalMealType.syncKind
    ]

    private func pushDeletes() async throws {
        // Values only, deduplicated: the models themselves may be deleted —
        // by this loop, or by a CloudKit merge from another device — while a
        // request is in flight, so each is fetched again afterwards.
        struct Pending: Hashable { let kind, key, serverId: String }
        var seen: Set<Pending> = []
        let pending: [Pending] = store.all(LocalTombstone.self).compactMap { tombstone in
            guard let link = store.link(kind: tombstone.kind, localKey: tombstone.localKey, account: account) else { return nil }
            let item = Pending(kind: tombstone.kind, key: tombstone.localKey, serverId: link.serverId)
            return seen.insert(item).inserted ? item : nil
        }
        for item in pending {
            if Self.deletableKinds.contains(item.kind) {
                do {
                    try await deleteOnServer(kind: item.kind, serverId: item.serverId)
                    report.deleted += 1
                } catch {
                    if error.isTransientFailure || error.isUnauthorized { throw error }
                    if !error.isNotFound {
                        // Refused (a meal category still in use, say).
                        // Retrying every sync would only fail again; the
                        // server keeps it.
                        report.failures.append(Failure(kind: item.kind, key: item.key, message: error.localizedDescription))
                    }
                }
            }
            let kind = item.kind
            let key = item.key
            let account = self.account
            // Every link for this account — CloudKit can hold duplicates —
            // and the tombstone once no account still needs it.
            for link in store.fetch(LocalSyncLink.self, where: #Predicate { $0.kind == kind && $0.localKey == key && $0.serverAccount == account }) {
                store.context.delete(link)
            }
            let otherAccounts = store.fetch(LocalSyncLink.self, where: #Predicate { $0.kind == kind && $0.localKey == key && $0.serverAccount != account })
            if otherAccounts.isEmpty {
                for tombstone in store.fetch(LocalTombstone.self, where: #Predicate { $0.kind == kind && $0.localKey == key }) {
                    store.context.delete(tombstone)
                }
            }
            guard store.save() else { throw LocalSaveFailure(underlying: store.lastSaveError) }
            onProgress?(report.sent + report.deleted + report.failures.count)
        }
    }

    private func deleteOnServer(kind: String, serverId: String) async throws {
        switch kind {
        case LocalFoodEntry.syncKind: try await server.deleteFoodEntry(id: serverId)
        case LocalExerciseEntry.syncKind:
            // Health's daily figure isn't a deletable entry.
            guard !serverId.hasPrefix("active-energy:") else { return }
            try await server.deleteExerciseEntry(id: serverId)
        case LocalWaterEntry.syncKind: try await server.deleteWaterLogEntry(id: serverId)
        case LocalCheckIn.syncKind: try await server.deleteBodyMeasurements(id: serverId)
        case LocalMealType.syncKind: try await server.deleteMealType(id: serverId)
        // Foods, exercises, goals and preferences have no delete here: the
        // app can't delete them locally either.
        default: return
        }
    }
}
