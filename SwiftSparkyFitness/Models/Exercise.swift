//
//  Exercise.swift
//  SwiftSparkyFitness
//
//  A materialized exercise in the user's own library — what
//  `exercise_entries.exercise_id` actually FKs to. External search results
//  (Free Exercise DB, Wger) are a different, lighter type (see
//  ExternalExerciseResult) because they aren't loggable until materialized;
//  see APIClient.materializeExternalExercise.
//
//  `modality` (not `category`, which is free text) is the real taxonomy —
//  CHECK-constrained server-side to exactly four values — and is what the
//  logging form branches its set editor on. Verified live against the
//  running server on 2026-09-26, not assumed from the OpenAPI doc.
//

import Foundation

/// weight_reps → per-set reps + weight; reps_only → per-set reps alone;
/// duration → a single elapsed-time field; duration_distance → duration +
/// distance (cardio). Server CHECK-constrained to exactly these four values.
enum ExerciseModality: String, Codable, CaseIterable {
    // Explicit snake_case raw values: a String-backed enum's Decodable
    // conformance matches the JSON *value* against `rawValue` directly —
    // `keyDecodingStrategy` only ever rewrites object *keys*, never a
    // string payload like this one, so an implicit camelCase rawValue
    // would fail to decode the server's actual "weight_reps" etc.
    case weightReps = "weight_reps"
    case repsOnly = "reps_only"
    case duration = "duration"
    case durationDistance = "duration_distance"

    var label: String {
        switch self {
        case .weightReps: return "Sets & reps"
        case .repsOnly: return "Reps only"
        case .duration: return "Duration"
        case .durationDistance: return "Duration & distance"
        }
    }

    /// True for the two modalities that log a list of individual sets
    /// (`exercise_entry_sets`) rather than one flat duration/distance figure.
    var usesSets: Bool { self == .weightReps || self == .repsOnly }
}

struct Exercise: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String?
    let modality: ExerciseModality?
    let caloriesPerHour: Double?
    let equipment: [String]
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let instructions: [String]
    let source: String?
    let isCustom: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, category, modality
        case caloriesPerHour, equipment, primaryMuscles, secondaryMuscles, instructions, source, isCustom
    }

    /// A plain memberwise initializer alongside the custom `Decodable` one —
    /// needed because the lenient array decode above requires writing
    /// `init(from:)` by hand, which suppresses Swift's usual free
    /// memberwise init. Used by previews, tests, and `LocalAPIClient`.
    init(
        id: String, name: String, category: String? = nil, modality: ExerciseModality? = nil,
        caloriesPerHour: Double? = nil, equipment: [String] = [], primaryMuscles: [String] = [],
        secondaryMuscles: [String] = [], instructions: [String] = [], source: String? = nil, isCustom: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.modality = modality
        self.caloriesPerHour = caloriesPerHour
        self.equipment = equipment
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.instructions = instructions
        self.source = source
        self.isCustom = isCustom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        modality = try c.decodeIfPresent(ExerciseModality.self, forKey: .modality)
        caloriesPerHour = try c.decodeIfPresent(Double.self, forKey: .caloriesPerHour)
        equipment = Self.lenientStringArray(c, .equipment)
        primaryMuscles = Self.lenientStringArray(c, .primaryMuscles)
        secondaryMuscles = Self.lenientStringArray(c, .secondaryMuscles)
        instructions = Self.lenientStringArray(c, .instructions)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom)
    }

    /// `POST /api/freeexercisedb/add` — verified live, and only that
    /// endpoint — returns these four fields JSON-stringified instead of as
    /// real arrays; every other exercise-list endpoint (`/api/exercises`,
    /// `/api/exercises/search`, `/api/exercises/recent`) returns real
    /// arrays. The same "sometimes a string, sometimes the real thing"
    /// inconsistency Module 2 found in OpenFoodFacts. Try the real shape
    /// first so this costs nothing on the common path.
    private static func lenientStringArray(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String] {
        if let array = try? container.decode([String].self, forKey: key) { return array }
        if let string = try? container.decode(String.self, forKey: key),
           let data = string.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            return array
        }
        return []
    }
}

/// One `exercise_entry_sets` row — reps/weight for strength, or just reps,
/// per `ExerciseModality`. Decoded from a create/update/read response;
/// `ExerciseSetInput` (below) is the lighter shape sent back up.
struct ExerciseSet: Decodable, Identifiable, Equatable {
    let id: Int?
    let setNumber: Int
    let setType: String?
    let reps: Int?
    let weight: Double?
    let duration: Double?
    let restTime: Double?
    let notes: String?
    let rpe: Double?
    let isPr: Bool?
    let distance: Double?
}

/// What the app actually sends when logging a set — no `id`/`isPr`, which
/// only the server ever produces. Also `Decodable` so local (server-less)
/// mode can round-trip a day's sets through its own flat JSON column — see
/// `LocalExerciseEntry.setsJSON`.
struct ExerciseSetInput: Codable, Equatable {
    var setNumber: Int
    var setType: String = "Working Set"
    var reps: Int?
    var weight: Double?
    var rpe: Double?
    var notes: String?
}

/// What the diary remembers about one exercise: the session logged most
/// recently, so the next one can start from it instead of from blank —
/// most sessions repeat the last one, give or take a rep or a kilo.
///
/// Keyed by name (`key`), not exercise id: server mode copies library
/// exercises under local keys, and one exercise can reach the library from
/// the catalog, a provider or the user under three different ids.
struct ExerciseLastSession: Equatable {
    let date: Date
    let modality: ExerciseModality?
    let durationMinutes: Double
    let caloriesBurned: Double
    let distance: Double?
    let sets: [ExerciseSetInput]
    /// Sessions of this exercise in the last 7 days, this one included.
    var timesThisWeek: Int

    static func key(_ name: String) -> String { ExerciseCatalog.normalized(name) }
}

/// A search-external hit (Free Exercise DB / Wger) — not yet in the user's
/// own library. `id` is the *provider's* id (e.g. a Free Exercise DB slug),
/// not a local exercise id, and cannot be logged against directly:
/// `exercise_entries.exercise_id` FKs to the user's own `exercises` table.
/// Materialize first via `APIClient.materializeExternalExercise`.
struct ExternalExerciseResult: Decodable, Identifiable {
    let id: String
    let name: String
    let category: String?
    let modality: ExerciseModality?
    let caloriesPerHour: Double?
    /// Provider type string ("free-exercise-db" | "wger" | ...) — which
    /// materialize call to make is looked up from this, not guessed.
    let source: String
    let force: String?
    let level: String?
    let mechanic: String?
    let equipment: [String]
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let instructions: [String]
    let images: [String]
}

/// What `POST /api/exercises/` (catalog creation — the multipart endpoint)
/// accepts inside its `exerciseData` field. `source: "manual"` is required;
/// omitting it is a 500 ("null value in column \"source\"") — verified live.
#if DEBUG
extension Exercise {
    static let previewSquat = Exercise(id: "preview-squat", name: "Barbell Full Squat", category: "strength", modality: .weightReps, caloriesPerHour: 368)
    static let previewRun = Exercise(id: "preview-run", name: "Running, Treadmill", category: "cardio", modality: .durationDistance, caloriesPerHour: 590)
}
#endif

struct CustomExerciseInput: Encodable {
    let name: String
    let category: String
    let modality: ExerciseModality
    let source = "manual"
    var equipment: [String] = []
    var muscleGroups: [String] = []
    var description: String?
    var instructions: [String] = []
    var isPublic = false
}
