//
//  DiaryArchive.swift
//  SwiftSparkyFitness
//
//  The diary as one JSON file, for the case neither iCloud nor a server can
//  cover: iCloud off with no server, a server that's gone, a change of Apple
//  ID. See docs/SYNC_SWITCHING_PLAN.md, "The safety net".
//
//  A file format, so it is written out field by field rather than derived
//  from the models: renaming a Swift property must not silently change what
//  an old backup means. `version` goes up only when a field's meaning
//  changes; new optional fields don't need it.
//
//  Restoring merges, it never deletes. A row is matched by the same key the
//  sync ledger uses; the file's copy wins only when it is newer. So restoring
//  the same file twice is a no-op, and restoring an old file can't roll back
//  anything edited since. Row ids survive the round trip, which also means a
//  restored food entry still dedupes on a server (its `source_id` is its id).
//  Links and tombstones are not in the file — they describe one server's copy,
//  and a file may be restored long after that stopped being true.
//

import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DiaryArchive: Codable {
    static let format = "sparkyfitness-diary"
    static let currentVersion = 1

    var format = DiaryArchive.format
    var version = DiaryArchive.currentVersion
    var exportedAt = Date()

    var foods: [Food] = []
    var foodEntries: [FoodEntry] = []
    var exercises: [Exercise] = []
    var exerciseEntries: [ExerciseEntry] = []
    var water: [Water] = []
    var waterContainers: [WaterContainer] = []
    var checkIns: [CheckIn] = []
    var goals: [Goal] = []
    var preferences: [Preferences] = []
    var mealTypes: [MealType] = []

    var rowCount: Int {
        foods.count + foodEntries.count + exercises.count + exerciseEntries.count + water.count
            + waterContainers.count + checkIns.count + goals.count + preferences.count + mealTypes.count
    }

    enum ArchiveError: LocalizedError, Equatable {
        case notADiary
        case tooNew(Int)

        var errorDescription: String? {
            switch self {
            case .notADiary: return "That file isn't a SparkyFitness diary export."
            case .tooNew(let version): return "That export was made by a newer version of the app (format \(version)). Update the app to restore it."
            }
        }
    }

    // MARK: - Coding

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    static func decode(_ data: Data) throws -> DiaryArchive {
        struct Header: Decodable { let format: String?; let version: Int? }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == format else {
            throw ArchiveError.notADiary
        }
        if let version = header.version, version > currentVersion { throw ArchiveError.tooNew(version) }
        return try decoder.decode(DiaryArchive.self, from: data)
    }
}

// MARK: - Rows

extension DiaryArchive {
    struct Food: Codable {
        var id, name: String
        var brand: String?
        var servingSize: Double, servingUnit: String
        var calories, protein, carbs, fat: Double
        var isCustom: Bool
        var lastUsedAt: Date?
        var usageCount: Int
        var updatedAt: Date
    }

    struct FoodEntry: Codable {
        var id, dayKey: String
        var entryDate: Date
        var foodId, foodName: String
        var brandName: String?
        var mealTypeId, mealTypeName: String
        var quantity: Double, unit: String
        var servingSize: Double, servingUnit: String
        var calories, protein, carbs, fat: Double
        var updatedAt: Date
    }

    struct Exercise: Codable {
        var id, name: String
        var category, modality: String?
        var caloriesPerHour: Double?
        var updatedAt: Date
    }

    struct ExerciseEntry: Codable {
        var id, dayKey: String
        var entryDate: Date
        var exerciseId, name: String
        var durationMinutes, caloriesBurned: Double
        var modality: String?
        var distance: Double?
        var avgHeartRate: Int?
        var notes, entryTime, setsJSON: String?
        var updatedAt: Date
    }

    struct Water: Codable {
        var id, dayKey: String
        var waterMl: Double
        var source: String
        var containerName: String?
        var loggedAt: Date
        var updatedAt: Date
    }

    struct WaterContainer: Codable {
        var id: Int
        var name: String
        var volume: Double, unit: String
        var isPrimary: Bool
        var servingsPerContainer: Int
    }

    struct CheckIn: Codable {
        var id, dayKey: String
        var weight, neck, waist, hips, height: Double?
        var bodyFatPercentage, muscleMassKg, boneMassKg, bodyWaterPercentage, bmr: Double?
        var updatedAt: Date
    }

    struct Goal: Codable {
        var dayKey: String
        var rawJSON: Data
        var updatedAt: Date
    }

    struct Preferences: Codable {
        var id, defaultWeightUnit, defaultMeasurementUnit, waterDisplayUnit: String
        var measurementDecimalPlaces, itemDisplayLimit: Int
        var defaultDistanceUnit, activityLevel: String
        var exerciseCaloriePercentage: Double
        var updatedAt: Date
    }

    struct MealType: Codable {
        var id, name: String
        var sortOrder: Int
        var isVisible, isSystemDefault: Bool
        var defaultTime: String?
        var updatedAt: Date
    }
}

// MARK: - Export

extension DiaryArchive {
    @MainActor
    init(from store: LocalStore) {
        foods = store.all(LocalFood.self).map {
            Food(id: $0.id, name: $0.name, brand: $0.brand, servingSize: $0.servingSize, servingUnit: $0.servingUnit,
                 calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat, isCustom: $0.isCustom,
                 lastUsedAt: $0.lastUsedAt, usageCount: $0.usageCount, updatedAt: $0.updatedAt)
        }
        foodEntries = store.all(LocalFoodEntry.self, sortBy: [SortDescriptor(\.dayKey)]).map {
            FoodEntry(id: $0.id, dayKey: $0.dayKey, entryDate: $0.entryDate, foodId: $0.foodId, foodName: $0.foodName,
                      brandName: $0.brandName, mealTypeId: $0.mealTypeId, mealTypeName: $0.mealTypeName,
                      quantity: $0.quantity, unit: $0.unit, servingSize: $0.servingSize, servingUnit: $0.servingUnit,
                      calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat, updatedAt: $0.updatedAt)
        }
        exercises = store.all(LocalExercise.self).map {
            Exercise(id: $0.id, name: $0.name, category: $0.category, modality: $0.modality,
                     caloriesPerHour: $0.caloriesPerHour, updatedAt: $0.updatedAt)
        }
        exerciseEntries = store.all(LocalExerciseEntry.self, sortBy: [SortDescriptor(\.dayKey)]).map {
            ExerciseEntry(id: $0.id, dayKey: $0.dayKey, entryDate: $0.entryDate, exerciseId: $0.exerciseId, name: $0.name,
                          durationMinutes: $0.durationMinutes, caloriesBurned: $0.caloriesBurned, modality: $0.modality,
                          distance: $0.distance, avgHeartRate: $0.avgHeartRate, notes: $0.notes,
                          entryTime: $0.entryTime, setsJSON: $0.setsJSON, updatedAt: $0.updatedAt)
        }
        water = store.all(LocalWaterEntry.self, sortBy: [SortDescriptor(\.dayKey)]).map {
            Water(id: $0.id, dayKey: $0.dayKey, waterMl: $0.waterMl, source: $0.source,
                  containerName: $0.containerName, loggedAt: $0.loggedAt, updatedAt: $0.updatedAt)
        }
        waterContainers = store.all(LocalWaterContainer.self).map {
            WaterContainer(id: $0.id, name: $0.name, volume: $0.volume, unit: $0.unit,
                           isPrimary: $0.isPrimary, servingsPerContainer: $0.servingsPerContainer)
        }
        checkIns = store.all(LocalCheckIn.self, sortBy: [SortDescriptor(\.dayKey)]).map {
            CheckIn(id: $0.id, dayKey: $0.dayKey, weight: $0.weight, neck: $0.neck, waist: $0.waist, hips: $0.hips,
                    height: $0.height, bodyFatPercentage: $0.bodyFatPercentage, muscleMassKg: $0.muscleMassKg,
                    boneMassKg: $0.boneMassKg, bodyWaterPercentage: $0.bodyWaterPercentage, bmr: $0.bmr,
                    updatedAt: $0.updatedAt)
        }
        goals = store.all(LocalGoalRow.self, sortBy: [SortDescriptor(\.dayKey)]).map {
            Goal(dayKey: $0.dayKey, rawJSON: $0.rawJSON, updatedAt: $0.updatedAt)
        }
        preferences = store.all(LocalPreferences.self).map {
            Preferences(id: $0.id, defaultWeightUnit: $0.defaultWeightUnit, defaultMeasurementUnit: $0.defaultMeasurementUnit,
                        waterDisplayUnit: $0.waterDisplayUnit, measurementDecimalPlaces: $0.measurementDecimalPlaces,
                        itemDisplayLimit: $0.itemDisplayLimit, defaultDistanceUnit: $0.defaultDistanceUnit,
                        activityLevel: $0.activityLevel, exerciseCaloriePercentage: $0.exerciseCaloriePercentage,
                        updatedAt: $0.updatedAt)
        }
        mealTypes = store.all(LocalMealType.self).map {
            MealType(id: $0.id, name: $0.name, sortOrder: $0.sortOrder, isVisible: $0.isVisible,
                     isSystemDefault: $0.isSystemDefault, defaultTime: $0.defaultTime, updatedAt: $0.updatedAt)
        }
    }
}

// MARK: - Restore

extension DiaryArchive {
    struct RestoreResult: Equatable {
        var added = 0
        var updated = 0
        /// Rows this device already had in a newer (or the same) state.
        var kept = 0
        /// The earliest day in the file, so the caller can make it reachable.
        var earliestDay: Date?
    }

    /// Merges the file into `store` in one save: all of it or none of it.
    @MainActor
    func restore(into store: LocalStore) throws -> RestoreResult {
        var result = RestoreResult()

        func merge<Row: SyncTracked, Archived>(
            _ archived: [Archived],
            key: (Archived) -> String,
            stamp: (Archived) -> Date,
            existing: [Row],
            existingKey: (Row) -> String,
            make: (Archived) -> Row,
            apply: (Archived, Row) -> Void
        ) {
            var byKey: [String: Row] = [:]
            for row in existing { byKey[existingKey(row)] = row }
            for item in archived {
                if let row = byKey[key(item)] {
                    if stamp(item) > row.updatedAt {
                        apply(item, row)
                        row.updatedAt = stamp(item)
                        result.updated += 1
                    } else {
                        result.kept += 1
                    }
                } else {
                    // `make` covers the initializer's required fields;
                    // `apply` fills in every other one.
                    let row = make(item)
                    apply(item, row)
                    row.updatedAt = stamp(item)
                    store.context.insert(row)
                    byKey[key(item)] = row
                    result.added += 1
                }
            }
        }

        merge(foods, key: \.id, stamp: \.updatedAt, existing: store.all(LocalFood.self), existingKey: \.id,
              make: { LocalFood(id: $0.id, name: $0.name) }, apply: Self.apply)
        merge(foodEntries, key: \.id, stamp: \.updatedAt, existing: store.all(LocalFoodEntry.self), existingKey: \.id,
              make: { LocalFoodEntry(id: $0.id, entryDate: $0.entryDate, foodId: $0.foodId, foodName: $0.foodName,
                                     mealTypeId: $0.mealTypeId, mealTypeName: $0.mealTypeName, quantity: $0.quantity,
                                     unit: $0.unit, servingSize: $0.servingSize, servingUnit: $0.servingUnit,
                                     calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat) },
              apply: Self.apply)
        merge(exercises, key: \.id, stamp: \.updatedAt, existing: store.all(LocalExercise.self), existingKey: \.id,
              make: { LocalExercise(id: $0.id, name: $0.name) }, apply: Self.apply)
        merge(exerciseEntries, key: \.id, stamp: \.updatedAt, existing: store.all(LocalExerciseEntry.self), existingKey: \.id,
              make: { LocalExerciseEntry(id: $0.id, entryDate: $0.entryDate, exerciseId: $0.exerciseId, name: $0.name,
                                         durationMinutes: $0.durationMinutes, caloriesBurned: $0.caloriesBurned) },
              apply: Self.apply)
        merge(water, key: \.id, stamp: \.updatedAt, existing: store.all(LocalWaterEntry.self), existingKey: \.id,
              make: { LocalWaterEntry(id: $0.id, dayKey: $0.dayKey, waterMl: $0.waterMl) }, apply: Self.apply)
        // One check-in per day on both sides, so a day's row is the same row
        // whatever id each copy happened to get.
        merge(checkIns, key: \.dayKey, stamp: \.updatedAt, existing: store.all(LocalCheckIn.self), existingKey: \.dayKey,
              make: { LocalCheckIn(id: $0.id, dayKey: $0.dayKey) }, apply: Self.apply)
        merge(goals, key: \.dayKey, stamp: \.updatedAt, existing: store.all(LocalGoalRow.self), existingKey: \.dayKey,
              make: { LocalGoalRow(dayKey: $0.dayKey, rawJSON: $0.rawJSON) }, apply: { $1.rawJSON = $0.rawJSON })
        merge(preferences, key: \.id, stamp: \.updatedAt, existing: store.all(LocalPreferences.self), existingKey: \.id,
              make: { _ in LocalPreferences() }, apply: Self.apply)
        merge(mealTypes, key: \.id, stamp: \.updatedAt, existing: store.all(LocalMealType.self), existingKey: \.id,
              make: { LocalMealType(id: $0.id, name: $0.name, sortOrder: $0.sortOrder) }, apply: Self.apply)

        // Containers carry no stamp: added when missing, never overwritten.
        let containerIds = Set(store.all(LocalWaterContainer.self).map(\.id))
        for container in waterContainers where !containerIds.contains(container.id) {
            store.context.insert(LocalWaterContainer(
                id: container.id, name: container.name, volume: container.volume, unit: container.unit,
                isPrimary: container.isPrimary, servingsPerContainer: container.servingsPerContainer
            ))
            result.added += 1
        }

        let saved = store.preservingStamps { store.save() }
        guard saved else {
            store.context.rollback()
            throw store.lastSaveError ?? ArchiveError.notADiary
        }

        let days = foodEntries.map(\.dayKey) + exerciseEntries.map(\.dayKey) + water.map(\.dayKey) + checkIns.map(\.dayKey)
        result.earliestDay = days.min().flatMap(LocalDay.date)
        return result
    }

    private static func apply(_ item: Food, to row: LocalFood) {
        row.name = item.name; row.brand = item.brand
        row.servingSize = item.servingSize; row.servingUnit = item.servingUnit
        row.calories = item.calories; row.protein = item.protein; row.carbs = item.carbs; row.fat = item.fat
        row.isCustom = item.isCustom; row.lastUsedAt = item.lastUsedAt; row.usageCount = item.usageCount
    }

    private static func apply(_ item: FoodEntry, to row: LocalFoodEntry) {
        row.dayKey = item.dayKey; row.entryDate = item.entryDate
        row.foodId = item.foodId; row.foodName = item.foodName; row.brandName = item.brandName
        row.mealTypeId = item.mealTypeId; row.mealTypeName = item.mealTypeName
        row.quantity = item.quantity; row.unit = item.unit
        row.servingSize = item.servingSize; row.servingUnit = item.servingUnit
        row.calories = item.calories; row.protein = item.protein; row.carbs = item.carbs; row.fat = item.fat
    }

    private static func apply(_ item: Exercise, to row: LocalExercise) {
        row.name = item.name; row.category = item.category; row.modality = item.modality
        row.caloriesPerHour = item.caloriesPerHour
    }

    private static func apply(_ item: ExerciseEntry, to row: LocalExerciseEntry) {
        row.dayKey = item.dayKey; row.entryDate = item.entryDate
        row.exerciseId = item.exerciseId; row.name = item.name
        row.durationMinutes = item.durationMinutes; row.caloriesBurned = item.caloriesBurned
        row.modality = item.modality; row.distance = item.distance; row.avgHeartRate = item.avgHeartRate
        row.notes = item.notes; row.entryTime = item.entryTime; row.setsJSON = item.setsJSON
    }

    private static func apply(_ item: Water, to row: LocalWaterEntry) {
        row.dayKey = item.dayKey; row.waterMl = item.waterMl; row.source = item.source
        row.containerName = item.containerName; row.loggedAt = item.loggedAt
    }

    private static func apply(_ item: CheckIn, to row: LocalCheckIn) {
        row.weight = item.weight; row.neck = item.neck; row.waist = item.waist; row.hips = item.hips
        row.height = item.height; row.bodyFatPercentage = item.bodyFatPercentage
        row.muscleMassKg = item.muscleMassKg; row.boneMassKg = item.boneMassKg
        row.bodyWaterPercentage = item.bodyWaterPercentage; row.bmr = item.bmr
    }

    private static func apply(_ item: Preferences, to row: LocalPreferences) {
        row.defaultWeightUnit = item.defaultWeightUnit; row.defaultMeasurementUnit = item.defaultMeasurementUnit
        row.waterDisplayUnit = item.waterDisplayUnit; row.measurementDecimalPlaces = item.measurementDecimalPlaces
        row.itemDisplayLimit = item.itemDisplayLimit; row.defaultDistanceUnit = item.defaultDistanceUnit
        row.activityLevel = item.activityLevel; row.exerciseCaloriePercentage = item.exerciseCaloriePercentage
    }

    private static func apply(_ item: MealType, to row: LocalMealType) {
        row.name = item.name; row.sortOrder = item.sortOrder; row.isVisible = item.isVisible
        row.isSystemDefault = item.isSystemDefault; row.defaultTime = item.defaultTime
    }
}

// MARK: - File

/// The export as a document `fileExporter` can write.
struct DiaryArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func defaultFilename(on date: Date = Date()) -> String {
        "SparkyFitness Diary \(LocalDay.key(date))"
    }
}

/// When this device last wrote an export, for "Last exported …" in Settings.
enum DiaryExportRecord {
    static let defaultsKey = "diaryLastExportedAt"

    static var lastExportedAt: Date? {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
