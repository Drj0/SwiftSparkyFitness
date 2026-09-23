//
//  BodyMeasurements.swift
//  SwiftSparkyFitness
//
//  The backend's "check-in" IS weight + body measurements — one row of
//  `check_in_measurements` per day, with weight/neck/waist/hips/height/
//  body_fat_percentage as columns on it. Confirmed against the schema:
//
//      "check_in_measurements_user_date_unique" UNIQUE (user_id, entry_date)
//
//  so a day holds exactly one weight and one of each measurement, and
//  POST /api/measurements/check-in is an upsert, not an append. That's the
//  answer to "how are multiple same-day weights handled": they can't exist,
//  and "today's weight" is unambiguous — no latest-vs-average rule needed
//  here or in Progress (Module 6). There is also no separate check-in
//  concept to build a third screen for.
//
//  Verified live: posting a subset of fields leaves the others untouched, an
//  explicit null clears one field, and GET for a day with nothing logged
//  returns `{}` (not 404, not null) — hence every field below is optional.
//

import Foundation

/// A day's check-in row. `id` is nil exactly when the server returned `{}`,
/// i.e. nothing is logged for that date.
struct BodyMeasurements: Decodable, Equatable, Sendable {
    let id: String?
    let weight: Double?
    let neck: Double?
    let waist: Double?
    let hips: Double?
    let height: Double?
    let bodyFatPercentage: Double?
    /// Smart-scale columns. Typed by hand here rather than device-provided,
    /// which is why the server's bounds matter — see BodyField.minimum.
    let muscleMassKg: Double?
    let boneMassKg: Double?
    let bodyWaterPercentage: Double?
    let bmr: Double?

    /// The smart-scale fields default to nil so adding them didn't churn
    /// every existing construction of this type.
    init(
        id: String?,
        weight: Double?,
        neck: Double?,
        waist: Double?,
        hips: Double?,
        height: Double?,
        bodyFatPercentage: Double?,
        muscleMassKg: Double? = nil,
        boneMassKg: Double? = nil,
        bodyWaterPercentage: Double? = nil,
        bmr: Double? = nil
    ) {
        self.id = id
        self.weight = weight
        self.neck = neck
        self.waist = waist
        self.hips = hips
        self.height = height
        self.bodyFatPercentage = bodyFatPercentage
        self.muscleMassKg = muscleMassKg
        self.boneMassKg = boneMassKg
        self.bodyWaterPercentage = bodyWaterPercentage
        self.bmr = bmr
    }

    static let none = BodyMeasurements(id: nil, weight: nil, neck: nil, waist: nil, hips: nil, height: nil, bodyFatPercentage: nil)

    var exists: Bool { id != nil }

    func value(for field: BodyField) -> Double? {
        switch field {
        case .weight: return weight
        case .neck: return neck
        case .waist: return waist
        case .hips: return hips
        case .height: return height
        case .bodyFatPercentage: return bodyFatPercentage
        case .muscleMassKg: return muscleMassKg
        case .boneMassKg: return boneMassKg
        case .bodyWaterPercentage: return bodyWaterPercentage
        case .bmr: return bmr
        }
    }

    /// The fields actually carrying a number, in display order — what the
    /// Today card and Diary's Body section list.
    var populatedFields: [(field: BodyField, value: Double)] {
        BodyField.allCases.compactMap { field in
            value(for: field).map { (field, $0) }
        }
    }
}

/// The manually-enterable columns of `check_in_measurements`, confirmed
/// against the live zod schema + table definition.
///
/// The smart-scale columns are included: they arrive from a device, but the
/// device shows you the numbers and there was otherwise no way to record
/// them. The server bounds them, and `bmr`'s lower bound of 600 is the one
/// constraint here that isn't "greater than zero" — see `minimum`.
///
/// Still excluded: `steps` — activity data feeding stepCalories, not a body
/// measurement. The Health integration reports active energy instead, which
/// the server prefers over step-derived calories anyway.
enum BodyField: String, CaseIterable, Identifiable {
    case weight
    case waist
    case hips
    case neck
    case height
    case bodyFatPercentage
    case muscleMassKg
    case boneMassKg
    case bodyWaterPercentage
    case bmr

    var id: String { rawValue }

    /// Column name in the request body. The shared encoder's
    /// convertToSnakeCase leaves already-snake_cased keys alone, but these
    /// are written out explicitly because they're dictionary keys, which no
    /// key strategy touches.
    var apiKey: String {
        switch self {
        case .bodyFatPercentage: return "body_fat_percentage"
        case .muscleMassKg: return "muscle_mass_kg"
        case .boneMassKg: return "bone_mass_kg"
        case .bodyWaterPercentage: return "body_water_percentage"
        default: return rawValue
        }
    }

    var label: String {
        switch self {
        case .weight: return "Weight"
        case .waist: return "Waist"
        case .hips: return "Hips"
        case .neck: return "Neck"
        case .height: return "Height"
        case .bodyFatPercentage: return "Body fat"
        case .muscleMassKg: return "Muscle mass"
        case .boneMassKg: return "Bone mass"
        case .bodyWaterPercentage: return "Body water"
        case .bmr: return "BMR"
        }
    }

    /// Which server-side unit preference labels this field.
    enum UnitKind { case weight, length, percent, energy }

    var unitKind: UnitKind {
        switch self {
        case .weight, .muscleMassKg, .boneMassKg: return .weight
        case .bodyFatPercentage, .bodyWaterPercentage: return .percent
        case .bmr: return .energy
        default: return .length
        }
    }

    func unitLabel(_ preferences: UserPreferences) -> String {
        switch unitKind {
        case .weight: return preferences.weightUnitLabel
        case .length: return preferences.measurementUnitLabel
        case .percent: return "%"
        case .energy: return "kcal"
        }
    }

    /// Upper bound for input validation. Body fat is a real percentage on
    /// the server (it bounds 0–100 on the smart-scale columns); the others
    /// are wide sanity limits that only catch a slipped decimal point.
    var maximum: Double {
        switch self {
        case .bodyFatPercentage, .bodyWaterPercentage: return 100
        case .weight: return 1000
        case .bmr: return 6000
        default: return 300
        }
    }

    /// Lower bound the server enforces. Everything here is simply "more than
    /// zero" except BMR, whose column carries a 600–6000 constraint — without
    /// modelling it, typing 550 returns a raw 400 ("Too small: expected
    /// number to be >=600") instead of a field error.
    var minimum: Double {
        self == .bmr ? 600 : 0
    }

    static let weightSheetFields: [BodyField] = [.weight]
    static let measurementSheetFields: [BodyField] = [
        .waist, .hips, .neck, .height, .bodyFatPercentage,
        .muscleMassKg, .boneMassKg, .bodyWaterPercentage, .bmr,
    ]
}

/// A check-in write. Only the fields in `values` are sent, which is what
/// makes the weight sheet and the measurements sheet safe to use on the same
/// day: saving a weight can't blank out this morning's waist measurement.
/// A `nil` value is sent as an explicit JSON null, which clears that column.
struct BodyMeasurementsInput: Encodable {
    let date: Date
    let values: [BodyField: Double?]

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(Self.dateFormatter.string(from: date), forKey: DynamicKey("entry_date"))
        // Sorted so the request body is stable and testable; the server
        // doesn't care about key order.
        for field in values.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let key = DynamicKey(field.apiKey)
            if let value = values[field], let value {
                try container.encode(value, forKey: key)
            } else {
                // encodeIfPresent would omit the key, which means "leave
                // this column alone" — the opposite of clearing it.
                try container.encodeNil(forKey: key)
            }
        }
    }
}
