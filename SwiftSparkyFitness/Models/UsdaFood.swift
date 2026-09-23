//
//  UsdaFood.swift
//  SwiftSparkyFitness
//
//  USDA FoodData Central, which is what makes *generic* foods findable —
//  "Apple, raw", "Cheeseburger, NFS", "Rice, white, cooked". OpenFoodFacts is
//  a packaged-product database and has none of those: searching it for
//  "apple" returns apple *juice* cartons, and "cheeseburger" returns only
//  branded fast food.
//
//  UNLIKE OPENFOODFACTS, THE BACKEND DOESN'T MAP THIS
//  --------------------------------------------------
//  `/api/foods/openfoodfacts/search` returns a shape the server has already
//  normalised. `/api/foods/usda/search` does a bare `res.json(data)` — the
//  raw FoodData Central response — so the mapping below is the app's job.
//
//  WHY BRANDED RESULTS ARE DROPPED
//  -------------------------------
//  FDC has four datasets. Foundation, SR Legacy and Survey (FNDDS) are the
//  generic ones; Branded is ~1.9M supermarket products. The backend sends no
//  `dataType` filter, so all four come back — and for "cheeseburger" the
//  first NINE results are near-identical Branded rows all literally named
//  "CHEESEBURGER", with the useful "Cheeseburger, NFS" at #12 (measured
//  against the live API).
//
//  Keeping them would push the generic entries off the end of the list while
//  duplicating OpenFoodFacts, which is already queried alongside this and is
//  the better branded source (it has real product names and brands, where
//  FDC's Branded descriptions are bare uppercase strings). So this keeps the
//  three generic datasets and drops Branded.
//
//  EVERYTHING IS PER 100 g
//  -----------------------
//  `foodNutrients` in a search response is per-100g for every dataset, which
//  is also how the OpenFoodFacts mapping models its variants — so both
//  sources produce the same shape and the portion sheet needs no special
//  case.
//

import Foundation

struct UsdaSearchResponse: Decodable {
    let foods: [UsdaFood]

    private enum CodingKeys: String, CodingKey {
        case foods
    }

    /// Decodes each food independently. The same lesson as OpenFoodFacts: an
    /// all-or-nothing array decode lets one unexpected entry discard the
    /// whole batch.
    private struct LenientFood: Decodable {
        let value: UsdaFood?
        init(from decoder: Decoder) throws {
            value = try? UsdaFood(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lenient = try container.decodeIfPresent([LenientFood].self, forKey: .foods) ?? []
        foods = lenient.compactMap(\.value)
    }
}

struct UsdaFood: Decodable {
    let fdcId: Int
    let description: String?
    let dataType: String?
    let brandOwner: String?
    let brandName: String?
    let foodNutrients: [Nutrient]?

    struct Nutrient: Decodable {
        let nutrientId: Int?
        let value: Double?
    }

    /// FDC nutrient ids. Energy has three because the dataset is inconsistent
    /// about which one it reports: 1008 is the usual kcal, and some rows carry
    /// only one of the Atwater variants instead.
    private enum NutrientID {
        static let energyKcal = 1008
        static let energyAtwaterGeneral = 2047
        static let energyAtwaterSpecific = 2048
        static let protein = 1003
        static let fat = 1004
        static let carbs = 1005
    }

    /// The datasets worth showing — see the note above on why Branded isn't
    /// one of them.
    static let genericDataTypes: Set<String> = ["Foundation", "SR Legacy", "Survey (FNDDS)"]

    var isGeneric: Bool {
        guard let dataType else { return false }
        return Self.genericDataTypes.contains(dataType)
    }

    /// A macro's value, keeping a genuine zero.
    ///
    /// Roast chicken really does have 0 g of carbohydrate, and treating that
    /// as "missing" made the portion sheet show a blank where it should show
    /// 0 g — indistinguishable from data the dataset doesn't have.
    private func macro(_ id: Int) -> Double? {
        foodNutrients?.first { $0.nutrientId == id }?.value
    }

    /// Energy, which is the one field where zero means unusable rather than
    /// true — nothing edible is 0 kcal per 100 g in this dataset, and logging
    /// it would add an entry worth nothing. Tries each id in turn because
    /// some rows report only an Atwater variant.
    private func energy(_ ids: Int...) -> Double? {
        for id in ids {
            if let match = macro(id), match > 0 { return match }
        }
        return nil
    }

    /// nil for anything that can't be logged meaningfully.
    ///
    /// The calorie check is not defensive padding: a Foundation row for
    /// "Lunchmeat, chicken breast, sliced" comes back with every nutrient
    /// null (1 in ~300 measured), and logging it would silently add a 0 kcal
    /// entry — worse than not offering it.
    var asFood: Food? {
        guard isGeneric else { return nil }
        guard let description, !description.isEmpty else { return nil }
        guard let calories = energy(
            NutrientID.energyKcal,
            NutrientID.energyAtwaterSpecific,
            NutrientID.energyAtwaterGeneral
        ) else { return nil }

        let variant = FoodVariant(
            id: "usda-variant-\(fdcId)",
            servingSize: 100, servingUnit: "g",
            calories: calories,
            protein: macro(NutrientID.protein),
            carbs: macro(NutrientID.carbs),
            fat: macro(NutrientID.fat)
        )
        return Food(
            id: "usda-\(fdcId)",
            name: description,
            // Generic rows have no brand, and that's the point of them — a
            // stray brandOwner on an SR Legacy row would read as a product.
            brand: nil,
            defaultVariant: variant,
            source: .usda
        )
    }
}
