//
//  Food.swift
//  SwiftSparkyFitness
//
//  Shapes verified live against the running server: GET /api/foods returns
//  { searchResults: [Food] } (not the bare array the OpenAPI doc claims), and
//  FoodVariant fields are flat (calories/protein/... directly on it), not the
//  nested "data" object the doc's schema shows — the doc is stale here.
//

import Foundation

struct FoodVariant: Decodable, Identifiable, Hashable {
    let id: String
    let servingSize: Double?
    let servingUnit: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

/// Where a search result came from.
///
/// Replaces a bare `isExternal` flag: the app now queries two external
/// databases, and the row has to say which one a result is from — two
/// separate properties for "is it external" and "which one" would drift.
enum FoodSource: String, Hashable {
    /// Already in this server's own `foods` table.
    case local
    case openFoodFacts
    /// USDA FoodData Central: the server's search, and the everyday foods
    /// bundled with the app (BundledFoodDB.everyday).
    case usda
    /// Indian Nutrient Databank, bundled with the app — see BundledFoodDB.
    case indb

    /// Shown in the result row. Local foods aren't labelled — the absence of
    /// a source *is* the signal that it's the user's own.
    var label: String? {
        switch self {
        case .local: return nil
        case .openFoodFacts: return "Open Food"
        case .usda: return "USDA"
        case .indb: return "INDB"
        }
    }
}

extension FoodVariant {
    /// "100g", "250ml" — but "1 chapati", "2 bowl": a household unit needs
    /// the space a metric symbol doesn't.
    static func amountText(_ amount: Double, unit: String) -> String {
        let metric: Set<String> = ["g", "kg", "mg", "ml", "l", "oz", "lb"]
        return metric.contains(unit.lowercased()) ? "\(Int(amount))\(unit)" : "\(Int(amount)) \(unit)"
    }

    /// Weighed units step by 10; a chapati or a bowl steps by one.
    static func stepAmount(for unit: String) -> Double {
        ["g", "ml"].contains(unit.lowercased()) ? 10 : 1
    }
}

struct Food: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let brand: String?
    let defaultVariant: FoodVariant?
    /// Not decoded — the search endpoints don't report it, the call site knows
    /// which one it asked.
    var source: FoodSource = .local

    /// A result that isn't in our local `foods` table yet. Logging one has to
    /// materialise it first: the entry needs a real food_id, and a snapshot
    /// alone is rejected by the RLS insert policy.
    var isExternal: Bool { source != .local }

    private enum CodingKeys: String, CodingKey {
        case id, name, brand, defaultVariant
    }
}

struct FoodSearchResponse: Decodable {
    let searchResults: [Food]
}

/// `GET /api/foods` with no `name` parameter.
///
/// The endpoint has two mutually exclusive modes, verified live: given a
/// search term it returns *only* `searchResults`, and given none it returns
/// *only* these two lists. So recents can't ride along with a search — they
/// need their own call.
///
/// Both lists carry the same food shape as `searchResults`, plus one extra
/// field each (`last_used_date` on recents, `usage_count` on top). Neither is
/// modelled here: `Food`'s explicit CodingKeys ignore them, and the rows are
/// already returned in the right order.
///
/// How many come back is governed by the account's `item_display_limit`
/// preference (10 by default), not by a request parameter — passing `limit`
/// is ignored when that preference is set.
/// How a food has been logged lately, for the Log Food sheet: the
/// "5× this week" cue and one-tap re-logging at the last amount.
struct FoodLogStat: Equatable {
    var timesThisWeek: Int
    /// The amount last logged, in the food's serving unit ("2" chapati).
    var lastQuantity: Double

    /// By name and brand, not id: server mode's suggestions carry server
    /// ids while its on-device diary may hold the same food under a local
    /// one, and both describe the same thing the user logs.
    static func key(name: String, brand: String?) -> String {
        FoodSearchText.words(name).joined(separator: " ") + "|" + FoodSearchText.words(brand ?? "").joined(separator: " ")
    }

    static func key(for food: Food) -> String { key(name: food.name, brand: food.brand) }
}

struct FoodSuggestions: Decodable {
    let recentFoods: [Food]
    let topFoods: [Food]

    static let none = FoodSuggestions(recentFoods: [], topFoods: [])
}
