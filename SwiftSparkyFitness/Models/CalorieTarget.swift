//
//  CalorieTarget.swift
//  SwiftSparkyFitness
//
//  Onboarding's suggested daily targets. The same numbers the server uses
//  (`@workspace/shared` calorieCalculations / calorieConstants), so a goal
//  suggested here agrees with what the server would compute from the same
//  profile:
//
//    * BMR: Mifflin-St Jeor, the server's default `bmr_algorithm`.
//    * TDEE: BMR x the activity multiplier for the preference's key.
//    * Pace: 6000 kcal per kg of body-weight change
//      (ENERGY_DENSITY_KCAL_PER_KG), in either direction.
//    * Floor: 1200 kcal, the default `calorie_safety_floor_value`.
//    * Water: 35 ml per kg, what the web app's onboarding suggests.
//

import Foundation

enum CalorieTarget {
    static let kcalPerKg = 6000.0
    static let floor = 1200.0

    /// The keys the Units screen offers for `activity_level`.
    static let activityMultipliers: [String: Double] = [
        "sedentary": 1.2, "lightly_active": 1.375, "moderately_active": 1.55,
        "very_active": 1.725, "extra_active": 1.9,
    ]

    static func bmr(weightKg: Double, heightCm: Double, age: Int, sex: UserProfile.Sex) -> Double {
        10 * weightKg + 6.25 * heightCm - 5 * Double(age) + (sex == .male ? 5 : -161)
    }

    static func maintenance(weightKg: Double, heightCm: Double, age: Int, sex: UserProfile.Sex, activityLevel: String) -> Double {
        bmr(weightKg: weightKg, heightCm: heightCm, age: age, sex: sex) * (activityMultipliers[activityLevel] ?? 1.2)
    }

    /// Maintenance moved by the weekly pace, never under the floor, on the
    /// 10 kcal grid the goal picker uses.
    static func daily(maintenance: Double, goal: UserProfile.PrimaryGoal, kgPerWeek: Double) -> Double {
        let change = kgPerWeek * kcalPerKg / 7
        let target: Double
        switch goal {
        case .lose: target = maintenance - change
        case .maintain: target = maintenance
        case .gain: target = maintenance + change
        }
        return (max(target, floor) / 10).rounded() * 10
    }

    /// 35 ml per kg, to the nearest 250 ml.
    static func waterMl(weightKg: Double) -> Double {
        ((weightKg * 35) / 250).rounded() * 250
    }

    static func age(birthDate: Date, on day: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.year], from: birthDate, to: day).year ?? 0
    }

    static func kilograms(_ value: Double, unit: String) -> Double {
        unit == "lbs" ? value * 0.45359237 : value
    }

    static func centimetres(_ value: Double, unit: String) -> Double {
        unit == "inches" ? value * 2.54 : value
    }
}
