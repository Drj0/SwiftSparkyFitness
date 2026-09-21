//
//  CustomFoodViewModel.swift
//  SwiftSparkyFitness
//
//  Field-level validation, matching the design exactly: Save with bad
//  fields just re-shows the same sheet with errors, no alert dialog.
//

import Foundation
import Combine

@MainActor
final class CustomFoodViewModel: ObservableObject {
    @Published var name = ""
    @Published var servingSize = "1"
    @Published var servingUnit = "serving"
    @Published var calories = ""
    @Published var protein = "0"
    @Published var carbs = "0"
    @Published var fat = "0"

    @Published private(set) var nameError: String?
    @Published private(set) var caloriesError: String?
    @Published private(set) var isSaving = false
    @Published var bannerMessage: String?

    private let apiClient: APIClientProtocol

    init(apiClient: APIClientProtocol = APIClient.shared) {
        self.apiClient = apiClient
    }

    @discardableResult
    private func validate() -> Bool {
        nameError = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give this food a name." : nil

        guard let calorieValue = Double(calories) else {
            caloriesError = "Enter a number."
            return false
        }
        caloriesError = calorieValue < 0 ? "Calories can't be negative." : nil

        return nameError == nil && caloriesError == nil
    }

    @discardableResult
    func save() async -> Food? {
        guard validate() else {
            Haptics.error()
            return nil
        }
        isSaving = true
        bannerMessage = nil
        defer { isSaving = false }
        do {
            let food = try await apiClient.createCustomFood(CustomFoodInput(
                name: name, brand: nil,
                servingSize: Double(servingSize) ?? 1, servingUnit: servingUnit,
                calories: Double(calories) ?? 0,
                protein: Double(protein) ?? 0, carbs: Double(carbs) ?? 0, fat: Double(fat) ?? 0
            ))
            Haptics.success()
            return food
        } catch {
            bannerMessage = error.localizedDescription
            Haptics.error()
            return nil
        }
    }
}
