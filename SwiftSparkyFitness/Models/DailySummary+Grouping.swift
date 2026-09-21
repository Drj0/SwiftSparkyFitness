//
//  DailySummary+Grouping.swift
//  SwiftSparkyFitness
//
//  Meal-grouping and macro-totals math, shared by Today and Diary (Module 3)
//  so both screens compute the same numbers off the same DailySummary the
//  exact same way — extracted out of TodayViewModel rather than having
//  DiaryViewModel reimplement it.
//

import Foundation

extension Array where Element == MealType {
    /// Entries grouped by meal, ordered by the meal type's sort order —
    /// falls back to the order meals appear in if meal types haven't loaded.
    func grouped(_ entries: [FoodEntrySummary]) -> [(mealType: MealType, entries: [FoodEntrySummary])] {
        let byName = Dictionary(grouping: entries, by: { $0.mealType })
        return sorted { $0.sortOrder < $1.sortOrder }.map { ($0, byName[$0.name] ?? []) }
    }
}

extension Array where Element == FoodEntrySummary {
    var macroTotals: (protein: Double, carbs: Double, fat: Double) {
        reduce(into: (0.0, 0.0, 0.0)) { totals, entry in
            totals.0 += entry.protein ?? 0
            totals.1 += entry.carbs ?? 0
            totals.2 += entry.fat ?? 0
        }
    }
}
