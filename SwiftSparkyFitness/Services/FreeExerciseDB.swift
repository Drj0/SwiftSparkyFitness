//
//  FreeExerciseDB.swift
//  SwiftSparkyFitness
//
//  Free Exercise DB (github.com/yuhonas/free-exercise-db, public domain):
//  ~870 exercises with instructions and two photos each. The server already
//  searches it; this gives local mode the same list, and gives both modes a
//  name → photo lookup.
//
//  The whole dataset is one ~1 MB JSON file, so it's fetched once, kept in
//  Caches, and searched in memory — no per-keystroke requests to a host that
//  never asked to be an API.
//

import Foundation

actor FreeExerciseDB {
    static let shared = FreeExerciseDB()

    private static let base = URL(string: "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/")!
    private static let datasetURL = base.appending(path: "dist/exercises.json")

    struct Entry: Decodable {
        let id: String
        let name: String
        let category: String?
        let equipment: String?
        let force: String?
        let level: String?
        let mechanic: String?
        let primaryMuscles: [String]
        let secondaryMuscles: [String]
        let instructions: [String]
        let images: [String]
    }

    private var entries: [Entry]?
    private var byName: [String: Entry] = [:]
    private var loading: Task<[Entry], Error>?

    private var cacheFile: URL {
        URL.cachesDirectory.appending(path: "free-exercise-db.json")
    }

    /// Photo for an exercise folder, e.g. "Barbell_Full_Squat" → …/0.jpg.
    nonisolated static func imageURL(imageId: String, index: Int = 0) -> URL {
        base.appending(path: "exercises/\(imageId)/\(index).jpg")
    }

    /// Catalog first (it's in the binary, so this works offline and before
    /// the dataset has ever loaded), then the dataset by name.
    func imageId(forName name: String) async -> String? {
        if let id = ExerciseCatalog.entry(named: name)?.imageId { return id }
        _ = try? await load()
        return byName[ExerciseCatalog.normalized(name)]?.id
    }

    func search(_ query: String, limit: Int = 25) async throws -> [ExternalExerciseResult] {
        let needle = ExerciseCatalog.normalized(query)
        guard !needle.isEmpty else { return [] }
        let hits = try await load().filter { ExerciseCatalog.normalized($0.name).contains(needle) }
        return hits.prefix(limit).map(Self.result)
    }

    private func load() async throws -> [Entry] {
        if let entries { return entries }
        if let loading { return try await loading.value }
        let file = cacheFile
        let task = Task<[Entry], Error> {
            if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([Entry].self, from: data) {
                return cached
            }
            let (data, response) = try await URLSession.shared.data(from: Self.datasetURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.invalidResponse }
            let decoded = try JSONDecoder().decode([Entry].self, from: data)
            try? data.write(to: file, options: .atomic)
            return decoded
        }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        entries = loaded
        byName = Dictionary(loaded.map { (ExerciseCatalog.normalized($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        return loaded
    }

    /// Free Exercise DB has no modality, so it's inferred: cardio logs time
    /// and distance, stretches log time, and strength logs sets — with
    /// weight unless it's bodyweight-only.
    private static func result(_ entry: Entry) -> ExternalExerciseResult {
        let modality: ExerciseModality
        switch entry.category {
        case "cardio": modality = .durationDistance
        case "stretching": modality = .duration
        default: modality = entry.equipment == "body only" ? .repsOnly : .weightReps
        }
        return ExternalExerciseResult(
            id: entry.id, name: entry.name, category: entry.category, modality: modality,
            caloriesPerHour: nil, source: "free-exercise-db",
            force: entry.force, level: entry.level, mechanic: entry.mechanic,
            equipment: entry.equipment.map { [$0] } ?? [],
            primaryMuscles: entry.primaryMuscles, secondaryMuscles: entry.secondaryMuscles,
            instructions: entry.instructions, images: entry.images
        )
    }
}
