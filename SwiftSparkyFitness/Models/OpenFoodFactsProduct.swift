//
//  OpenFoodFactsProduct.swift
//  SwiftSparkyFitness
//
//  GET /api/foods/openfoodfacts/search proxies OpenFoodFacts directly — free,
//  keyless, and confirmed live to return real matches (e.g. "aloo" returns 20
//  real products server-side). Unlike our own API, its nutriment keys use
//  hyphens ("energy-kcal_100g"), which the decoder's .convertFromSnakeCase
//  strategy doesn't touch — explicit CodingKeys here, so it decodes correctly
//  regardless of that strategy.
//
//  OpenFoodFacts entries are user-submitted and routinely inconsistent in
//  shape (a missing `nutriments`, an unexpected field type). A plain
//  `[OpenFoodFactsProduct]` array decode is all-or-nothing — ONE malformed
//  product in a batch of 20 throws and silently discards all 20, which is
//  exactly what made "aloo" show zero results despite the server having real
//  data for it (verified live: all 20 raw entries had valid names/calories).
//  OpenFoodFactsSearchResponse decodes leniently instead, dropping only the
//  individual products that don't parse.
//

import Foundation

struct OpenFoodFactsSearchResponse: Decodable {
    let products: [OpenFoodFactsProduct]

    private enum CodingKeys: String, CodingKey {
        case products
    }

    /// Decodes each product independently so one malformed entry can't take
    /// the rest of the batch down with it.
    private struct LenientProduct: Decodable {
        let value: OpenFoodFactsProduct?
        init(from decoder: Decoder) throws {
            value = try? OpenFoodFactsProduct(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = try container.decode([LenientProduct].self, forKey: .products)
        products = lenient.compactMap(\.value)
    }
}

struct OpenFoodFactsProduct: Decodable {
    let code: String?
    let brands: String?
    let productName: String?
    let productNameEn: String?
    let nutriments: Nutriments?

    private enum CodingKeys: String, CodingKey {
        case code, brands
        case productName = "product_name"
        case productNameEn = "product_name_en"
        case nutriments
    }

    struct Nutriments: Decodable {
        let energyKcal100g: Double?
        let proteins100g: Double?
        let carbohydrates100g: Double?
        let fat100g: Double?

        private enum CodingKeys: String, CodingKey {
            case energyKcal100g = "energy-kcal_100g"
            case proteins100g = "proteins_100g"
            case carbohydrates100g = "carbohydrates_100g"
            case fat100g = "fat_100g"
        }
    }

    /// nil when the product has no usable name or calorie data — OpenFoodFacts
    /// is user-submitted and routinely has entries too sparse to log against.
    var asFood: Food? {
        let name = [productNameEn, productName].compactMap { $0 }.first { !$0.isEmpty }
        guard let name, let calories = nutriments?.energyKcal100g else { return nil }
        let variant = FoodVariant(
            id: "off-variant-\(code ?? UUID().uuidString)",
            servingSize: 100, servingUnit: "g",
            calories: calories, protein: nutriments?.proteins100g,
            carbs: nutriments?.carbohydrates100g, fat: nutriments?.fat100g
        )
        return Food(id: "off-\(code ?? UUID().uuidString)", name: name, brand: brands, defaultVariant: variant, isExternal: true)
    }
}
