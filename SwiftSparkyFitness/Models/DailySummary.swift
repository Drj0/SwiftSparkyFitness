//
//  DailySummary.swift
//  SwiftSparkyFitness
//
//  Mirrors the subset of GET /api/daily-summary we actually render.
//  The endpoint returns a lot more (supplement totals, per-nutrient goals,
//  raw water breakdown) — Decodable ignores fields we don't declare, so we
//  only model what the Today/Diary screens need. Field shapes (meal_type as a
//  plain string per entry, exercise "name" at the top level of each
//  session) were verified against the live server, not the OpenAPI doc.
//
//  Diary (Module 3) reuses this same model as Today rather than a separate
//  by-date endpoint — GET /api/daily-summary already returns everything a
//  day view needs (food_id/variant_id/meal_type_id per food entry,
//  exercise_id per session), confirmed live, so both screens read one
//  source of truth and can't disagree after an edit.
//

import Foundation

struct DailySummary: Decodable {
    let calorieBalance: CalorieBalance
    let waterIntake: Double
    /// Module 4: the same water total broken out by where it came from.
    /// Only `manual_ml` can be decremented or deleted (provider-synced and
    /// food-derived water isn't the app's to remove), so the water card
    /// needs the split, not just the sum. Optional because it's additive —
    /// nothing that read this model before has to change.
    let waterIntakeBreakdown: WaterTotals?
    let goals: Goals
    let foodEntries: [FoodEntrySummary]
    let exerciseSessions: [ExerciseSessionSummary]

    struct CalorieBalance: Decodable {
        let eaten: Double
        let burned: Double
        let remaining: Double
        let goal: Double
    }

    struct Goals: Decodable {
        /// The goal the user actually set, which is NOT the same number as
        /// `calorieBalance.goal`: that one falls back to a server-side
        /// default of 2000 when no goal row exists. Reading the balance to
        /// decide "has a goal been set?" therefore always answers yes, and
        /// the goal-not-set state became unreachable — verified live, a row
        /// with `calories: 0` still reported `calorieBalance.goal: 2000`.
        let calories: Double?
        let protein: Double?
        let carbs: Double?
        let fat: Double?
        let waterGoalMl: Double?
    }
}

struct FoodEntrySummary: Decodable, Identifiable {
    let id: String
    let foodName: String
    let mealType: String
    let quantity: Double
    let unit: String
    let calories: Double
    let protein: Double?
    let carbs: Double?
    let fat: Double?

    // Diary-only: needed to reopen FoodDetailView pre-loaded for editing.
    // Not used by Today, but harmless there — Decodable just ignores what
    // a decode site doesn't ask for, and Today never reads these.
    let foodId: String?
    let variantId: String?
    let mealTypeId: String?
    let brandName: String?
    /// The *default variant's* base serving size/unit — e.g. 50g — not the
    /// logged quantity (100g). Recovering the per-base-serving nutrition for
    /// the edit sheet means dividing back out: baseCalories = calories *
    /// servingSize / quantity (the inverse of createFoodEntry's scaling).
    let servingSize: Double?
    let servingUnit: String?
}

struct ExerciseSessionSummary: Decodable, Identifiable {
    let id: String
    let name: String?
    let caloriesBurned: Double?
    let durationMinutes: Double?
    /// Diary-only: needed to reopen LogExerciseView pre-loaded for editing
    /// without a redundant findOrCreateExercise(named:) lookup.
    let exerciseId: String?
}
