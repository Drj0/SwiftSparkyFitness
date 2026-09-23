//
//  NutritionGoals.swift
//  SwiftSparkyFitness
//
//  A day's nutrition goals, and the awkward write contract behind them.
//
//  THE WRITE IS A DESTRUCTIVE FULL-ROW REPLACE
//  -------------------------------------------
//  `POST /api/goals/manage-timeline` does not merge. Any column absent from
//  the body is written as 0. Verified live: a row with sodium 2300, fibre 30
//  and an exercise target of 400 came back with all three at 0 after a POST
//  that sent only calories and macros.
//
//  The app surfaces five of these (calories, the three macros, water), but
//  the web client can set two dozen more — sodium, fibre, the vitamins,
//  exercise targets, per-meal calorie distribution. So editing a calorie goal
//  here must not be allowed to silently wipe them.
//
//  Hence this doesn't enumerate the schema: it keeps the server's response
//  verbatim and puts every key back on write, overwriting only what the user
//  actually changed. A column added to the backend later round-trips on its
//  own, with no change here.
//
//  TWO MORE TRAPS
//  --------------
//  * Write keys are `p_`-prefixed (`p_calories`), read keys are not
//    (`calories`). Sending an unprefixed field returns 200 and writes
//    nothing — a silent no-op that looks exactly like success.
//    `custom_meal_percentages` and `custom_nutrients` are the exceptions:
//    they are *not* prefixed.
//  * If `protein_percentage`, `carbs_percentage` and `fat_percentage` are all
//    numbers, the server computes macro grams from them and overrides the
//    gram fields. They're null here by default, and null is preserved rather
//    than coerced to 0 — three zeroes would count as "all numbers" and zero
//    out the macros. (Verified: omitting them leaves them null, unlike every
//    other column.)
//

import Foundation

struct NutritionGoals: Equatable {
    /// Everything the server sent, untouched, so a write can put it all back.
    private var raw: [String: JSONValue]

    /// Keys that must NOT take the `p_` prefix on write.
    private static let unprefixedOnWrite: Set<String> = [
        "custom_meal_percentages", "custom_nutrients",
    ]

    /// Read-only on the response; the write names the date `p_start_date`.
    private static let readOnlyKeys: Set<String> = ["goal_date", "id", "user_id"]

    init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    private func number(_ key: String) -> Double? {
        if case .number(let value) = raw[key] { return value }
        return nil
    }

    private mutating func setNumber(_ key: String, _ value: Double?) {
        raw[key] = value.map(JSONValue.number) ?? .null
    }

    var calories: Double? {
        get { number("calories") }
        set { setNumber("calories", newValue) }
    }
    var protein: Double? {
        get { number("protein") }
        set { setNumber("protein", newValue) }
    }
    var carbs: Double? {
        get { number("carbs") }
        set { setNumber("carbs", newValue) }
    }
    var fat: Double? {
        get { number("fat") }
        set { setNumber("fat", newValue) }
    }
    var waterGoalMl: Double? {
        get { number("water_goal_ml") }
        set { setNumber("water_goal_ml", newValue) }
    }

    /// A goal row exists in a meaningful sense only once calories are set —
    /// the server returns a zeroed row rather than 404 for an account that
    /// has never set one.
    var isSet: Bool { (calories ?? 0) > 0 }

    /// The body for `POST /api/goals/manage-timeline`.
    ///
    /// `startDate` is the day the goal takes effect. The timeline inherits
    /// forward, so writing today's goal also applies to every later date
    /// until another row supersedes it.
    func writePayload(startingOn startDate: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["p_start_date": .string(startDate)]
        for (key, value) in raw where !Self.readOnlyKeys.contains(key) {
            body[Self.unprefixedOnWrite.contains(key) ? key : "p_\(key)"] = value
        }
        return body
    }
}

extension NutritionGoals: Decodable {
    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }
}

/// Minimal type-erased JSON, so goal columns this app has no opinion about
/// survive a round trip instead of being flattened to 0.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognised JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
