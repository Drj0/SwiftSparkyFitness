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
//  anything edited since, nor bring back a server-linked row deleted since
//  (its tombstone is newer). A delete of a row that was never on a server
//  leaves no record, so restoring an older file does bring that row back —
//  the one thing a merge can't know. Row ids survive the round trip, which also means a
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
        case couldNotSave

        var errorDescription: String? {
            switch self {
            case .notADiary: return "That file isn't a SparkyFitness diary export."
            case .couldNotSave: return "Couldn't save the restored diary on this iPhone. Nothing was changed."
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
    struct Food: Codable, Equatable {
        var id, name: String
        var brand: String?
        var servingSize: Double, servingUnit: String
        var calories, protein, carbs, fat: Double
        var isCustom: Bool
        var lastUsedAt: Date?
        var usageCount: Int
        var updatedAt: Date
    }

    struct FoodEntry: Codable, Equatable {
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

    struct Exercise: Codable, Equatable {
        var id, name: String
        var category, modality: String?
        var caloriesPerHour: Double?
        var updatedAt: Date
    }

    struct ExerciseEntry: Codable, Equatable {
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

    struct Water: Codable, Equatable {
        var id, dayKey: String
        var waterMl: Double
        var source: String
        var containerName: String?
        var loggedAt: Date
        var updatedAt: Date
    }

    struct WaterContainer: Codable, Equatable {
        var id: Int
        var name: String
        var volume: Double, unit: String
        var isPrimary: Bool
        var servingsPerContainer: Int
    }

    struct CheckIn: Codable, Equatable {
        var id, dayKey: String
        var weight, neck, waist, hips, height: Double?
        var bodyFatPercentage, muscleMassKg, boneMassKg, bodyWaterPercentage, bmr: Double?
        var updatedAt: Date
    }

    struct Goal: Codable, Equatable {
        var dayKey: String
        var rawJSON: Data
        var updatedAt: Date
    }

    struct Preferences: Codable, Equatable {
        var id, defaultWeightUnit, defaultMeasurementUnit, waterDisplayUnit: String
        var measurementDecimalPlaces, itemDisplayLimit: Int
        var defaultDistanceUnit, activityLevel: String
        var exerciseCaloriePercentage: Double
        var updatedAt: Date
        /// Onboarding's answers. Optional, so files written before them
        /// still read.
        var sex, birthDate, primaryGoal: String?
        var targetWeight: Double?
    }

    struct MealType: Codable, Equatable {
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
        foods = store.all(LocalFood.self).map(Self.archived)
        foodEntries = store.all(LocalFoodEntry.self, sortBy: [SortDescriptor(\.dayKey)]).map(Self.archived)
        exercises = store.all(LocalExercise.self).map(Self.archived)
        exerciseEntries = store.all(LocalExerciseEntry.self, sortBy: [SortDescriptor(\.dayKey)]).map(Self.archived)
        water = store.all(LocalWaterEntry.self, sortBy: [SortDescriptor(\.dayKey)]).map(Self.archived)
        waterContainers = store.all(LocalWaterContainer.self).map {
            WaterContainer(id: $0.id, name: $0.name, volume: $0.volume, unit: $0.unit,
                           isPrimary: $0.isPrimary, servingsPerContainer: $0.servingsPerContainer)
        }
        checkIns = store.all(LocalCheckIn.self, sortBy: [SortDescriptor(\.dayKey)]).map(Self.archived)
        goals = store.all(LocalGoalRow.self, sortBy: [SortDescriptor(\.dayKey)]).map(Self.archived)
        preferences = store.all(LocalPreferences.self).map(Self.archived)
        mealTypes = store.all(LocalMealType.self).map(Self.archived)
    }

    // One per model, shared by export and by restore's "is this row
    // actually different" check, so the two can't drift apart.

    static func archived(_ row: LocalFood) -> Food {
        Food(id: row.id, name: row.name, brand: row.brand, servingSize: row.servingSize, servingUnit: row.servingUnit,
             calories: row.calories, protein: row.protein, carbs: row.carbs, fat: row.fat, isCustom: row.isCustom,
             lastUsedAt: row.lastUsedAt, usageCount: row.usageCount, updatedAt: row.updatedAt)
    }

    static func archived(_ row: LocalFoodEntry) -> FoodEntry {
        FoodEntry(id: row.id, dayKey: row.dayKey, entryDate: row.entryDate, foodId: row.foodId, foodName: row.foodName,
                  brandName: row.brandName, mealTypeId: row.mealTypeId, mealTypeName: row.mealTypeName,
                  quantity: row.quantity, unit: row.unit, servingSize: row.servingSize, servingUnit: row.servingUnit,
                  calories: row.calories, protein: row.protein, carbs: row.carbs, fat: row.fat, updatedAt: row.updatedAt)
    }

    static func archived(_ row: LocalExercise) -> Exercise {
        Exercise(id: row.id, name: row.name, category: row.category, modality: row.modality,
                 caloriesPerHour: row.caloriesPerHour, updatedAt: row.updatedAt)
    }

    static func archived(_ row: LocalExerciseEntry) -> ExerciseEntry {
        ExerciseEntry(id: row.id, dayKey: row.dayKey, entryDate: row.entryDate, exerciseId: row.exerciseId, name: row.name,
                      durationMinutes: row.durationMinutes, caloriesBurned: row.caloriesBurned, modality: row.modality,
                      distance: row.distance, avgHeartRate: row.avgHeartRate, notes: row.notes,
                      entryTime: row.entryTime, setsJSON: row.setsJSON, updatedAt: row.updatedAt)
    }

    static func archived(_ row: LocalWaterEntry) -> Water {
        Water(id: row.id, dayKey: row.dayKey, waterMl: row.waterMl, source: row.source,
              containerName: row.containerName, loggedAt: row.loggedAt, updatedAt: row.updatedAt)
    }

    static func archived(_ row: LocalCheckIn) -> CheckIn {
        CheckIn(id: row.id, dayKey: row.dayKey, weight: row.weight, neck: row.neck, waist: row.waist, hips: row.hips,
                height: row.height, bodyFatPercentage: row.bodyFatPercentage, muscleMassKg: row.muscleMassKg,
                boneMassKg: row.boneMassKg, bodyWaterPercentage: row.bodyWaterPercentage, bmr: row.bmr,
                updatedAt: row.updatedAt)
    }

    static func archived(_ row: LocalGoalRow) -> Goal {
        Goal(dayKey: row.dayKey, rawJSON: row.rawJSON, updatedAt: row.updatedAt)
    }

    static func archived(_ row: LocalPreferences) -> Preferences {
        Preferences(id: row.id, defaultWeightUnit: row.defaultWeightUnit, defaultMeasurementUnit: row.defaultMeasurementUnit,
                    waterDisplayUnit: row.waterDisplayUnit, measurementDecimalPlaces: row.measurementDecimalPlaces,
                    itemDisplayLimit: row.itemDisplayLimit, defaultDistanceUnit: row.defaultDistanceUnit,
                    activityLevel: row.activityLevel, exerciseCaloriePercentage: row.exerciseCaloriePercentage,
                    updatedAt: row.updatedAt, sex: row.sex, birthDate: row.birthDate, primaryGoal: row.primaryGoal,
                    targetWeight: row.targetWeight)
    }

    static func archived(_ row: LocalMealType) -> MealType {
        MealType(id: row.id, name: row.name, sortOrder: row.sortOrder, isVisible: row.isVisible,
                 isSystemDefault: row.isSystemDefault, defaultTime: row.defaultTime, updatedAt: row.updatedAt)
    }
}

// MARK: - Restore

extension DiaryArchive {
    struct RestoreResult: Equatable {
        var added = 0
        var updated = 0
        /// Rows this device already had in a newer (or the same) state.
        var kept = 0
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
            apply: (Archived, Row) -> Void,
            snapshot: (Row) -> Archived
        ) where Archived: Equatable {
            var byKey: [String: Row] = [:]
            for row in existing { byKey[existingKey(row)] = row }
            // A linked row deleted here after the file was made stays
            // deleted: its tombstone is newer than the file's copy.
            var deletedAt: [String: Date] = [:]
            for tombstone in store.tombstones(kind: Row.syncKind) { deletedAt[tombstone.localKey] = tombstone.deletedAt }
            for item in archived {
                if let row = byKey[key(item)] {
                    if stamp(item) > row.updatedAt {
                        apply(item, row)
                        row.updatedAt = stamp(item)
                        result.updated += 1
                    } else if stamp(item) == .distantPast && row.updatedAt == .distantPast && snapshot(row) != item {
                        // Neither side has ever been stamped — rows from
                        // before tracking existed, against a fresh device's
                        // seeded defaults — and they differ. The file holds
                        // the user's real settings, so it wins; the row is
                        // stamped just past "never" so restoring the same
                        // file again is a no-op.
                        apply(item, row)
                        row.updatedAt = Date.distantPast.addingTimeInterval(1)
                        result.updated += 1
                    } else {
                        result.kept += 1
                    }
                } else if let deleted = deletedAt[key(item)], deleted >= stamp(item) {
                    result.kept += 1
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
              make: { LocalFood(id: $0.id, name: $0.name) }, apply: Self.apply, snapshot: Self.archived)
        merge(foodEntries, key: \.id, stamp: \.updatedAt, existing: store.all(LocalFoodEntry.self), existingKey: \.id,
              make: { LocalFoodEntry(id: $0.id, entryDate: $0.entryDate, foodId: $0.foodId, foodName: $0.foodName,
                                     mealTypeId: $0.mealTypeId, mealTypeName: $0.mealTypeName, quantity: $0.quantity,
                                     unit: $0.unit, servingSize: $0.servingSize, servingUnit: $0.servingUnit,
                                     calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat) },
              apply: Self.apply, snapshot: Self.archived)
        merge(exercises, key: \.id, stamp: \.updatedAt, existing: store.all(LocalExercise.self), existingKey: \.id,
              make: { LocalExercise(id: $0.id, name: $0.name) }, apply: Self.apply, snapshot: Self.archived)
        merge(exerciseEntries, key: \.id, stamp: \.updatedAt, existing: store.all(LocalExerciseEntry.self), existingKey: \.id,
              make: { LocalExerciseEntry(id: $0.id, entryDate: $0.entryDate, exerciseId: $0.exerciseId, name: $0.name,
                                         durationMinutes: $0.durationMinutes, caloriesBurned: $0.caloriesBurned) },
              apply: Self.apply, snapshot: Self.archived)
        merge(water, key: \.id, stamp: \.updatedAt, existing: store.all(LocalWaterEntry.self), existingKey: \.id,
              make: { LocalWaterEntry(id: $0.id, dayKey: $0.dayKey, waterMl: $0.waterMl) }, apply: Self.apply, snapshot: Self.archived)
        // One check-in per day on both sides, so a day's row is the same row
        // whatever id each copy happened to get.
        merge(checkIns, key: \.dayKey, stamp: \.updatedAt, existing: store.all(LocalCheckIn.self), existingKey: \.dayKey,
              make: { LocalCheckIn(id: $0.id, dayKey: $0.dayKey) }, apply: Self.apply, snapshot: Self.archived)
        merge(goals, key: \.dayKey, stamp: \.updatedAt, existing: store.all(LocalGoalRow.self), existingKey: \.dayKey,
              make: { LocalGoalRow(dayKey: $0.dayKey, rawJSON: $0.rawJSON) }, apply: { $1.rawJSON = $0.rawJSON }, snapshot: Self.archived)
        merge(preferences, key: \.id, stamp: \.updatedAt, existing: store.all(LocalPreferences.self), existingKey: \.id,
              make: { _ in LocalPreferences() }, apply: Self.apply, snapshot: Self.archived)
        merge(mealTypes, key: \.id, stamp: \.updatedAt, existing: store.all(LocalMealType.self), existingKey: \.id,
              make: { LocalMealType(id: $0.id, name: $0.name, sortOrder: $0.sortOrder) }, apply: Self.apply, snapshot: Self.archived)

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
            throw store.lastSaveError ?? ArchiveError.couldNotSave
        }
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
        // An older file has no answers; it shouldn't erase newer ones.
        row.sex = item.sex ?? row.sex; row.birthDate = item.birthDate ?? row.birthDate
        row.primaryGoal = item.primaryGoal ?? row.primaryGoal; row.targetWeight = item.targetWeight ?? row.targetWeight
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
