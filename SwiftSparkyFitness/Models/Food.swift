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

struct Food: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let brand: String?
    let defaultVariant: FoodVariant?
    /// True for a result from an external database (OpenFoodFacts) that
    /// isn't in our local `foods` table yet. Logging one sends a nutrition
    /// snapshot only — no food_id/variant_id, since neither exists locally.
    var isExternal: Bool = false

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
struct FoodSuggestions: Decodable {
    let recentFoods: [Food]
    let topFoods: [Food]

    static let none = FoodSuggestions(recentFoods: [], topFoods: [])
}
