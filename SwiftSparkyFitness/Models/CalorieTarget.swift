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
//    * Floor: 1200 kcal, the default `calorie_safety_floor_value`; 1500 for
//      men, the NIH's lowest unsupervised intake for them.
//    * Water: 35 ml per kg, what the web app's onboarding suggests.
//
//  PACE IS A SHARE OF BODY WEIGHT, NOT A FIXED KG
//  ----------------------------------------------
//  A fixed 1 kg a week is 0.6% of a 160 kg person and 2% of a 50 kg one.
//  The research frames safe pace relative to weight, so the three tiers do:
//
//    * Losing: 0.5 / 0.75 / 1% a week, capped at 1 kg. 0.5–1% is the range
//      shown to keep lean mass (Helms 2014, Garthe 2011: 0.7% kept more
//      muscle than 1.4%), and 1 kg is the top of the NIH's 0.5–1 kg advice.
//    * Gaining: 0.25 / 0.5 / 0.75% a week, capped at 0.5 kg. Past ~0.5% the
//      extra is mostly fat (Iraki 2019).
//    * The floor still wins: a pace whose target would go under it is
//      reported at the pace the floor actually allows.
//    * Target weight stays inside BMI 18.5 to 30, the WHO's healthy band
//      with room for a muscular build. Going lower isn't something to plan.
//

import Foundation

enum CalorieTarget {
    static let kcalPerKg = 6000.0
    static let floor = 1200.0

    /// The lowest daily target to suggest without medical supervision.
    static func floor(sex: UserProfile.Sex?) -> Double { sex == .male ? 1500 : floor }

    static let healthyBMI = 18.5...30.0

    enum Pace: String, CaseIterable, Identifiable {
        case slow = "Slow", medium = "Medium", fast = "Fast"
        var id: String { rawValue }

        /// Share of body weight per week.
        func weeklyShare(gaining: Bool) -> Double {
            switch self {
            case .slow: return gaining ? 0.0025 : 0.005
            case .medium: return gaining ? 0.005 : 0.0075
            case .fast: return gaining ? 0.0075 : 0.01
            }
        }

        /// What this pace asks for at `weightKg`, before the floor.
        func kgPerWeek(weightKg: Double, gaining: Bool) -> Double {
            min(weightKg * weeklyShare(gaining: gaining), gaining ? 0.5 : 1)
        }
    }

    /// The weight at `bmi` for this height.
    static func weightKg(bmi: Double, heightCm: Double) -> Double {
        bmi * pow(heightCm / 100, 2)
    }

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
    static func daily(maintenance: Double, goal: UserProfile.PrimaryGoal, kgPerWeek: Double, floor: Double = CalorieTarget.floor) -> Double {
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
