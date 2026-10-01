//
//  ExerciseCatalog.swift
//  SwiftSparkyFitness
//
//  The built-in exercise list: offline, instant, and the only source that
//  knows how hard an exercise is. Neither Free Exercise DB nor Wger carries
//  a calorie rate (search results come back with 0), and Apple publishes
//  none, so the intensity has to live here.
//
//  Source priority, highest first, wherever two disagree:
//    1. Apple Health — a recorded workout's measured calories.
//    2. This catalog — MET-based estimate.
//    3. Free Exercise DB / Wger — names, photos, instructions.
//
//  MET values are from the Compendium of Physical Activities (Ainsworth et
//  al.). kcal = MET × body weight (kg) × hours. `imageId` is the exercise's
//  folder in Free Exercise DB (public domain, Unlicense), where photos live.
//

import Foundation

struct CatalogExercise: Identifiable, Hashable {
    let name: String
    let category: String
    let modality: ExerciseModality
    /// Metabolic equivalent: multiples of resting energy use.
    let met: Double
    /// SF Symbol shown beside the exercise.
    let symbol: String
    let imageId: String?
    /// Offered in the idle state of Log Exercise, before anything is typed.
    var popular = false

    var id: String { name }

    init(_ name: String, _ category: String, _ modality: ExerciseModality, met: Double,
         symbol: String, imageId: String?, popular: Bool = false) {
        self.name = name
        self.category = category
        self.modality = modality
        self.met = met
        self.symbol = symbol
        self.imageId = imageId
        self.popular = popular
    }

    /// kcal per hour for someone of `weightKg`.
    func caloriesPerHour(weightKg: Double) -> Double {
        met * weightKg
    }
}

enum ExerciseCatalog {
    /// Used when the user hasn't logged a weight: a common adult reference
    /// figure, and the estimate is labelled as one anyway.
    static let fallbackWeightKg: Double = 70

    static func entry(named name: String) -> CatalogExercise? {
        byName[normalized(name)]
    }

    static func search(_ query: String) -> [CatalogExercise] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return [] }
        let hits = all.filter { normalized($0.name).contains(needle) || $0.category == needle }
        // Names that *start* with the query first: "run" → Running before
        // Treadmill Running.
        return hits.filter { normalized($0.name).hasPrefix(needle) }
            + hits.filter { !normalized($0.name).hasPrefix(needle) }
    }

    static var popular: [CatalogExercise] { all.filter(\.popular) }

    /// Case- and punctuation-insensitive, so "Push-ups", "pushups" and
    /// "Push Ups" are one exercise when deduplicating across sources.
    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let byName: [String: CatalogExercise] =
        Dictionary(all.map { (normalized($0.name), $0) }, uniquingKeysWith: { first, _ in first })

    static let all: [CatalogExercise] = [
        .init("Walking", "cardio", .durationDistance, met: 3.5, symbol: "figure.walk", imageId: "Walking_Treadmill", popular: true),
        .init("Brisk Walking", "cardio", .durationDistance, met: 4.3, symbol: "figure.walk", imageId: nil),
        .init("Hiking", "cardio", .durationDistance, met: 6.0, symbol: "figure.hiking", imageId: "Trail_Running_Walking"),
        .init("Running", "cardio", .durationDistance, met: 9.8, symbol: "figure.run", imageId: "Running_Treadmill", popular: true),
        .init("Jogging", "cardio", .durationDistance, met: 7.0, symbol: "figure.run", imageId: "Jogging_Treadmill"),
        .init("Treadmill Running", "cardio", .durationDistance, met: 9.0, symbol: "figure.run.treadmill", imageId: "Running_Treadmill"),
        .init("Treadmill Walking", "cardio", .durationDistance, met: 3.8, symbol: "figure.walk.treadmill", imageId: "Walking_Treadmill"),
        .init("Cycling", "cardio", .durationDistance, met: 7.5, symbol: "figure.outdoor.cycle", imageId: "Bicycling", popular: true),
        .init("Stationary Bike", "cardio", .durationDistance, met: 6.8, symbol: "figure.indoor.cycle", imageId: "Bicycling_Stationary"),
        .init("Recumbent Bike", "cardio", .durationDistance, met: 5.5, symbol: "figure.indoor.cycle", imageId: "Recumbent_Bike"),
        .init("Mountain Biking", "cardio", .durationDistance, met: 8.5, symbol: "figure.outdoor.cycle", imageId: nil),
        .init("Swimming", "cardio", .durationDistance, met: 6.0, symbol: "figure.pool.swim", imageId: nil, popular: true),
        .init("Open Water Swimming", "cardio", .durationDistance, met: 7.0, symbol: "figure.open.water.swim", imageId: nil),
        .init("Rowing Machine", "cardio", .durationDistance, met: 7.0, symbol: "figure.indoor.rowing", imageId: "Rowing_Stationary"),
        .init("Rowing", "cardio", .durationDistance, met: 5.8, symbol: "figure.outdoor.rowing", imageId: nil),
        .init("Elliptical", "cardio", .durationDistance, met: 5.0, symbol: "figure.elliptical", imageId: "Elliptical_Trainer", popular: true),
        .init("Stair Climber", "cardio", .duration, met: 9.0, symbol: "figure.stair.stepper", imageId: "Stairmaster"),
        .init("Stair Climbing", "cardio", .duration, met: 8.0, symbol: "figure.stairs", imageId: "Step_Mill"),
        .init("Step Aerobics", "cardio", .duration, met: 7.0, symbol: "figure.step.training", imageId: nil),
        .init("Jump Rope", "cardio", .duration, met: 11.8, symbol: "figure.jumprope", imageId: "Rope_Jumping"),
        .init("Skating", "cardio", .durationDistance, met: 7.0, symbol: "figure.skating", imageId: "Skating"),
        .init("Mixed Cardio", "cardio", .duration, met: 7.0, symbol: "figure.mixed.cardio", imageId: nil),
        .init("Sprints", "cardio", .durationDistance, met: 11.0, symbol: "figure.run", imageId: "Prowler_Sprint"),
        .init("HIIT", "cardio", .duration, met: 8.0, symbol: "figure.highintensity.intervaltraining", imageId: nil, popular: true),
        .init("Circuit Training", "cardio", .duration, met: 8.0, symbol: "figure.cross.training", imageId: nil),
        .init("Aerobics", "cardio", .duration, met: 6.8, symbol: "figure.mixed.cardio", imageId: nil),
        .init("Dance Workout", "cardio", .duration, met: 5.5, symbol: "figure.dance", imageId: nil),
        .init("Battle Ropes", "cardio", .duration, met: 10.3, symbol: "figure.cross.training", imageId: "Battling_Ropes"),
        .init("Hand Cycling", "cardio", .durationDistance, met: 6.0, symbol: "figure.hand.cycling", imageId: nil),
        .init("Cross-Country Skiing", "cardio", .durationDistance, met: 9.0, symbol: "figure.skiing.crosscountry", imageId: nil),
        .init("Yoga", "flexibility", .duration, met: 2.5, symbol: "figure.yoga", imageId: nil, popular: true),
        .init("Power Yoga", "flexibility", .duration, met: 4.0, symbol: "figure.yoga", imageId: nil),
        .init("Pilates", "flexibility", .duration, met: 3.0, symbol: "figure.pilates", imageId: nil),
        .init("Stretching", "flexibility", .duration, met: 2.3, symbol: "figure.flexibility", imageId: nil),
        .init("Barre", "flexibility", .duration, met: 3.5, symbol: "figure.barre", imageId: nil),
        .init("Tai Chi", "flexibility", .duration, met: 3.0, symbol: "figure.taichi", imageId: nil),
        .init("Cooldown", "flexibility", .duration, met: 2.5, symbol: "figure.cooldown", imageId: nil),
        .init("Mind & Body", "flexibility", .duration, met: 2.0, symbol: "figure.mind.and.body", imageId: nil),
        .init("Strength Training", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: nil, popular: true),
        .init("Functional Strength Training", "strength", .duration, met: 5.0, symbol: "figure.strengthtraining.functional", imageId: nil),
        .init("Core Training", "strength", .duration, met: 3.8, symbol: "figure.core.training", imageId: nil),
        .init("Bench Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Barbell_Bench_Press_-_Medium_Grip", popular: true),
        .init("Incline Bench Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Barbell_Incline_Bench_Press_-_Medium_Grip"),
        .init("Decline Bench Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Decline_Barbell_Bench_Press"),
        .init("Close-Grip Bench Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Close-Grip_Barbell_Bench_Press"),
        .init("Dumbbell Bench Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Dumbbell_Bench_Press"),
        .init("Incline Dumbbell Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Incline_Dumbbell_Press"),
        .init("Chest Press Machine", "strength", .weightReps, met: 4.0, symbol: "figure.strengthtraining.traditional", imageId: "Leverage_Chest_Press"),
        .init("Chest Fly", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Dumbbell_Flyes"),
        .init("Cable Crossover", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Cable_Crossover"),
        .init("Pec Deck", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Butterfly"),
        .init("Squat", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Barbell_Full_Squat", popular: true),
        .init("Front Squat", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Front_Barbell_Squat"),
        .init("Goblet Squat", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.functional", imageId: "Goblet_Squat"),
        .init("Dumbbell Squat", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.functional", imageId: "Dumbbell_Squat"),
        .init("Hack Squat", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Hack_Squat"),
        .init("Smith Machine Squat", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Smith_Machine_Squat"),
        .init("Bodyweight Squat", "strength", .repsOnly, met: 5.0, symbol: "figure.strengthtraining.functional", imageId: "Bodyweight_Squat"),
        .init("Jump Squat", "strength", .repsOnly, met: 8.0, symbol: "figure.highintensity.intervaltraining", imageId: "Freehand_Jump_Squat"),
        .init("Deadlift", "strength", .weightReps, met: 6.0, symbol: "figure.strengthtraining.traditional", imageId: "Barbell_Deadlift", popular: true),
        .init("Romanian Deadlift", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Romanian_Deadlift"),
        .init("Sumo Deadlift", "strength", .weightReps, met: 6.0, symbol: "figure.strengthtraining.traditional", imageId: "Sumo_Deadlift"),
        .init("Good Morning", "strength", .weightReps, met: 4.0, symbol: "figure.strengthtraining.traditional", imageId: "Good_Morning"),
        .init("Leg Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Leg_Press", popular: true),
        .init("Leg Extension", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Leg_Extensions"),
        .init("Seated Leg Curl", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Seated_Leg_Curl"),
        .init("Lying Leg Curl", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Lying_Leg_Curls"),
        .init("Lunges", "strength", .weightReps, met: 4.0, symbol: "figure.strengthtraining.functional", imageId: "Dumbbell_Lunges"),
        .init("Walking Lunges", "strength", .repsOnly, met: 4.0, symbol: "figure.strengthtraining.functional", imageId: "Bodyweight_Walking_Lunge"),
        .init("Split Squat", "strength", .weightReps, met: 4.0, symbol: "figure.strengthtraining.functional", imageId: "Split_Squat_with_Dumbbells"),
        .init("Step-Ups", "strength", .weightReps, met: 4.0, symbol: "figure.step.training", imageId: "Dumbbell_Step_Ups"),
        .init("Hip Thrust", "strength", .weightReps, met: 4.0, symbol: "figure.strengthtraining.traditional", imageId: "Barbell_Hip_Thrust"),
        .init("Glute Bridge", "strength", .repsOnly, met: 3.5, symbol: "figure.core.training", imageId: "Barbell_Glute_Bridge"),
        .init("Standing Calf Raise", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Standing_Calf_Raises"),
        .init("Seated Calf Raise", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Seated_Calf_Raise"),
        .init("Hip Adduction Machine", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Thigh_Adductor"),
        .init("Hip Abduction Machine", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Thigh_Abductor"),
        .init("Overhead Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Standing_Military_Press"),
        .init("Barbell Shoulder Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Barbell_Shoulder_Press"),
        .init("Dumbbell Shoulder Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Dumbbell_Shoulder_Press", popular: true),
        .init("Arnold Press", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Arnold_Dumbbell_Press"),
        .init("Lateral Raise", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Side_Lateral_Raise"),
        .init("Front Raise", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Front_Dumbbell_Raise"),
        .init("Rear Delt Fly", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Reverse_Flyes"),
        .init("Face Pull", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Face_Pull"),
        .init("Upright Row", "strength", .weightReps, met: 4.0, symbol: "figure.strengthtraining.traditional", imageId: "Upright_Barbell_Row"),
        .init("Shrugs", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Barbell_Shrug"),
        .init("Pull-Ups", "strength", .repsOnly, met: 8.0, symbol: "figure.strengthtraining.functional", imageId: "Pullups", popular: true),
        .init("Chin-Ups", "strength", .repsOnly, met: 8.0, symbol: "figure.strengthtraining.functional", imageId: "Chin-Up"),
        .init("Weighted Pull-Ups", "strength", .weightReps, met: 8.0, symbol: "figure.strengthtraining.functional", imageId: "Weighted_Pull_Ups"),
        .init("Lat Pulldown", "strength", .weightReps, met: 4.0, symbol: "figure.strengthtraining.traditional", imageId: "Wide-Grip_Lat_Pulldown", popular: true),
        .init("Straight-Arm Pulldown", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Straight-Arm_Pulldown"),
        .init("Barbell Row", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "Bent_Over_Barbell_Row"),
        .init("Dumbbell Row", "strength", .weightReps, met: 4.5, symbol: "figure.strengthtraining.traditional", imageId: "One-Arm_Dumbbell_Row"),
        .init("Seated Cable Row", "strength", .weightReps, met: 4.0, symbol: "figure.strengthtraining.traditional", imageId: "Seated_Cable_Rows"),
        .init("T-Bar Row", "strength", .weightReps, met: 5.0, symbol: "figure.strengthtraining.traditional", imageId: "T-Bar_Row_with_Handle"),
        .init("Inverted Row", "strength", .repsOnly, met: 5.0, symbol: "figure.strengthtraining.functional", imageId: "Inverted_Row"),
        .init("Barbell Curl", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Barbell_Curl"),
        .init("Dumbbell Curl", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Dumbbell_Bicep_Curl", popular: true),
        .init("Hammer Curl", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Hammer_Curls"),
        .init("Preacher Curl", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Preacher_Curl"),
        .init("Concentration Curl", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Concentration_Curls"),
        .init("Triceps Pushdown", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Triceps_Pushdown"),
        .init("Skull Crusher", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "EZ-Bar_Skullcrusher"),
        .init("Overhead Triceps Extension", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Standing_Overhead_Barbell_Triceps_Extension"),
        .init("Triceps Kickback", "strength", .weightReps, met: 3.5, symbol: "figure.strengthtraining.traditional", imageId: "Tricep_Dumbbell_Kickback"),
        .init("Dips", "strength", .repsOnly, met: 8.0, symbol: "figure.strengthtraining.functional", imageId: "Dips_-_Triceps_Version"),
        .init("Push-Ups", "strength", .repsOnly, met: 8.0, symbol: "figure.strengthtraining.functional", imageId: "Pushups", popular: true),
        .init("Handstand Push-Ups", "strength", .repsOnly, met: 8.0, symbol: "figure.gymnastics", imageId: "Handstand_Push-Ups"),
        .init("Plank", "strength", .duration, met: 3.8, symbol: "figure.core.training", imageId: "Plank", popular: true),
        .init("Side Plank", "strength", .duration, met: 3.8, symbol: "figure.core.training", imageId: "Side_Bridge"),
        .init("Crunches", "strength", .repsOnly, met: 3.8, symbol: "figure.core.training", imageId: "Crunches"),
        .init("Sit-Ups", "strength", .repsOnly, met: 3.8, symbol: "figure.core.training", imageId: "Sit-Up"),
        .init("Cable Crunch", "strength", .weightReps, met: 3.8, symbol: "figure.core.training", imageId: "Cable_Crunch"),
        .init("Russian Twist", "strength", .repsOnly, met: 3.8, symbol: "figure.core.training", imageId: "Russian_Twist"),
        .init("Hanging Leg Raise", "strength", .repsOnly, met: 4.0, symbol: "figure.core.training", imageId: "Hanging_Leg_Raise"),
        .init("Flutter Kicks", "strength", .repsOnly, met: 3.8, symbol: "figure.core.training", imageId: "Flutter_Kicks"),
        .init("Ab Wheel Rollout", "strength", .repsOnly, met: 4.0, symbol: "figure.core.training", imageId: "Ab_Roller"),
        .init("Mountain Climbers", "strength", .duration, met: 8.0, symbol: "figure.highintensity.intervaltraining", imageId: "Mountain_Climbers"),
        .init("Burpees", "cardio", .repsOnly, met: 8.0, symbol: "figure.highintensity.intervaltraining", imageId: nil, popular: true),
        .init("Jumping Jacks", "cardio", .duration, met: 7.7, symbol: "figure.mixed.cardio", imageId: nil),
        .init("Box Jumps", "strength", .repsOnly, met: 8.0, symbol: "figure.highintensity.intervaltraining", imageId: "Box_Jump_Multiple_Response"),
        .init("Kettlebell Swing", "strength", .weightReps, met: 9.8, symbol: "figure.strengthtraining.functional", imageId: "One-Arm_Kettlebell_Swings"),
        .init("Kettlebell Thruster", "strength", .weightReps, met: 8.0, symbol: "figure.strengthtraining.functional", imageId: "Kettlebell_Thruster"),
        .init("Medicine Ball Slam", "strength", .repsOnly, met: 8.0, symbol: "figure.strengthtraining.functional", imageId: "Overhead_Slam"),
        .init("Farmer's Walk", "strength", .duration, met: 6.0, symbol: "figure.strengthtraining.functional", imageId: "Farmers_Walk"),
        .init("Sled Push", "strength", .duration, met: 8.0, symbol: "figure.strengthtraining.functional", imageId: "Sled_Push"),
        .init("Power Clean", "strength", .weightReps, met: 6.0, symbol: "figure.strengthtraining.traditional", imageId: "Power_Clean"),
        .init("Clean and Jerk", "strength", .weightReps, met: 6.0, symbol: "figure.strengthtraining.traditional", imageId: "Clean_and_Jerk"),
        .init("Snatch", "strength", .weightReps, met: 6.0, symbol: "figure.strengthtraining.traditional", imageId: "Snatch"),
        .init("Superman", "strength", .repsOnly, met: 3.0, symbol: "figure.core.training", imageId: "Superman"),
        .init("Basketball", "sports", .duration, met: 6.5, symbol: "figure.basketball", imageId: nil),
        .init("Soccer", "sports", .duration, met: 7.0, symbol: "figure.soccer", imageId: nil),
        .init("Tennis", "sports", .duration, met: 7.3, symbol: "figure.tennis", imageId: nil),
        .init("Badminton", "sports", .duration, met: 5.5, symbol: "figure.badminton", imageId: nil),
        .init("Cricket", "sports", .duration, met: 4.8, symbol: "figure.cricket", imageId: nil),
        .init("Volleyball", "sports", .duration, met: 4.0, symbol: "figure.volleyball", imageId: nil),
        .init("Table Tennis", "sports", .duration, met: 4.0, symbol: "figure.table.tennis", imageId: nil),
        .init("Squash", "sports", .duration, met: 7.3, symbol: "figure.squash", imageId: nil),
        .init("Pickleball", "sports", .duration, met: 4.1, symbol: "figure.pickleball", imageId: nil),
        .init("Golf", "sports", .duration, met: 4.8, symbol: "figure.golf", imageId: nil),
        .init("Baseball", "sports", .duration, met: 5.0, symbol: "figure.baseball", imageId: nil),
        .init("Hockey", "sports", .duration, met: 8.0, symbol: "figure.hockey", imageId: nil),
        .init("Rugby", "sports", .duration, met: 8.3, symbol: "figure.rugby", imageId: nil),
        .init("American Football", "sports", .duration, met: 8.0, symbol: "figure.american.football", imageId: nil),
        .init("Climbing", "sports", .duration, met: 8.0, symbol: "figure.climbing", imageId: nil),
        .init("Boxing", "sports", .duration, met: 7.8, symbol: "figure.boxing", imageId: nil),
        .init("Kickboxing", "sports", .duration, met: 7.3, symbol: "figure.kickboxing", imageId: nil),
        .init("Martial Arts", "sports", .duration, met: 7.5, symbol: "figure.martial.arts", imageId: nil),
        .init("Wrestling", "sports", .duration, met: 6.0, symbol: "figure.wrestling", imageId: nil),
        .init("Surfing", "sports", .duration, met: 3.0, symbol: "figure.surfing", imageId: nil),
        .init("Snowboarding", "sports", .duration, met: 5.3, symbol: "figure.snowboarding", imageId: nil),
        .init("Downhill Skiing", "sports", .duration, met: 5.3, symbol: "figure.skiing.downhill", imageId: nil),
        .init("Bowling", "sports", .duration, met: 3.8, symbol: "figure.bowling", imageId: nil),
        .init("Gymnastics", "sports", .duration, met: 3.8, symbol: "figure.gymnastics", imageId: nil),
        .init("Workout", "cardio", .duration, met: 5.0, symbol: "figure.mixed.cardio", imageId: nil),
    ]
}

extension APIClientProtocol {
    /// The user's own library exercise for a catalog entry — reused when one
    /// already exists under the same name, so picking (or importing)
    /// "Running" twice doesn't create two Runnings.
    func libraryExercise(for entry: CatalogExercise) async throws -> Exercise {
        let key = ExerciseCatalog.normalized(entry.name)
        if let existing = try await searchExercises(query: entry.name)
            .first(where: { ExerciseCatalog.normalized($0.name) == key }) {
            return existing
        }
        return try await createCustomExercise(
            CustomExerciseInput(name: entry.name, category: entry.category, modality: entry.modality)
        )
    }
}

// MARK: - Browsing

/// The filter row above Log Exercise's lists — the catalog's own four
/// kinds, so 150-odd exercises can be browsed without knowing a name to
/// type.
enum ExerciseCategoryFilter: String, CaseIterable, Identifiable {
    case all, strength, cardio, flexibility, sports

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .strength: return "Strength"
        case .cardio: return "Cardio"
        case .flexibility: return "Flexibility"
        case .sports: return "Sports"
        }
    }

    /// Library and provider categories are free text ("Strength",
    /// "strength", "Other"), so this compares loosely; anything that isn't
    /// one of the four only shows under All.
    func matches(_ category: String?) -> Bool {
        self == .all || category?.lowercased() == rawValue
    }
}

extension ExerciseCatalog {
    /// What to browse for a filter: Popular for All, otherwise the whole
    /// category with its popular entries first. Built once per filter.
    static func browse(_ filter: ExerciseCategoryFilter) -> [CatalogExercise] {
        browseLists[filter] ?? []
    }

    private static let browseLists: [ExerciseCategoryFilter: [CatalogExercise]] = {
        var lists: [ExerciseCategoryFilter: [CatalogExercise]] = [.all: popular]
        for filter in ExerciseCategoryFilter.allCases where filter != .all {
            let entries = all.filter { $0.category == filter.rawValue }
            lists[filter] = entries.filter(\.popular) + entries.filter { !$0.popular }
        }
        return lists
    }()

    /// A middle-of-the-range MET for an exercise the catalog doesn't know —
    /// a custom one, or a provider's — so its calories start from a
    /// labelled estimate the user can correct, instead of a required blank
    /// that blocked Save. Compendium "general" codes for each kind.
    static func fallbackMET(category: String?, modality: ExerciseModality?) -> Double {
        switch category?.lowercased() {
        case "strength": return 5.0
        case "cardio": return 7.0
        case "flexibility": return 2.5
        case "sports": return 6.0
        default: break
        }
        switch modality {
        case .durationDistance: return 7.0
        case .duration: return 4.0
        case .weightReps, .repsOnly, nil: return 5.0
        }
    }

    /// The glyph for any exercise: the catalog's own where it knows the
    /// name, otherwise a generic one for its kind.
    static func symbol(name: String, category: String?) -> String {
        if let entry = entry(named: name) { return entry.symbol }
        switch category?.lowercased() {
        case "cardio": return "figure.mixed.cardio"
        case "flexibility": return "figure.flexibility"
        case "sports": return "sportscourt"
        default: return "figure.strengthtraining.traditional"
        }
    }
}
