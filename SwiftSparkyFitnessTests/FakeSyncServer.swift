//
//  FakeSyncServer.swift
//  SwiftSparkyFitnessTests
//
//  A SparkyFitness server for the sync tests: an in-memory local store
//  behind the `SyncServer` protocol, with the real server's behaviour where
//  sync depends on it — (source, source_id) upserts for food entries and
//  water, provider-id dedupe for foods, 404s for missing rows, and exercise
//  entries that *do* duplicate when sent twice — plus injectable failures:
//  a dropped connection, a 401, a refused row, and "the server did it but the
//  reply never arrived".
//

import Foundation
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class FakeSyncServer: SyncServer {
    let backing: LocalAPIClient

    /// Every call, in order, by name.
    private(set) var calls: [String] = []
    var mutatingCalls: [String] { calls.filter { !Self.reads.contains($0) } }
    private static let reads: Set<String> = [
        "serverVersion", "mealTypes", "dailySummary", "waterLog", "searchExercises",
        "userPreferences", "goalsRange", "bodyMeasurementsRange", "profile"
    ]

    /// Throws this for the next call of that name, before doing anything.
    var failNext: [String: Error] = [:]
    /// Performs the next call of that name, then throws a dropped connection:
    /// the server has the change, the device never heard.
    var dropReplyNext: Set<String> = []
    /// Every mutating call after this many throws a dropped connection.
    var goOfflineAfterMutations: Int?
    /// Runs before a call is performed — lets a test edit the device store
    /// "while the request is in flight".
    var beforeCall: ((String) -> Void)?

    private var foodEntryBySource: [String: String] = [:]
    private var foodByProvider: [String: Food] = [:]
    private var waterBySource: [String: String] = [:]

    init() {
        backing = LocalAPIClient(store: LocalStore(inMemory: true))
    }

    static let offline = URLError(.notConnectedToInternet)
    static let notFound = APIError.server(message: "Not found", code: nil, status: 404)
    static let refused = APIError.server(message: "Invalid", code: nil, status: 400)
    static let unauthorized = APIError.server(message: "Unauthorized", code: nil, status: 401)
    static let badGateway = APIError.server(message: "Bad gateway", code: nil, status: 502)

    /// Out of range: every call fails as unreachable.
    var isOffline = false
    /// A slow server: every call waits this long first.
    var delay: Duration?

    private func call<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        calls.append(name)
        beforeCall?(name)
        if let delay { try? await Task.sleep(for: delay) }
        if isOffline { throw Self.offline }
        if let error = failNext.removeValue(forKey: name) { throw error }
        if let limit = goOfflineAfterMutations, !Self.reads.contains(name), mutatingCalls.count > limit {
            throw Self.offline
        }
        let result = try await body()
        if dropReplyNext.remove(name) != nil { throw Self.offline }
        return result
    }

    // MARK: - Reads

    func serverVersion() async throws -> String { try await call("serverVersion") { "fake" } }
    func mealTypes() async throws -> [MealType] { try await call("mealTypes") { try await backing.mealTypes() } }
    func dailySummary(date: Date) async throws -> DailySummary { try await call("dailySummary") { try await backing.dailySummary(date: date) } }
    func waterLog(date: Date) async throws -> [WaterLogEntry] { try await call("waterLog") { try await backing.waterLog(date: date) } }
    func searchExercises(query: String) async throws -> [Exercise] { try await call("searchExercises") { try await backing.searchExercises(query: query) } }
    func userPreferences() async throws -> UserPreferences { try await call("userPreferences") { try await backing.userPreferences() } }
    func goals(from start: Date, to end: Date) async throws -> [String: NutritionGoals] {
        try await call("goalsRange") { try await backing.goals(from: start, to: end) }
    }
    func bodyMeasurements(from start: Date, to end: Date) async throws -> [DatedBodyMeasurements] {
        try await call("bodyMeasurementsRange") { try await backing.bodyMeasurements(from: start, to: end) }
    }

    // MARK: - Meal types

    func createMealType(name: String, sortOrder: Int) async throws -> MealType {
        try await call("createMealType") {
            // The real server refuses a second category with the same name.
            if try await backing.mealTypes().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw APIError.server(message: "A meal type with this name already exists", code: nil, status: 409)
            }
            return try await backing.createMealType(name: name, sortOrder: sortOrder)
        }
    }
    func updateMealType(id: String, _ input: MealTypeInput) async throws -> MealType {
        try await call("updateMealType") { try await backing.updateMealType(id: id, input) }
    }
    func deleteMealType(id: String) async throws {
        try await call("deleteMealType") { try await backing.deleteMealType(id: id) }
    }

    // MARK: - Foods and entries

    func createCustomFood(_ input: CustomFoodInput) async throws -> Food {
        try await call("createCustomFood") {
            if let provider = input.providerExternalId, let existing = foodByProvider[provider] { return existing }
            let food = try await backing.createCustomFood(input)
            if let provider = input.providerExternalId { foodByProvider[provider] = food }
            return food
        }
    }

    func createFoodEntry(_ input: FoodEntryInput) async throws -> String {
        try await call("createFoodEntry") {
            if let source = input.sourceId, let existing = foodEntryBySource[source], entryExists(existing) {
                try await backing.updateFoodEntry(id: existing, input)
                return existing
            }
            let id = try await backing.createFoodEntry(input)
            if let source = input.sourceId { foodEntryBySource[source] = id }
            return id
        }
    }

    func updateFoodEntry(id: String, _ input: FoodEntryInput) async throws {
        try await call("updateFoodEntry") {
            guard entryExists(id) else { throw Self.notFound }
            try await backing.updateFoodEntry(id: id, input)
        }
    }

    func deleteFoodEntry(id: String) async throws {
        try await call("deleteFoodEntry") {
            guard entryExists(id) else { throw Self.notFound }
            try await backing.deleteFoodEntry(id: id)
        }
    }

    private func entryExists(_ id: String) -> Bool {
        !backing.store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == id }).isEmpty
    }

    // MARK: - Exercise

    func createCustomExercise(_ input: CustomExerciseInput) async throws -> Exercise {
        try await call("createCustomExercise") { try await backing.createCustomExercise(input) }
    }
    func createExerciseEntry(_ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
        try await call("createExerciseEntry") { try await backing.createExerciseEntry(input) }
    }
    func updateExerciseEntry(id: String, _ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
        try await call("updateExerciseEntry") {
            guard !backing.store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.id == id }).isEmpty else { throw Self.notFound }
            return try await backing.updateExerciseEntry(id: id, input)
        }
    }
    func deleteExerciseEntry(id: String) async throws {
        try await call("deleteExerciseEntry") {
            guard !backing.store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.id == id }).isEmpty else { throw Self.notFound }
            try await backing.deleteExerciseEntry(id: id)
        }
    }
    func syncActiveEnergy(kilocalories: Double, date: Date) async throws {
        try await call("syncActiveEnergy") { try await backing.syncActiveEnergy(kilocalories: kilocalories, date: date) }
    }

    // MARK: - Water, body, goals, preferences

    func pushWater(milliliters: Double, date: Date, sourceId: String) async throws -> String {
        try await call("pushWater") {
            // Upsert, like the real ingest: same drink → same row, amount
            // updated; a row deleted since is made again.
            if let existing = waterBySource[sourceId],
               let row = backing.store.fetch(LocalWaterEntry.self, where: #Predicate { $0.id == existing }).first {
                row.waterMl = milliliters.rounded()
                backing.store.save()
                return existing
            }
            let before = Set(try await backing.waterLog(date: date).map(\.id))
            _ = try await backing.logWaterAmount(date: date, milliliters: milliliters.rounded())
            guard let id = try await backing.waterLog(date: date).map(\.id).first(where: { !before.contains($0) }) else {
                throw APIError.invalidResponse
            }
            waterBySource[sourceId] = id
            return id
        }
    }
    func deleteWaterLogEntry(id: String) async throws {
        try await call("deleteWaterLogEntry") {
            guard !backing.store.fetch(LocalWaterEntry.self, where: #Predicate { $0.id == id }).isEmpty else { throw Self.notFound }
            try await backing.deleteWaterLogEntry(id: id)
        }
    }
    func upsertBodyMeasurements(_ input: BodyMeasurementsInput) async throws -> BodyMeasurements {
        try await call("upsertBodyMeasurements") { try await backing.upsertBodyMeasurements(input) }
    }
    func deleteBodyMeasurements(id: String) async throws {
        try await call("deleteBodyMeasurements") {
            guard !backing.store.fetch(LocalCheckIn.self, where: #Predicate { $0.id == id }).isEmpty else { throw Self.notFound }
            try await backing.deleteBodyMeasurements(id: id)
        }
    }
    func saveGoals(_ goals: NutritionGoals, startingOn date: Date) async throws {
        try await call("saveGoals") { try await backing.saveGoals(goals, startingOn: date) }
    }
    func updateUserPreference(_ setting: UserPreferences.Setting, to value: String) async throws -> UserPreferences {
        // Written straight to the row: the real server keeps metric and never
        // converts on a unit switch, where the local client does.
        try await call("updateUserPreference") {
            let row = backing.store.all(LocalPreferences.self).first ?? {
                let fresh = LocalPreferences()
                backing.store.insert(fresh)
                return fresh
            }()
            LocalAPIClient.apply(setting, value, to: row)
            backing.store.save()
            return try await backing.userPreferences()
        }
    }
    func profile() async throws -> UserProfile {
        try await call("profile") { try await backing.profile() }
    }
    func saveProfile(_ profile: UserProfile) async throws {
        try await call("saveProfile") { try await backing.saveProfile(profile) }
    }
    private(set) var onboardingSubmissions: [OnboardingSubmission] = []
    func completeOnboarding(_ submission: OnboardingSubmission) async throws {
        try await call("completeOnboarding") { onboardingSubmissions.append(submission) }
    }
}
