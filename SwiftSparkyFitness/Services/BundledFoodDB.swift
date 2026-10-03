//
//  BundledFoodDB.swift
//  SwiftSparkyFitness
//
//  The food datasets shipped inside the app, so they answer instantly,
//  offline, in both modes:
//
//  - `.indian` — Indian Nutrient Databank (INDB, Anuvaad Solutions,
//    2024.11): ~730 cooked Indian dishes — roti, dal, idli, poha, biryani —
//    which neither USDA nor Open Food Facts covers. Resources/indb.json
//    (built by tools/indb_to_json.py).
//  - `.everyday` — USDA FNDDS 2021-2023 survey foods: ~5,200 everyday basics
//    INDB doesn't have, because it holds only recipes — a slice of bread, a
//    banana, a cup of milk, an egg, a chicken breast. Resources/fndds.json
//    (built by tools/fndds_to_json.py). Public domain; source: USDA
//    FoodData Central. Listed as USDA, under the same ids as the server's
//    USDA search, so the two never show the same food twice.
//
//  Values are per household unit ("1 chapati", "1 slice", "1 banana"):
//  INDB's per-100g figures are on raw-ingredient weight with no cooking
//  yield factor, so grams of the cooked dish would read high (dosa 381
//  kcal/100g). An FNDDS food with no household portion near its usual amount
//  is in grams instead (`size`).
//

import Foundation

actor BundledFoodDB {
    static let indian = BundledFoodDB(source: .indb, rows: { try bundled("indb") })
    static let everyday = BundledFoodDB(source: .usda, rows: { try bundled("fndds") })

    nonisolated struct Row: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let unit: String
        let kcal: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        /// How many `unit`s the values are for: 1 for a household unit, the
        /// usual amount for a food in grams ("123 g" of paneer).
        var size: Double? = nil
    }

    /// Each row with its words and squashed words precomputed, so a keystroke
    /// scans small arrays instead of re-tokenising every name.
    private struct Indexed {
        let row: Row
        let words: [String]
        let squashed: [String]
    }

    nonisolated let source: FoodSource
    private let rows: @Sendable () throws -> [Row]
    private var index: [Indexed]?

    init(source: FoodSource = .indb, rows: @escaping @Sendable () throws -> [Row]) {
        self.source = source
        self.rows = rows
    }

    nonisolated static func bundled(_ resource: String) throws -> [Row] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else { return [] }
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
    }

    /// Loads the dataset ahead of the first keystroke (a few ms, once).
    func prepare() {
        _ = loaded()
    }

    /// `search`, as foods from this dataset's source.
    func foods(matching query: String) -> [Food] {
        search(query).map { $0.food(source: source) }
    }

    /// Every row whose name contains each query word as the start of a word —
    /// directly, after spelling squash, or as a synonym ("dahi" finds Curd
    /// rice, "chole" Chickpeas curry) — so "dal" finds "Moong dal", "chana"
    /// finds "channa", and "lassi" doesn't find "classic". When nothing
    /// does, the same with one typo allowed per long word ("omlette"). In
    /// dataset order; FoodSearchRanker orders them.
    func search(_ query: String) -> [Row] {
        let queryWords = FoodSearchText.words(query)
        guard !queryWords.isEmpty else { return [] }
        // Per query word, every form that counts as it: itself and its
        // synonyms, plain and squashed.
        let forms = queryWords.map { FoodSearchText.synonyms(of: $0) }
        let squashedForms = forms.map { $0.map(FoodSearchText.squash) }
        func holds(_ entry: Indexed, _ index: Int, typo: Bool = false) -> Bool {
            if forms[index].contains(where: { q in entry.words.contains { $0.hasPrefix(q) } }) { return true }
            if squashedForms[index].contains(where: { q in entry.squashed.contains { $0.hasPrefix(q) } }) { return true }
            return typo && entry.words.contains { FoodSearchText.isOneTypoAway($0, queryWords[index]) }
        }
        let all = loaded()
        let full = all.filter { entry in queryWords.indices.allSatisfy { holds(entry, $0) } }
        if !full.isEmpty { return full.map(\.row) }
        let typos = all.filter { entry in queryWords.indices.allSatisfy { holds(entry, $0, typo: true) } }
        guard typos.isEmpty, queryWords.count > 1 else { return typos.map(\.row) }
        // Nothing holds every word ("paneer butter masala"): the dishes that
        // hold all but one, for the ranker to offer as closest matches.
        let needed = queryWords.count - 1
        return all.filter { entry in
            var held = 0
            for index in queryWords.indices where holds(entry, index, typo: true) {
                held += 1
                if held >= needed { return true }
            }
            return false
        }.map(\.row)
    }

    private func loaded() -> [Indexed] {
        if let index { return index }
        let rows = (try? rows()) ?? []
        let built = rows.map { row in
            let words = FoodSearchText.words(row.name)
            return Indexed(row: row, words: words, squashed: words.map(FoodSearchText.squash))
        }
        index = built
        return built
    }
}

extension BundledFoodDB.Row {
    /// As an INDB dish.
    nonisolated var asFood: Food { food(source: .indb) }

    nonisolated func food(source: FoodSource) -> Food {
        // USDA's prefix is the server search's own, so a food found both
        // ways is one food.
        let prefix = source == .usda ? "usda" : "indb"
        return Food(
            id: "\(prefix)-\(id)",
            name: name,
            brand: nil,
            defaultVariant: FoodVariant(
                id: "\(prefix)-variant-\(id)",
                servingSize: size ?? 1, servingUnit: unit,
                calories: kcal, protein: protein, carbs: carbs, fat: fat
            ),
            source: source
        )
    }
}
