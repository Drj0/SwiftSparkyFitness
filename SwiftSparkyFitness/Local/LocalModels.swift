//
//  LocalModels.swift
//  SwiftSparkyFitness
//
//  The SwiftData schema behind local-only mode.
//
//  Two constraints shaped every type here, and both are deliberate:
//
//  1. CloudKit compatibility, even though nothing syncs yet. iCloud sync is a
//     separate module, and CloudKit schemas are additive-only once promoted to
//     production — so `@Attribute(.unique)` and non-optional relationships are
//     avoided now rather than migrated away from later. There are no
//     relationships at all: rows reference each other by id, exactly as the
//     server's flat DTOs already do, which also keeps the mapping trivial.
//
//  2. Day-keyed queries. Every dated row carries a `dayKey` ("yyyy-MM-dd")
//     alongside its Date. The server's whole API is day-addressed, and matching
//     on a string avoids predicating on Date ranges for what is really a
//     calendar-day question — the same reason the API client has a
//     `yyyy-MM-dd` formatter rather than sending timestamps.
//

import Foundation
import SwiftData

/// Formats and parses the `yyyy-MM-dd` day keys every dated row is filed under.
/// Gregorian and POSIX-fixed so a non-Gregorian device calendar can't shift
/// which day a row belongs to.
enum LocalDay {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static func key(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ key: String) -> Date? { formatter.date(from: key) }
}

@Model
final class LocalFood {
    var id: String = UUID().uuidString
    var name: String = ""
    var brand: String?
    var servingSize: Double = 100
    var servingUnit: String = "g"
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    /// Distinguishes a food the user typed from one materialised out of a
    /// provider result, so the two can be told apart in search ordering.
    var isCustom: Bool = true
    /// Drives the RECENT list, which the server otherwise ranks for us.
    var lastUsedAt: Date?
    var usageCount: Int = 0

    init(
        id: String = UUID().uuidString,
        name: String,
        brand: String? = nil,
        servingSize: Double = 100,
        servingUnit: String = "g",
        calories: Double = 0,
        protein: Double = 0,
        carbs: Double = 0,
        fat: Double = 0,
        isCustom: Bool = true,
        lastUsedAt: Date? = nil,
        usageCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.servingSize = servingSize
        self.servingUnit = servingUnit
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.isCustom = isCustom
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
    }
}

/// Nutrition is stored **already scaled** for the logged quantity, matching
/// what the day screens sum. The server stores it the same way — its own
/// aggregates then re-scale a second time, which is the double-counting bug
/// Module 5 had to work around. Local mode simply doesn't have that bug.
@Model
final class LocalFoodEntry {
    var id: String = UUID().uuidString
    var dayKey: String = ""
    var entryDate: Date = Date()
    var foodId: String = ""
    var foodName: String = ""
    var brandName: String?
    var mealTypeId: String = ""
    var mealTypeName: String = ""
    var quantity: Double = 0
    var unit: String = "g"
    var servingSize: Double = 100
    var servingUnit: String = "g"
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0

    init(
        id: String = UUID().uuidString,
        entryDate: Date,
        foodId: String,
        foodName: String,
        brandName: String? = nil,
        mealTypeId: String,
        mealTypeName: String,
        quantity: Double,
        unit: String,
        servingSize: Double,
        servingUnit: String,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double
    ) {
        self.id = id
        self.entryDate = entryDate
        self.dayKey = LocalDay.key(entryDate)
        self.foodId = foodId
        self.foodName = foodName
        self.brandName = brandName
        self.mealTypeId = mealTypeId
        self.mealTypeName = mealTypeName
        self.quantity = quantity
        self.unit = unit
        self.servingSize = servingSize
        self.servingUnit = servingUnit
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }
}

@Model
final class LocalExercise {
    var id: String = UUID().uuidString
    var name: String = ""
    var category: String?
    /// Additive (Module 12): the real taxonomy the server keys logging UI
    /// off of. Stored as the raw string, not `ExerciseModality`, so the
    /// CloudKit schema never has to model an enum.
    var modality: String?
    var caloriesPerHour: Double?

    init(id: String = UUID().uuidString, name: String, category: String? = nil, modality: String? = nil, caloriesPerHour: Double? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.modality = modality
        self.caloriesPerHour = caloriesPerHour
    }
}

@Model
final class LocalExerciseEntry {
    var id: String = UUID().uuidString
    var dayKey: String = ""
    var entryDate: Date = Date()
    var exerciseId: String = ""
    var name: String = ""
    var durationMinutes: Double = 0
    var caloriesBurned: Double = 0
    /// Additive (Module 12), all optional/defaulted so the CloudKit schema
    /// stays additive-only. `setsJSON` is a flat JSON-encoded
    /// `[ExerciseSetInput]` rather than a relationship — SwiftData's
    /// CloudKit mirroring can't express one (see Module 10/11), and a
    /// handful of sets per entry never needs querying on its own.
    var modality: String?
    var distance: Double?
    var avgHeartRate: Int?
    var notes: String?
    var entryTime: String?
    var setsJSON: String?

    init(
        id: String = UUID().uuidString,
        entryDate: Date,
        exerciseId: String,
        name: String,
        durationMinutes: Double,
        caloriesBurned: Double,
        modality: String? = nil,
        distance: Double? = nil,
        avgHeartRate: Int? = nil,
        notes: String? = nil,
        entryTime: String? = nil,
        setsJSON: String? = nil
    ) {
        self.id = id
        self.entryDate = entryDate
        self.dayKey = LocalDay.key(entryDate)
        self.exerciseId = exerciseId
        self.name = name
        self.durationMinutes = durationMinutes
        self.caloriesBurned = caloriesBurned
        self.modality = modality
        self.distance = distance
        self.avgHeartRate = avgHeartRate
        self.notes = notes
        self.entryTime = entryTime
        self.setsJSON = setsJSON
    }
}

/// One row per drink, mirroring the server's ledger rather than a daily total.
/// The per-entry list, the swipe-to-delete and the "undo removes the most
/// recent *manual* drink" rule all need individual rows; a running total can't
/// express any of them.
@Model
final class LocalWaterEntry {
    var id: String = UUID().uuidString
    var dayKey: String = ""
    var waterMl: Double = 0
    /// "manual" for a tap, or a provider name. Only manual rows are undoable,
    /// which is the server's rule and the reason food-derived water is shown
    /// on its own non-swipeable line.
    var source: String = "manual"
    var containerName: String?
    var loggedAt: Date = Date()

    init(
        id: String = UUID().uuidString,
        dayKey: String,
        waterMl: Double,
        source: String = "manual",
        containerName: String? = nil,
        loggedAt: Date = Date()
    ) {
        self.id = id
        self.dayKey = dayKey
        self.waterMl = waterMl
        self.source = source
        self.containerName = containerName
        self.loggedAt = loggedAt
    }
}

@Model
final class LocalWaterContainer {
    var id: Int = 0
    var name: String = ""
    var volume: Double = 0
    var unit: String = "ml"
    var isPrimary: Bool = false
    var servingsPerContainer: Int = 1

    init(id: Int, name: String, volume: Double, unit: String = "ml", isPrimary: Bool = false, servingsPerContainer: Int = 1) {
        self.id = id
        self.name = name
        self.volume = volume
        self.unit = unit
        self.isPrimary = isPrimary
        self.servingsPerContainer = servingsPerContainer
    }
}

/// One row per day, matching `check_in_measurements`' UNIQUE (user, date).
/// Enforced in code rather than with `@Attribute(.unique)`, which CloudKit
/// cannot express — see the file header.
@Model
final class LocalCheckIn {
    var id: String = UUID().uuidString
    var dayKey: String = ""
    var weight: Double?
    var neck: Double?
    var waist: Double?
    var hips: Double?
    var height: Double?
    var bodyFatPercentage: Double?
    var muscleMassKg: Double?
    var boneMassKg: Double?
    var bodyWaterPercentage: Double?
    var bmr: Double?

    init(id: String = UUID().uuidString, dayKey: String) {
        self.id = id
        self.dayKey = dayKey
    }
}

/// Goals are date-versioned and carried forward: a row is in force from its
/// effective day until a later row supersedes it. The server does that
/// carry-forward on read, and `ProgressViewModel` does *not* — it looks each
/// day up directly — so local mode has to expand the rows per day itself or
/// the goal line silently disappears.
@Model
final class LocalGoalRow {
    var dayKey: String = ""
    /// The whole goal bag as JSON, so columns this app doesn't model survive
    /// exactly as `NutritionGoals` already preserves them over the wire.
    var rawJSON: Data = Data()

    init(dayKey: String, rawJSON: Data) {
        self.dayKey = dayKey
        self.rawJSON = rawJSON
    }
}

@Model
final class LocalPreferences {
    var id: String = "preferences"
    var defaultWeightUnit: String = "kg"
    var defaultMeasurementUnit: String = "cm"
    var waterDisplayUnit: String = "ml"
    var measurementDecimalPlaces: Int = 0
    var itemDisplayLimit: Int = 10
    /// Additive (Module 12), matching the server's own defaults.
    var defaultDistanceUnit: String = "km"
    var activityLevel: String = "sedentary"
    var exerciseCaloriePercentage: Double = 100

    init() {}
}

@Model
final class LocalMealType {
    var id: String = UUID().uuidString
    var name: String = ""
    var sortOrder: Int = 0
    var isVisible: Bool = true
    /// The four the app seeds. They're hideable but not renameable or
    /// deletable, matching the server's own asymmetric rules.
    var isSystemDefault: Bool = false
    var defaultTime: String?

    init(id: String = UUID().uuidString, name: String, sortOrder: Int, isVisible: Bool = true, isSystemDefault: Bool = false) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isVisible = isVisible
        self.isSystemDefault = isSystemDefault
    }
}
