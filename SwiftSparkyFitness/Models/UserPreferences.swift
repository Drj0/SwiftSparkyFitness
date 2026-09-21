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
//  Confirmed live + against the reference web client: the stored numbers are
//  in whatever unit the preference names (the web client writes the typed
//  value as-is, and check_in_measurements has no unit column), so this app
//  does no conversion either — read the preference, label the field, store
//  the number. See PROGRESS.md for the one caveat this leaves behind (the
//  server's BMR math assumes kg/cm regardless of the preference).
//

import Foundation

struct UserPreferences: Decodable, Equatable, Sendable {
    let defaultWeightUnit: String?
    let defaultMeasurementUnit: String?
    let waterDisplayUnit: String?
    let measurementDecimalPlaces: Int?

    /// Used until the real preferences land (and if the call fails) — the
    /// same defaults the `user_preferences` table itself declares, so a
    /// failed fetch shows the same labels the server would have sent.
    static let serverDefaults = UserPreferences(
        defaultWeightUnit: "kg", defaultMeasurementUnit: "cm",
        waterDisplayUnit: "ml", measurementDecimalPlaces: 0
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

    /// How many decimals a measurement is shown with — the server tracks
    /// this per user (defaults to 0) so lists and cards agree.
    var decimals: Int { max(0, min(3, measurementDecimalPlaces ?? 0)) }

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
