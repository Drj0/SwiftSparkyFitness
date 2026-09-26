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

        /// Water target to measure progress against.
        ///
        /// A goal the user never set is null, but one they *cleared* comes
        /// back as 0 — so `?? fallback` alone isn't enough, and it became
        /// reachable from the app itself once the goals sheet could write a
        /// blank water target. Dividing a ring's progress by that zero gave an
        /// infinite value.
        var effectiveWaterGoalMl: Double {
            guard let waterGoalMl, waterGoalMl > 0 else { return Self.fallbackWaterGoalMl }
            return waterGoalMl
        }

        /// Module 2 already showed this on Today before goals were editable,
        /// so it isn't a new invention.
        static let fallbackWaterGoalMl: Double = 2000
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

/// The exercise's own metadata as it was at the moment this session was
/// logged — present on `GET /api/daily-summary` entries as `exercise_snapshot`
/// (verified live 2026-09-26). The whole point is that it never changes
/// underneath a past entry: `exercise_entries.exercise_id` is nullable with
/// `ON DELETE SET NULL`, so editing or deleting the catalog exercise later
/// must not rewrite history. Read this for display, never re-fetch the live
/// catalog row for an already-logged entry.
struct ExerciseSnapshot: Decodable {
    let id: String?
    let name: String?
    let category: String?
    let modality: ExerciseModality?
    let equipment: [String]?
    let primaryMuscles: [String]?
    let secondaryMuscles: [String]?
    let instructions: [String]?
    let images: [String]?
    let force: String?
    let level: String?
    let mechanic: String?
}

struct ExerciseSessionSummary: Decodable, Identifiable {
    let id: String
    /// Present at top level on both shapes this decodes (the raw
    /// create/update ack and `daily-summary`'s nested entry) — kept as the
    /// display name and as the "Active Calories" sentinel check below.
    let name: String?
    let caloriesBurned: Double?
    let durationMinutes: Double?
    /// Diary-only: needed to reopen the entry editor pre-loaded for editing
    /// without a redundant catalog lookup.
    let exerciseId: String?

    var entryDate: String? = nil
    var entryTime: String? = nil
    var notes: String? = nil
    /// Cardio-only (`duration_distance` modality) — real top-level columns
    /// on `exercise_entries`, confirmed live, not something bolted on via
    /// notes text.
    var distance: Double? = nil
    var avgHeartRate: Int? = nil
    /// Strength (`weight_reps`/`reps_only` modality) — a real one-to-many
    /// `exercise_entry_sets` table, not a flat reps/weight trio. Absent
    /// (nil) rather than `[]` on rows that predate this or on cardio
    /// entries, so `setsList` is the safe way to read it.
    var sets: [ExerciseSet]? = nil
    var setsList: [ExerciseSet] { sets ?? [] }
    /// Present on the raw entry create/update response; `daily-summary`
    /// only carries it inside `exerciseSnapshot`, hence the fallback below.
    var modality: ExerciseModality? = nil
    var exerciseSnapshot: ExerciseSnapshot? = nil

    /// What the logging form should branch its editor on when this entry is
    /// reopened — the entry's own modality if present, else the snapshot's.
    var effectiveModality: ExerciseModality {
        modality ?? exerciseSnapshot?.modality ?? .duration
    }

    /// The server records a Health active-energy figure as an exercise entry
    /// against a sentinel exercise it names "Active Calories", rather than as
    /// a column of its own. It therefore arrives in `exerciseSessions` looking
    /// like a workout — one lasting zero minutes that the user never logged.
    ///
    /// Left alone it would sit in Today's exercise list and Diary's Exercise
    /// section offering to be edited (the edit sheet would ask how many
    /// minutes of "Active Calories" were done) and swiped away, which would
    /// then silently come back on the next sync. So the lists exclude it and
    /// the figure is surfaced as what it is.
    ///
    /// Matching on the name is the only handle the summary gives — there's no
    /// source or kind field distinguishing it. If a server release renames
    /// that exercise this check goes quiet rather than breaking: the row
    /// reappears as a zero-minute workout, which is visible.
    /// The one place this name is written down. Local mode has to *create*
    /// rows the same check then filters, so a second literal somewhere else
    /// would break the filter silently the moment either copy was edited.
    static let healthActiveEnergyName = "Active Calories"

    var isHealthActiveEnergy: Bool {
        name == Self.healthActiveEnergyName
    }

    /// Builds just enough of an `Exercise` to reopen this session in the
    /// entry editor for edits — from this entry's own snapshot, not a fresh
    /// catalog fetch. Deliberately no `caloriesPerHour`: edit mode always
    /// prefills a real logged calorie figure, so the editor's "suggest a
    /// default from the rate" path (which only fires when that field is
    /// still empty) never needs one here.
    var asExercise: Exercise {
        Exercise(
            id: exerciseId ?? "", name: name ?? exerciseSnapshot?.name ?? "Exercise",
            category: exerciseSnapshot?.category, modality: effectiveModality
        )
    }
}

extension Array where Element == ExerciseSessionSummary {
    /// Sessions the user actually logged, i.e. everything a list may offer to
    /// edit or delete.
    var userLogged: [ExerciseSessionSummary] {
        filter { !$0.isHealthActiveEnergy }
    }

    /// The Health-sourced active energy for the day, if any has been synced.
    var healthActiveEnergy: Double? {
        first { $0.isHealthActiveEnergy }?.caloriesBurned
    }
}
