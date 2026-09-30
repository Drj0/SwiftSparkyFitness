//
//  IndianFoodDB.swift
//  SwiftSparkyFitness
//
//  Indian Nutrient Databank (INDB, Anuvaad Solutions, 2024.11): ~930 cooked
//  Indian dishes — roti, dal, idli, poha, biryani — which neither USDA nor
//  Open Food Facts covers. Bundled as Resources/indb.json (110 KB, built by
//  tools/indb_to_json.py), so it answers instantly, offline, in both modes.
//
//  Values are per household unit ("1 chapati", "1 bowl"), never per gram:
//  INDB's per-100g figures are on raw-ingredient weight with no cooking yield
//  factor, so grams of the cooked dish would read high (dosa 381 kcal/100g).
//

import Foundation

actor IndianFoodDB {
    static let shared = IndianFoodDB()

    nonisolated struct Row: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let unit: String
        let kcal: Double
        let protein: Double
        let carbs: Double
        let fat: Double
    }

    /// Each row with its words and squashed words precomputed, so a keystroke
    /// scans ~930 small arrays instead of re-tokenising every name.
    private struct Indexed {
        let row: Row
        let words: [String]
        let squashed: [String]
    }

    private let source: @Sendable () throws -> [Row]
    private var index: [Indexed]?

    init(source: @escaping @Sendable () throws -> [Row] = IndianFoodDB.bundled) {
        self.source = source
    }

    nonisolated static func bundled() throws -> [Row] {
        guard let url = Bundle.main.url(forResource: "indb", withExtension: "json") else { return [] }
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
    }

    /// Loads the dataset ahead of the first keystroke (a few ms, once).
    func prepare() {
        _ = loaded()
    }

    /// Every row whose name contains each query word as the start of a word,
    /// directly or after spelling squash — "dal" finds "Moong dal", "chana"
    /// finds "channa", and "lassi" doesn't find "classic". In dataset order;
    /// FoodSearchRanker orders them.
    func search(_ query: String) -> [Row] {
        let queryWords = FoodSearchText.words(query)
        guard !queryWords.isEmpty else { return [] }
        let squashedQuery = queryWords.map(FoodSearchText.squash)
        return loaded().filter { entry in
            queryWords.allSatisfy { q in entry.words.contains { $0.hasPrefix(q) } }
                || squashedQuery.allSatisfy { q in entry.squashed.contains { $0.hasPrefix(q) } }
        }.map(\.row)
    }

    private func loaded() -> [Indexed] {
        if let index { return index }
        let rows = (try? source()) ?? []
        let built = rows.map { row in
            let words = FoodSearchText.words(row.name)
            return Indexed(row: row, words: words, squashed: words.map(FoodSearchText.squash))
        }
        index = built
        return built
    }
}

extension IndianFoodDB.Row {
    var asFood: Food {
        Food(
            id: "indb-\(id)",
            name: name,
            brand: nil,
            defaultVariant: FoodVariant(
                id: "indb-variant-\(id)",
                servingSize: 1, servingUnit: unit,
                calories: kcal, protein: protein, carbs: carbs, fat: fat
            ),
            source: .indb
        )
    }
}
