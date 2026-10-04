//
//  UserPreferences.swift
//  SwiftSparkyFitness
//
//  The units every weight/measurement/water number in the app is labelled
//  with. Deliberately NOT hardcoded client-side: the backend already owns
//  this (GET /api/user-preferences returns default_weight_unit,
//  default_measurement_unit, water_display_unit), so Settings (Module 5)
//  only has to PUT it back — there's nothing here to rework later.
//
//  This device stores numbers in the units named here; the server stores
//  kg and cm, and sync converts (see `metricFactor` below). That was once
//  "no conversion anywhere", matching the web client of the time; the web
//  client has converted to metric since v1.7 (March 2026).
//

import Foundation

struct UserPreferences: Decodable, Equatable, Sendable {
    let defaultWeightUnit: String?
    let defaultMeasurementUnit: String?
    let waterDisplayUnit: String?
    let measurementDecimalPlaces: Int?
    /// Module 12: exercise-side preferences, parallel to the three above —
    /// same table, same "the server doesn't validate these" caveat, same
    /// partial-merge PUT. `defaultDistanceUnit` labels cardio distance
    /// (`km` default, confirmed against the migration); `activityLevel` and
    /// `exerciseCaloriePercentage` feed the server's TDEE/goal math and have
    /// no display use in this app yet, but round-trip safely either way.
    // `var`, not `let`, despite the default: a `let` with an initial value is
    // silently skipped by synthesized `Decodable` (Swift assigns the default
    // once and never calls decode for it), which would make every response
    // from the server look like it never sent these three fields. Caught by
    // the build, not by reading the docs — worth remembering elsewhere too.
    var defaultDistanceUnit: String? = nil
    var activityLevel: String? = nil
    var exerciseCaloriePercentage: Double? = nil

    /// Used until the real preferences land (and if the call fails) — the
    /// same defaults the `user_preferences` table itself declares, so a
    /// failed fetch shows the same labels the server would have sent.
    static let serverDefaults = UserPreferences(
        defaultWeightUnit: "kg", defaultMeasurementUnit: "cm",
        waterDisplayUnit: "ml", measurementDecimalPlaces: 0,
        defaultDistanceUnit: "km", activityLevel: "sedentary", exerciseCaloriePercentage: 100
    )

    /// Short label for a weight field, e.g. "kg". `st_lbs`/`ft_in` are
    /// compound units the server allows but which a single numeric field
    /// can't express properly — they're labelled honestly rather than
    /// silently treated as their primary component, and no UI can select
    /// them until Settings exists.
    var weightUnitLabel: String {
        switch defaultWeightUnit {
        case "lbs": return "lb"
        case "st_lbs": return "st"
        default: return "kg"
        }
    }

    var measurementUnitLabel: String {
        switch defaultMeasurementUnit {
        case "inches": return "in"
        case "ft_in": return "ft"
        default: return "cm"
        }
    }

    /// Water is logged in ml by the backend regardless of this; the
    /// preference only decides how a total is presented.
    var waterUnitLabel: String {
        switch waterDisplayUnit {
        case "oz": return "oz"
        case "liter": return "L"
        default: return "ml"
        }
    }

    var distanceUnitLabel: String {
        switch defaultDistanceUnit {
        case "miles": return "mi"
        default: return "km"
        }
    }

    /// How many decimals a measurement is shown with — the server tracks
    /// this per user (defaults to 0) so lists and cards agree.
    var decimals: Int { max(0, min(3, measurementDecimalPlaces ?? 0)) }

    // MARK: - What Settings may offer
    //
    // **The server does not validate any of these.** `PUT` with
    // `default_weight_unit: "bogus"` returns 200 and stores it, verified
    // live — so these lists are the only thing keeping the value sane, and
    // every label getter above falls back through `default:` rather than
    // trusting what comes back.
    //
    // `st_lbs` and `ft_in` are accepted by the server and deliberately NOT
    // offered: they're compound units, and the app has a single numeric field
    // per measurement. Showing "13.5 st" is not how anyone writes stone and
    // pounds, so selecting one here would promise something the UI can't
    // keep. A value set from the web client still reads back and is labelled
    // honestly.

    enum Setting: String, CaseIterable, Identifiable {
        case weight, measurement, water, decimals
        // Module 12 — exercise-side, same "Goals & Units" section (per the
        // Module 11 reorganisation: this is "how is the app set up for me",
        // not a new area).
        case distance, activityLevel, exerciseCaloriePercentage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .weight: return "Weight"
            case .measurement: return "Measurements"
            case .water: return "Water"
            case .decimals: return "Decimal places"
            case .distance: return "Distance"
            case .activityLevel: return "Activity level"
            case .exerciseCaloriePercentage: return "Exercise calorie credit"
            }
        }

        /// Stored value → what the picker shows.
        var options: [(value: String, label: String)] {
            switch self {
            case .weight: return [("kg", "kg"), ("lbs", "lb")]
            case .measurement: return [("cm", "cm"), ("inches", "in")]
            case .water: return [("ml", "ml"), ("oz", "oz"), ("liter", "L")]
            case .decimals: return [("0", "0"), ("1", "1"), ("2", "2")]
            case .distance: return [("km", "km"), ("miles", "mi")]
            // The five "backend keys" `ACTIVITY_MULTIPLIERS` actually reads
            // (confirmed in the shared constants file) — the server's own
            // default, `not_much`, is a legacy alias for `sedentary` and
            // isn't offered, matching the "value set elsewhere" fallback
            // every other picker here already relies on.
            case .activityLevel:
                return [
                    ("sedentary", "Sedentary"), ("lightly_active", "Lightly active"),
                    ("moderately_active", "Moderately active"), ("very_active", "Very active"),
                    ("extra_active", "Extra active"),
                ]
            case .exerciseCaloriePercentage:
                return [("50", "50%"), ("75", "75%"), ("100", "100%"), ("125", "125%"), ("150", "150%")]
            }
        }

        /// The request key. Written out because these are dictionary keys,
        /// which no key-encoding strategy touches.
        var apiKey: String {
            switch self {
            case .weight: return "default_weight_unit"
            case .measurement: return "default_measurement_unit"
            case .water: return "water_display_unit"
            case .decimals: return "measurement_decimal_places"
            case .distance: return "default_distance_unit"
            case .activityLevel: return "activity_level"
            case .exerciseCaloriePercentage: return "exercise_calorie_percentage"
            }
        }

        /// Whether this setting's value is a JSON number rather than a
        /// string — `updateUserPreference` needs to know which encoder to
        /// use, since sending a numeric preference as a string stores a
        /// string.
        var isNumeric: Bool {
            self == .decimals || self == .exerciseCaloriePercentage
        }
    }

    func value(for setting: Setting) -> String {
        switch setting {
        case .weight: return defaultWeightUnit ?? "kg"
        case .measurement: return defaultMeasurementUnit ?? "cm"
        case .water: return waterDisplayUnit ?? "ml"
        case .decimals: return String(decimals)
        case .distance: return defaultDistanceUnit ?? "km"
        case .activityLevel: return activityLevel ?? "sedentary"
        case .exerciseCaloriePercentage: return String(Int(exerciseCaloriePercentage ?? 100))
        }
    }

    /// Formats a stored value for display.
    ///
    /// `measurement_decimal_places` is treated as a *minimum*, not a ceiling:
    /// it defaults to 0 on the server, and obeying that literally showed a
    /// weight the user had typed as 73.1 as "73" (caught in a render). A
    /// preference about presentation must not quietly misreport the stored
    /// number, so extra places are kept — up to two — whenever rounding away
    /// would change the value.
    func formatted(_ value: Double) -> String {
        for places in decimals...max(decimals, 2) {
            let rendered = String(format: "%.\(places)f", value)
            if let round = Double(rendered), abs(round - value) < 0.0001 {
                return rendered
            }
        }
        return String(format: "%.\(max(decimals, 2))f", value)
    }
}

// MARK: - Metric on the server

/// The server keeps body measurements in kg and cm and converts only for
/// display, as its web app has since v1.7 (March 2026). This app stores the
/// number as shown, in these units, so sync converts on the way through
/// (ServerPush, ServerPull) and a unit switch rewrites what's stored.
extension UserPreferences {
    /// One unit shown here, in the server's metric.
    func metricFactor(_ kind: BodyField.UnitKind) -> Double {
        switch kind {
        case .weight:
            switch defaultWeightUnit {
            case "lbs": return 0.45359237
            case "st_lbs": return 6.35029318
            default: return 1
            }
        case .length:
            switch defaultMeasurementUnit {
            case "inches": return 2.54
            case "ft_in": return 30.48
            default: return 1
            }
        case .percent, .energy: return 1
        }
    }

    func toMetric(_ value: Double, _ kind: BodyField.UnitKind) -> Double {
        value * metricFactor(kind)
    }

    /// Two places, so 154.3 lb comes back as 154.3, not 154.29999.
    func fromMetric(_ value: Double, _ kind: BodyField.UnitKind) -> Double {
        let factor = metricFactor(kind)
        return factor == 1 ? value : (value / factor * 100).rounded() / 100
    }
}
