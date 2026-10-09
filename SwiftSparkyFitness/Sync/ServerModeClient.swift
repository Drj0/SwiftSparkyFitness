//
//  ServerModeClient.swift
//  SwiftSparkyFitness
//
//  What every screen talks to in server mode. See docs/SYNC_SWITCHING_PLAN.md,
//  step 5.
//
//  The diary — anything the user logs, edits or reads back — is read from
//  and written to this device's copy (`ServerSync.store`), so it works the
//  same with or without the server, and `ServerSync` carries the changes
//  across. Only three kinds of call go to the server directly:
//
//  - Signing in and out, which can't happen offline.
//  - Searching: the server's food and exercise libraries and its providers
//    are far bigger than anything cached here. Out of range, search falls
//    back to what this device has.
//  - Water containers, whose integer ids the server assigns. They're
//    mirrored here for reading offline; changing them needs the server.
//
//  One object for the whole session, not one per mode: every view model
//  captures its client when it's created, so the choice between device and
//  server has to be made per call, inside it.
//

import Foundation
import SwiftData

@MainActor
final class ServerModeClient: APIClientProtocol {
    static let shared = ServerModeClient()

    private let remote: APIClient
    let sync: ServerSync

    init(remote: APIClient = .shared, sync: ServerSync = .shared) {
        self.remote = remote
        self.sync = sync
    }

    private var local: LocalAPIClient { LocalAPIClient(store: sync.store) }
    private var store: LocalStore { sync.store }

    /// Exercises seen in server search results, so logging one creates a
    /// complete local row for it rather than a nameless placeholder.
    private var knownExercises: [String: Exercise] = [:]

    /// Writes land here first; the sync that follows sends them.
    private func wrote<T>(_ value: T) -> T {
        sync.localChange()
        return value
    }

    /// The server when it answers, this device's own copy when it can't.
    /// Known to be out of range, it doesn't wait for the server to time out
    /// again; the sync's own retries notice when it's back.
    private func remoteFirst<T>(_ call: () async throws -> T, fallback: () async throws -> T) async throws -> T {
        guard sync.isReachable else { return try await fallback() }
        do {
            return try await call()
        } catch where error.isTransientFailure || ServerSync.isNotTheServer(error) {
            return try await fallback()
        }
    }

    // MARK: - Session

    func signIn(email: String, password: String) async throws -> SessionUser {
        let epoch = AppMode.changeCount
        let user = try await remote.signIn(email: email, password: password)
        signedIn(user, epoch: epoch)
        return user
    }

    /// Out of range, the last user who signed in to *this* server is still
    /// signed in: their diary opens from this device instead of a
    /// "can't reach the server" screen. A server that answers "no session"
    /// is believed, and clears it.
    func currentSession() async throws -> SessionUser? {
        let serverURL = ServerConfig.urlString
        let remote = self.remote
        let epoch = AppMode.changeCount
        // With a saved session, a server that accepts the connection and
        // then hangs mustn't hold the launch for the whole request timeout:
        // after a moment the diary opens from this device, and the check
        // finishes on its own — signing out then if the session was gone.
        if let cached = SessionCache.user(forServer: serverURL) {
            let check = Task { try await remote.currentSession() }
            guard let early = await Self.result(of: check, within: .seconds(3)) else {
                activateSync(cached, serverURL: serverURL, epoch: epoch)
                Task { await self.finishSessionCheck(check, epoch: epoch) }
                return cached
            }
            return try resolveSession(early, cached: cached, serverURL: serverURL, epoch: epoch)
        }
        do {
            guard let user = try await remote.currentSession() else {
                SessionCache.clear()
                sync.deactivate(removingCopy: false)
                return nil
            }
            signedIn(user, epoch: epoch)
            return user
        } catch where error.isTransientFailure || error is DecodingError {
            // A body that isn't a session at all — a hotel Wi-Fi login page
            // answering in the server's place — says nothing about the
            // session either; it's being out of range by another name.
            guard let cached = SessionCache.user(forServer: serverURL) else { throw error }
            activateSync(cached, serverURL: serverURL, epoch: epoch)
            return cached
        }
    }

    private func resolveSession(_ result: Result<SessionUser?, Error>, cached: SessionUser, serverURL: String, epoch: Int) throws -> SessionUser? {
        switch result {
        case .success(let user?):
            signedIn(user, epoch: epoch)
            return user
        case .success(nil):
            SessionCache.clear()
            sync.deactivate(removingCopy: false)
            return nil
        case .failure:
            // APIClient turns a definite "signed out" into nil; any error
            // left is the server not answering properly, not a sign-out.
            activateSync(cached, serverURL: serverURL, epoch: epoch)
            return cached
        }
    }

    /// The rest of a session check the launch stopped waiting for.
    private func finishSessionCheck(_ check: Task<SessionUser?, Error>, epoch: Int) async {
        switch await check.result {
        case .success(let user?):
            signedIn(user, epoch: epoch)
        case .success(nil):
            // The server answered after all: this session is over. The copy
            // stays; signing in again returns to it.
            SessionCache.clear()
            // Only to a user still in the server mode this check began in.
            guard AppMode.changeCount == epoch else { return }
            NotificationCenter.default.post(name: .sessionExpired, object: nil)
        case .failure:
            break // still out of range: carry on from this device
        }
    }

    /// `task`'s result if it finishes within `limit`, else nil — without
    /// cancelling it or waiting for it.
    private static func result(of task: Task<SessionUser?, Error>, within limit: Duration) async -> Result<SessionUser?, Error>? {
        let box = FirstResult()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            Task { box.finish(await task.result) }
            Task { try? await Task.sleep(for: limit); box.finish(nil) }
        }
    }

    /// Resumes once, with whichever of the result and the deadline is first.
    private final class FirstResult: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<SessionUser?, Error>?, Never>?
        private var done = false

        func install(_ continuation: CheckedContinuation<Result<SessionUser?, Error>?, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ value: Result<SessionUser?, Error>?) {
            lock.lock()
            guard !done, let continuation else { lock.unlock(); return }
            done = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        }
    }

    private func signedIn(_ user: SessionUser, epoch: Int) {
        SessionCache.save(user, serverURL: ServerConfig.urlString)
        activateSync(user, serverURL: ServerConfig.urlString, epoch: epoch)
    }

    /// Starts syncing only if the app is still in the mode the check or
    /// sign-in began in. One the user walked away from — Back to the start
    /// screen mid-connect, then on to this iPhone — can still finish, and
    /// used to start server sync behind local mode. The session is still
    /// cached either way, so choosing the server again picks it up.
    private func activateSync(_ user: SessionUser, serverURL: String, epoch: Int) {
        guard AppMode.changeCount == epoch else { return }
        sync.activate(user: user, serverURL: serverURL)
    }

    /// The copy is deleted with the session — after Settings has warned
    /// about anything in it the server doesn't have yet.
    func signOut() async {
        // One last try at sending what's waiting, briefly, while the session
        // still works.
        await sync.syncNow(timeout: .seconds(5))
        await remote.signOut()
        SessionCache.clear()
        sync.deactivate(removingCopy: true)
    }

    func requestPasswordReset(email: String) async throws {
        try await remote.requestPasswordReset(email: email)
    }

    // MARK: - The day

    /// Refreshes the day from the server first when it can (briefly — see
    /// `ServerSync.refresh`), then reads this device's copy.
    func dailySummary(date: Date) async throws -> DailySummary {
        await sync.refresh(day: date)
        return try await local.dailySummary(date: date)
    }

    // MARK: - Meal types

    func mealTypes() async throws -> [MealType] { try await local.mealTypes() }
    func createMealType(name: String, sortOrder: Int) async throws -> MealType {
        wrote(try await local.createMealType(name: name, sortOrder: sortOrder))
    }
    func updateMealType(id: String, _ input: MealTypeInput) async throws -> MealType {
        wrote(try await local.updateMealType(id: id, input))
    }
    func deleteMealType(id: String) async throws {
        wrote(try await local.deleteMealType(id: id))
    }

    // MARK: - Food

    func searchFoods(query: String) async throws -> [Food] {
        try await remoteFirst({ try await remote.searchFoods(query: query) }, fallback: { try await local.searchFoods(query: query) })
    }
    func foodSuggestions() async throws -> FoodSuggestions {
        try await remoteFirst({ try await remote.foodSuggestions() }, fallback: { try await local.foodSuggestions() })
    }
    /// The on-device diary, which in this mode holds everything logged here
    /// and what the last pull brought in: no request, same as iCloud mode.
    func foodLogStats(since start: Date) async -> [String: FoodLogStat] {
        await local.foodLogStats(since: start)
    }
    /// Straight to Open Food Facts: the server isn't in this path, so a
    /// remote-then-local fallback would only send the same request twice.
    func searchExternalFoods(query: String) async throws -> [Food] {
        try await OpenFoodFactsSearch.search(query)
    }
    func searchUsdaFoods(query: String) async throws -> [Food] {
        try await remoteFirst({ try await remote.searchUsdaFoods(query: query) }, fallback: { [] })
    }
    func createCustomFood(_ input: CustomFoodInput) async throws -> Food {
        wrote(try await local.createCustomFood(input))
    }
    /// Kept here under the provider's own id; the push creates the server
    /// food, once, the first time an entry needs it.
    func materializeExternalFood(_ food: Food) async throws -> Food {
        try await local.materializeExternalFood(food)
    }

    @discardableResult
    func createFoodEntry(_ input: FoodEntryInput) async throws -> String {
        wrote(try await local.createFoodEntry(try await withLocalFood(input)))
    }
    func updateFoodEntry(id: String, _ input: FoodEntryInput) async throws {
        wrote(try await local.updateFoodEntry(id: id, try await withLocalFood(input)))
    }

    /// The same entry, pointing at the local food for its food.
    private func withLocalFood(_ input: FoodEntryInput) async throws -> FoodEntryInput {
        var input = input
        input = FoodEntryInput(food: try await ensureFood(input.food), mealTypeId: input.mealTypeId,
                               quantity: input.quantity, entryDate: input.entryDate,
                               source: input.source, sourceId: input.sourceId)
        return input
    }
    func deleteFoodEntry(id: String) async throws {
        wrote(try await local.deleteFoodEntry(id: id))
    }

    /// A food picked from the server's library already exists there: it is
    /// copied here under its server id and linked to it with its variant,
    /// so the entry's push references it instead of creating a duplicate.
    /// A provider result (OpenFoodFacts, USDA) is only kept here; the push
    /// creates its server food.
    ///
    /// Returns the food to log against: a server food this copy already
    /// knows under another id (one it created and pushed) is that local food,
    /// not a second one.
    private func ensureFood(_ food: Food) async throws -> Food {
        if !food.isExternal, let account = sync.account,
           let key = store.links(kind: LocalFood.syncKind, account: account).first(where: { $0.serverId == food.id })?.localKey,
           let row = store.fetch(LocalFood.self, where: #Predicate { $0.id == key }).first {
            return LocalAPIClient.food(row)
        }
        let id = food.id
        if store.fetch(LocalFood.self, where: #Predicate { $0.id == id }).isEmpty {
            _ = try await local.materializeExternalFood(food)
            if !food.isExternal, let account = sync.account,
               let row = store.fetch(LocalFood.self, where: #Predicate { $0.id == id }).first {
                store.setLink(row, serverId: food.id, account: account, serverVariantId: food.defaultVariant?.id)
            }
        }
        return food
    }

    // MARK: - Exercise

    func searchExercises(query: String) async throws -> [Exercise] {
        remember(try await remoteFirst({ try await remote.searchExercises(query: query) }, fallback: { try await local.searchExercises(query: query) }))
    }
    func recentExercises() async throws -> [Exercise] {
        remember(try await remoteFirst({ try await remote.recentExercises() }, fallback: { try await local.recentExercises() }))
    }
    /// The on-device diary, which mirrors the server's — no round trip.
    func exerciseHistory(since start: Date) async -> [String: ExerciseLastSession] {
        await local.exerciseHistory(since: start)
    }
    func searchExternalExercises(query: String) async throws -> [ExternalExerciseResult] {
        try await remoteFirst({ try await remote.searchExternalExercises(query: query) }, fallback: { try await local.searchExternalExercises(query: query) })
    }
    /// Created here; the push matches it to the server library by name, or
    /// creates it there.
    func materializeExternalExercise(_ result: ExternalExerciseResult) async throws -> Exercise {
        wrote(try await local.materializeExternalExercise(result))
    }
    func createCustomExercise(_ input: CustomExerciseInput) async throws -> Exercise {
        wrote(try await local.createCustomExercise(input))
    }
    func createExerciseEntry(_ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
        ensureExercise(input.exerciseId)
        return wrote(try await local.createExerciseEntry(input))
    }
    func updateExerciseEntry(id: String, _ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
        ensureExercise(input.exerciseId)
        return wrote(try await local.updateExerciseEntry(id: id, input))
    }
    func deleteExerciseEntry(id: String) async throws {
        wrote(try await local.deleteExerciseEntry(id: id))
    }

    private func remember(_ exercises: [Exercise]) -> [Exercise] {
        for exercise in exercises { knownExercises[exercise.id] = exercise }
        return exercises
    }

    /// An exercise from the server's library, copied here under its server
    /// id and linked, so logging against it offline works and the push
    /// reuses it.
    private func ensureExercise(_ id: String) {
        guard store.fetch(LocalExercise.self, where: #Predicate { $0.id == id }).isEmpty,
              let known = knownExercises[id] else { return }
        let row = LocalExercise(id: id, name: known.name, category: known.category, modality: known.modality?.rawValue)
        store.insert(row)
        if let account = sync.account { store.setLink(row, serverId: id, account: account) }
    }

    // MARK: - Preferences and goals

    func userPreferences() async throws -> UserPreferences { try await local.userPreferences() }
    func updateUserPreference(_ setting: UserPreferences.Setting, to value: String) async throws -> UserPreferences {
        wrote(try await local.updateUserPreference(setting, to: value))
    }
    func profile() async throws -> UserProfile { try await local.profile() }
    func saveProfile(_ profile: UserProfile) async throws { wrote(try await local.saveProfile(profile)) }
    func goals(date: Date) async throws -> NutritionGoals { try await local.goals(date: date) }
    func saveGoals(_ goals: NutritionGoals, startingOn date: Date) async throws {
        wrote(try await local.saveGoals(goals, startingOn: date))
    }

    // MARK: - Water

    func waterTotals(date: Date) async throws -> WaterTotals { try await local.waterTotals(date: date) }
    func waterLog(date: Date) async throws -> [WaterLogEntry] { try await local.waterLog(date: date) }
    func adjustWater(date: Date, drinks: Int) async throws -> WaterTotals {
        wrote(try await local.adjustWater(date: date, drinks: drinks))
    }
    func adjustWater(date: Date, drinks: Int, containerId: Int?) async throws -> WaterTotals {
        wrote(try await local.adjustWater(date: date, drinks: drinks, containerId: containerId))
    }
    func logWaterAmount(date: Date, milliliters: Double) async throws -> WaterTotals {
        wrote(try await local.logWaterAmount(date: date, milliliters: milliliters))
    }
    func deleteWaterLogEntry(id: String) async throws {
        wrote(try await local.deleteWaterLogEntry(id: id))
    }

    func waterContainers() async throws -> [WaterContainer] {
        do {
            let containers = try await remote.waterContainers()
            mirror(containers)
            return containers
        } catch where error.isTransientFailure {
            return try await local.waterContainers()
        }
    }
    func createWaterContainer(_ input: WaterContainerInput) async throws -> WaterContainer {
        let created = try await needsServer { try await remote.createWaterContainer(input) }
        _ = try? await waterContainers()
        return created
    }
    func setPrimaryWaterContainer(id: Int) async throws {
        try await needsServer { try await remote.setPrimaryWaterContainer(id: id) }
        _ = try? await waterContainers()
    }
    func deleteWaterContainer(id: Int) async throws {
        try await needsServer { try await remote.deleteWaterContainer(id: id) }
        _ = try? await waterContainers()
    }

    private func needsServer<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch where error.isTransientFailure {
            throw APIError.server(message: "Changing containers needs your server. Your drinks still log offline.", code: "OFFLINE")
        }
    }

    /// The server's containers, kept here so an offline tap is still worth
    /// the right amount.
    private func mirror(_ containers: [WaterContainer]) {
        for row in store.all(LocalWaterContainer.self) { store.context.delete(row) }
        for container in containers {
            store.context.insert(LocalWaterContainer(
                id: container.id, name: container.name, volume: container.volume, unit: container.unit,
                isPrimary: container.isPrimary, servingsPerContainer: container.servingsPerContainer ?? 1
            ))
        }
        store.save()
    }

    // MARK: - Health, body, ranges

    func syncActiveEnergy(kilocalories: Double, date: Date) async throws {
        // An unchanged figure is no change: no sync for it.
        if try await local.upsertActiveEnergy(kilocalories: kilocalories, date: date) { sync.localChange() }
    }
    func bodyMeasurements(date: Date) async throws -> BodyMeasurements { try await local.bodyMeasurements(date: date) }
    func upsertBodyMeasurements(_ input: BodyMeasurementsInput) async throws -> BodyMeasurements {
        wrote(try await local.upsertBodyMeasurements(input))
    }
    func deleteBodyMeasurements(id: String) async throws {
        wrote(try await local.deleteBodyMeasurements(id: id))
    }
    func foodEntries(from start: Date, to end: Date) async throws -> [FoodEntryRangeRow] {
        try await local.foodEntries(from: start, to: end)
    }
    func goals(from start: Date, to end: Date) async throws -> [String: NutritionGoals] {
        try await local.goals(from: start, to: end)
    }
    func bodyMeasurements(from start: Date, to end: Date) async throws -> [DatedBodyMeasurements] {
        try await local.bodyMeasurements(from: start, to: end)
    }
    func exerciseSummary(from start: Date, to end: Date) async throws -> ExerciseRangeSummary {
        try await local.exerciseSummary(from: start, to: end)
    }
}
