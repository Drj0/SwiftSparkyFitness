//
//  CustomExerciseViewModel.swift
//  SwiftSparkyFitness
//
//  For anything not found via search — mirrors CustomFoodViewModel's
//  field-level validation. `POST /api/exercises/` (the multipart endpoint)
//  requires `name`, `category` and `source`; `modality` is inferred from
//  category when the user doesn't pick one, matching the server's own
//  fallback (`exerciseService.ts`: cardio -> duration_distance, isometric ->
//  duration, else weight_reps) so a category-only pick still gets a sane
//  set editor.
//

import Foundation
import Combine

@MainActor
final class CustomExerciseViewModel: ObservableObject {
    @Published var name = ""
    @Published var category = ""
    @Published var modality: ExerciseModality = .weightReps

    @Published private(set) var nameError: String?
    @Published private(set) var isSaving = false
    @Published var bannerMessage: String?

    private let apiClient: APIClientProtocol

    init(apiClient: APIClientProtocol = AppServices.client) {
        self.apiClient = apiClient
    }

    @discardableResult
    private func validate() -> Bool {
        nameError = name.trimmingCharacters(in: .whitespaces).isEmpty ? "What's it called?" : nil
        return nameError == nil
    }

    func save() async -> Exercise? {
        guard validate() else {
            Haptics.error()
            return nil
        }
        isSaving = true
        bannerMessage = nil
        defer { isSaving = false }
        do {
            let trimmedCategory = category.trimmingCharacters(in: .whitespaces)
            let exercise = try await apiClient.createCustomExercise(CustomExerciseInput(
                name: name.trimmingCharacters(in: .whitespaces),
                category: trimmedCategory.isEmpty ? "Other" : trimmedCategory,
                modality: modality
            ))
            Haptics.success()
            return exercise
        } catch {
            bannerMessage = error.localizedDescription
            Haptics.error()
            return nil
        }
    }
}
