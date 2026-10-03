//
//  OpenFoodFactsProduct.swift
//  SwiftSparkyFitness
//
//  GET /api/foods/openfoodfacts/search proxies OpenFoodFacts directly — free,
//  keyless, and confirmed live to return real matches (e.g. "aloo" returns 20
//  real products server-side).
//
//  THIS MUST BE DECODED WITH KEYS TAKEN VERBATIM
//  ---------------------------------------------
//  An earlier comment here claimed the explicit CodingKeys below made it
//  decode "correctly regardless of" the shared decoder's
//  `.convertFromSnakeCase`. That is backwards, and it silently broke the
//  whole integration.
//
//  The strategy transforms the *incoming JSON key* before matching it against
//  a CodingKey, so `product_name` arrives as `productName` and never matches
//  the key `"product_name"`. Hyphens are indeed left alone, but the
//  underscore isn't: `energy-kcal_100g` becomes `energy-kcal100g`.
//
//  The result decoded without ever throwing — 20 products, every field nil —
//  so `asFood` returned nil for all of them and search quietly fell back to
//  local foods only. Measured against the live server: shared decoder gives
//  0 usable foods, a plain one gives 19 from the same bytes.
//
//  Hence the call site passes `verbatimKeys: true`. Don't remove it.
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

    /// `products` from the server proxy and the legacy search; `hits` from
    /// Search-a-licious (search.openfoodfacts.org), which the app now calls
    /// directly. Same product objects in both.
    private enum CodingKeys: String, CodingKey {
        case products, hits
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
        let lenient = try container.decodeIfPresent([LenientProduct].self, forKey: .products)
            ?? container.decode([LenientProduct].self, forKey: .hits)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        productNameEn = try container.decodeIfPresent(String.self, forKey: .productNameEn)
        nutriments = try container.decodeIfPresent(Nutriments.self, forKey: .nutriments)
        // A comma-joined string from the legacy search, an array from
        // Search-a-licious.
        if let list = try? container.decodeIfPresent([String].self, forKey: .brands) {
            brands = list.isEmpty ? nil : list.joined(separator: ", ")
        } else {
            brands = try container.decodeIfPresent(String.self, forKey: .brands)
        }
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
    /// is user-submitted and routinely has entries too sparse to log against —
    /// or numbers that can't be true (`isPlausible`).
    var asFood: Food? {
        let name = [productNameEn, productName].compactMap { $0 }.first { !$0.isEmpty }
        guard let name, let calories = nutriments?.energyKcal100g, isPlausible(calories) else { return nil }
        let variant = FoodVariant(
            id: "off-variant-\(code ?? UUID().uuidString)",
            servingSize: 100, servingUnit: "g",
            calories: calories, protein: nutriments?.proteins100g,
            carbs: nutriments?.carbohydrates100g, fat: nutriments?.fat100g
        )
        return Food(id: "off-\(code ?? UUID().uuidString)", name: name, brand: brands, defaultVariant: variant, source: .openFoodFacts)
    }

    /// Per 100 g nothing passes 900 kcal (pure fat), and with all three
    /// macros known they must roughly make the energy (4 kcal/g protein and
    /// carbs, 9 fat). Loose — fibre, polyols and rounding all move it — but
    /// it catches the typed-in-the-wrong-box entries: "Chole with rice" at
    /// 300 kcal with 74 g protein.
    private func isPlausible(_ calories: Double) -> Bool {
        guard calories > 0, calories <= 900 else { return false }
        guard calories >= 50, let n = nutriments, let protein = n.proteins100g,
              let carbs = n.carbohydrates100g, let fat = n.fat100g else { return true }
        return abs(4 * protein + 4 * carbs + 9 * fat - calories) <= 0.4 * calories
    }
}
