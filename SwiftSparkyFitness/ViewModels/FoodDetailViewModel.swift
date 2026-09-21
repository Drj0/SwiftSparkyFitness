//
//  FoodDetailViewModel.swift
//  SwiftSparkyFitness
//
//  The portion screen: macros recompute live off the gram stepper, scaled
//  from the food's default variant.
//

import Foundation
import Combine

@MainActor
final class FoodDetailViewModel: ObservableObject {
    let food: Food
    @Published var quantity: Double
    @Published var selectedMealType: MealType
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    let mealTypes: [MealType]
    private let apiClient: APIClientProtocol
    /// Set when Diary reopens this sheet on an already-logged entry — save()
    /// then PUTs to that entry instead of POSTing a new one. `nil` is the
    /// normal Module 2 create flow (Today's Log Food).
    private let existingEntryId: String?
    private let entryDate: Date
    var isEditing: Bool { existingEntryId != nil }

    init(
        food: Food, mealTypes: [MealType], initialMealType: MealType,
        existingEntryId: String? = nil, initialQuantity: Double? = nil, entryDate: Date = Date(),
        apiClient: APIClientProtocol = APIClient.shared
    ) {
        self.food = food
        self.mealTypes = mealTypes.sorted { $0.sortOrder < $1.sortOrder }
        self.selectedMealType = initialMealType
        // Create mode starts at the food's base serving size (a sensible
        // default for something never logged before). Edit mode must start
        // at what's actually logged — defaulting to the base serving size
        // there would silently rewrite a 100g entry down to 50g on open.
        self.quantity = initialQuantity ?? food.defaultVariant?.servingSize ?? 100
        self.existingEntryId = existingEntryId
        self.entryDate = entryDate
        self.apiClient = apiClient
    }

    private var scale: Double {
        let base = food.defaultVariant?.servingSize ?? 1
        return base > 0 ? quantity / base : 1
    }

    var scaledCalories: Double { (food.defaultVariant?.calories ?? 0) * scale }
    var scaledProtein: Double { (food.defaultVariant?.protein ?? 0) * scale }
    var scaledCarbs: Double { (food.defaultVariant?.carbs ?? 0) * scale }
    var scaledFat: Double { (food.defaultVariant?.fat ?? 0) * scale }
    var servingUnit: String { food.defaultVariant?.servingUnit ?? "g" }

    func step(by amount: Double) {
        quantity = max(0, quantity + amount)
    }

    @discardableResult
    func save() async -> Bool {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            // An OpenFoodFacts result isn't a row in our `foods` table yet —
            // persist it first (same call "Enter food manually" makes),
            // then log the entry against that real food/variant id.
            let loggableFood = food.isExternal ? try await apiClient.materializeExternalFood(food) : food
            let input = FoodEntryInput(food: loggableFood, mealTypeId: selectedMealType.id, quantity: quantity, entryDate: entryDate)
            if let existingEntryId {
                try await apiClient.updateFoodEntry(id: existingEntryId, input)
            } else {
                try await apiClient.createFoodEntry(input)
            }
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            return false
        }
    }
}
