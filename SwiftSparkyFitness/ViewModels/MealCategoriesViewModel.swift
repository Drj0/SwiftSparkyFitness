//
//  MealCategoriesViewModel.swift
//  SwiftSparkyFitness
//
//  Managing the meal categories food is logged into. See MealType for what
//  the server permits — in short, its four defaults can be hidden and given a
//  time but not renamed, reordered or deleted, and a category with food
//  logged against it can't be deleted at all.
//
//  Those two rules are enforced server-side (403 and 409), so this doesn't
//  reimplement them — it reads them off the model to decide what to *offer*,
//  and surfaces the server's refusal if one still gets through.
//

import Foundation
import Combine

@MainActor
final class MealCategoriesViewModel: ObservableObject {
    @Published private(set) var categories: [MealType] = []
    @Published private(set) var isLoading = false
    @Published private(set) var busyCategoryId: String?
    @Published var errorMessage: String?

    @Published var newName = ""
    @Published private(set) var isCreating = false

    private let apiClient: APIClientProtocol

    init(apiClient: APIClientProtocol = APIClient.shared) {
        self.apiClient = apiClient
    }

    var canCreate: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty && !isCreating
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            categories = try await apiClient.mealTypes().sorted { $0.sortOrder < $1.sortOrder }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// New categories go after everything else. The server rejects reordering
    /// its defaults, so there's no general drag-to-reorder to fit into — the
    /// only ordering decision available is where a new one lands.
    func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let nextOrder = (categories.map(\.sortOrder).max() ?? 0) + 10
            _ = try await apiClient.createMealType(name: name, sortOrder: nextOrder)
            newName = ""
            Haptics.success()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func setVisible(_ visible: Bool, for category: MealType) async {
        busyCategoryId = category.id
        errorMessage = nil
        defer { busyCategoryId = nil }
        do {
            _ = try await apiClient.updateMealType(id: category.id, MealTypeInput(isVisible: visible))
            Haptics.selection()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            // Reload so the toggle springs back to what the server actually
            // holds rather than sitting on a change that didn't happen.
            await load()
        }
    }

    func rename(_ category: MealType, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != category.name else { return }
        guard !category.isSystemDefault else {
            // The UI doesn't offer this, and the server would answer 403.
            errorMessage = "The built-in meals can't be renamed."
            return
        }
        busyCategoryId = category.id
        errorMessage = nil
        defer { busyCategoryId = nil }
        do {
            _ = try await apiClient.updateMealType(id: category.id, MealTypeInput(name: trimmed))
            Haptics.success()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// The 409 the server returns for a category still in use is the useful
    /// case here: it protects food already logged, so the message explains
    /// that rather than reporting a generic failure.
    func delete(_ category: MealType) async {
        busyCategoryId = category.id
        errorMessage = nil
        defer { busyCategoryId = nil }
        do {
            try await apiClient.deleteMealType(id: category.id)
            Haptics.warning()
            await load()
        } catch let error as APIError {
            if case .server(let message, _) = error, message.localizedCaseInsensitiveContains("still in use") {
                errorMessage = "“\(category.displayName)” still has food logged against it. Move or delete those entries first."
            } else {
                errorMessage = error.localizedDescription
            }
            Haptics.error()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
