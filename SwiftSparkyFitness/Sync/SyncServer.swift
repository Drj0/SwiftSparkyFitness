//
//  SyncServer.swift
//  SwiftSparkyFitness
//
//  Exactly what the sync engine needs from a SparkyFitness server, and no
//  more. `APIClient` conforms (most requirements are its existing methods);
//  tests conform an in-memory fake with the real server's dedupe rules and
//  injectable failures, which is what lets retries and crashes be tested.
//

import Foundation

/// The `source` the engine stamps on everything it writes, so the server's
/// (user, source, source_id) upserts make every write safe to repeat.
enum SyncServerSource {
    static let tag = "sparky_ios"
}

protocol SyncServer {
    // Reads
    func serverVersion() async throws -> String
    func mealTypes() async throws -> [MealType]
    func dailySummary(date: Date) async throws -> DailySummary
    func waterLog(date: Date) async throws -> [WaterLogEntry]
    func searchExercises(query: String) async throws -> [Exercise]
    func userPreferences() async throws -> UserPreferences
    func goals(from start: Date, to end: Date) async throws -> [String: NutritionGoals]
    func bodyMeasurements(from start: Date, to end: Date) async throws -> [DatedBodyMeasurements]

    // Meal types
    func createMealType(name: String, sortOrder: Int) async throws -> MealType
    func updateMealType(id: String, _ input: MealTypeInput) async throws -> MealType
    func deleteMealType(id: String) async throws

    // Foods and entries
    func createCustomFood(_ input: CustomFoodInput) async throws -> Food
    @discardableResult
    func createFoodEntry(_ input: FoodEntryInput) async throws -> String
    func updateFoodEntry(id: String, _ input: FoodEntryInput) async throws
    func deleteFoodEntry(id: String) async throws

    // Exercise
    func createCustomExercise(_ input: CustomExerciseInput) async throws -> Exercise
    func createExerciseEntry(_ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary
    func updateExerciseEntry(id: String, _ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary
    func deleteExerciseEntry(id: String) async throws
    func syncActiveEnergy(kilocalories: Double, date: Date) async throws

    // Water, body, goals, preferences
    func pushWater(milliliters: Double, date: Date, sourceId: String) async throws -> String
    func deleteWaterLogEntry(id: String) async throws
    func upsertBodyMeasurements(_ input: BodyMeasurementsInput) async throws -> BodyMeasurements
    func deleteBodyMeasurements(id: String) async throws
    func saveGoals(_ goals: NutritionGoals, startingOn date: Date) async throws
    func updateUserPreference(_ setting: UserPreferences.Setting, to value: String) async throws -> UserPreferences
}

extension APIClient: SyncServer {}
