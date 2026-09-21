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
/// Deliberately excluded, with reasons:
///   * `steps` — activity data (it feeds stepCalories), not a body
///     measurement; it belongs to a health-sync path, not a typed form.
///   * `muscle_mass_kg`, `bone_mass_kg`, `body_water_percentage`, `bmr` —
///     smart-scale columns. The server bounds them (and `bmr` has a
///     600–6000 CHECK constraint) because they arrive from a device, not a
///     keyboard.
enum BodyField: String, CaseIterable, Identifiable {
    case weight
    case waist
    case hips
    case neck
    case height
    case bodyFatPercentage

    var id: String { rawValue }

    /// Column name in the request body. The shared encoder's
    /// convertToSnakeCase leaves already-snake_cased keys alone, but these
    /// are written out explicitly because they're dictionary keys, which no
    /// key strategy touches.
    var apiKey: String {
        switch self {
        case .bodyFatPercentage: return "body_fat_percentage"
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
        }
    }

    /// Which server-side unit preference labels this field.
    enum UnitKind { case weight, length, percent }

    var unitKind: UnitKind {
        switch self {
        case .weight: return .weight
        case .bodyFatPercentage: return .percent
        default: return .length
        }
    }

    func unitLabel(_ preferences: UserPreferences) -> String {
        switch unitKind {
        case .weight: return preferences.weightUnitLabel
        case .length: return preferences.measurementUnitLabel
        case .percent: return "%"
        }
    }

    /// Upper bound for input validation. Body fat is a real percentage on
    /// the server (it bounds 0–100 on the smart-scale columns); the others
    /// are wide sanity limits that only catch a slipped decimal point.
    var maximum: Double {
        switch self {
        case .bodyFatPercentage: return 100
        case .weight: return 1000
        default: return 300
        }
    }

    static let weightSheetFields: [BodyField] = [.weight]
    static let measurementSheetFields: [BodyField] = [.waist, .hips, .neck, .height, .bodyFatPercentage]
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
