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
