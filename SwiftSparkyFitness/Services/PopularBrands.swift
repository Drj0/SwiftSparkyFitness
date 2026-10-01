//
//  PopularBrands.swift
//  SwiftSparkyFitness
//
//  The packaged-food brands most Indian households actually buy, as a light
//  prior for FoodSearchRanker. Open Food Facts orders equally good matches by
//  its own relevance, which knows nothing about reach: "curd" listed
//  Akshayakalpa above Amul. Among products whose names match the query
//  equally well, these come first; a better name match always still wins,
//  and the user's own history (FoodSearchRanker.History) outranks this list.
//
//  Curated, not crowdsourced: staples first (dairy, bread, atta, oil,
//  biscuits, snacks, noodles, masalas). Add a brand by adding its name here;
//  spellings seen on Open Food Facts go in as aliases.
//

import Foundation

nonisolated enum PopularBrands {
    /// Household names across the country.
    static let national: [String] = [
        "Amul", "Mother Dairy", "Mother Diary", "Nandini", "Britannia", "Parle", "Haldiram's", "Haldirams",
        "Nestle", "Nestlé", "Maggi", "Aashirvaad", "Tata", "Tata Sampann", "Fortune", "MTR", "Kellogg's",
        "Cadbury", "Lay's", "Kurkure", "Bingo", "Sunfeast", "Patanjali", "Dabur", "Modern", "Harvest Gold",
        "iD", "iD Fresh", "Saffola", "Everest", "MDH", "Bikano", "Bikaji", "Kissan", "Knorr",
    ]

    /// Big regional or category brands.
    static let regional: [String] = [
        "Milky Mist", "MilkyMist", "Heritage", "Aavin", "Verka", "Gowardhan", "Epigamia", "Hatsun", "Arokya",
        "Govind", "Sudha", "Akshayakalpa", "Akshaykalpa", "Nutralite", "Real", "Paper Boat", "Tropicana",
        "Yippee", "Ching's", "Catch", "Priyagold", "Unibic", "McCain", "Venky's", "Aashirvaad Svasti",
        "Quaker", "Saffola Oats", "Chitale", "Gits", "Eastern", "Aachi", "Sakthi",
    ]

    /// Normalised brand → bonus, built once.
    static let bonus: [String: Double] = {
        var map: [String: Double] = [:]
        for name in regional { map[key(name)] = FoodSearchRanker.Weights.standard.regionalBrand }
        for name in national { map[key(name)] = FoodSearchRanker.Weights.standard.nationalBrand }
        return map
    }()

    /// "AMUL", "Amul, GCMMF", "Haldiram's" → "amul", "amul" + "gcmmf",
    /// "haldiram". OFF brands are comma-separated lists.
    static func keys(_ brand: String?) -> [String] {
        guard let brand, !brand.isEmpty else { return [] }
        guard brand.utf8.contains(44) else {  // ","
            let one = key(brand)
            return one.isEmpty ? [] : [one]
        }
        return brand.split(separator: ",").map { key(String($0)) }.filter { !$0.isEmpty }
    }

    static func key(_ name: String) -> String {
        // Dropped, not split on: "Haldiram's" is one word.
        // 39 = "'"; 226 leads "’" in UTF-8.
        let bare = name.utf8.contains { $0 == 39 || $0 == 226 }
            ? name.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            : name
        return FoodSearchText.words(bare).joined(separator: " ")
    }
}
