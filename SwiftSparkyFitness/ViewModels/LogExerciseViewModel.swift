//
//  LogExerciseViewModel.swift
//  SwiftSparkyFitness
//
//  Calorie estimate is a simple MET-free heuristic (kcal/min by intensity)
//  since no calorie-estimation endpoint was verified — good enough for a
//  ballpark and clearly a placeholder science; swap for a real formula or
//  server estimate later.
//

import Foundation
import Combine

enum ExerciseIntensity: String, CaseIterable {
    case light = "Light", moderate = "Moderate", vigorous = "Vigorous"

    var caloriesPerMinute: Double {
        switch self {
        case .light: return 4
        case .moderate: return 8
        case .vigorous: return 12
        }
    }
}

@MainActor
final class LogExerciseViewModel: ObservableObject {
    @Published var activityName = ""
    @Published var durationMinutesText = ""
    @Published var intensity: ExerciseIntensity = .moderate

    @Published private(set) var activityError: String?
    @Published private(set) var durationError: String?
    @Published private(set) var isSaving = false
    @Published var bannerMessage: String?

    private let apiClient: APIClientProtocol
    /// Set when Diary reopens this sheet on an already-logged session —
    /// save() then PUTs that entry (against its real exercise id, no
    /// findOrCreateExercise lookup needed) instead of POSTing a new one.
    private let existingEntryId: String?
    private let existingExerciseId: String?
    private let entryDate: Date
    var isEditing: Bool { existingEntryId != nil }

    init(apiClient: APIClientProtocol = APIClient.shared) {
        self.apiClient = apiClient
        self.existingEntryId = nil
        self.existingExerciseId = nil
        self.entryDate = Date()
    }

    /// Diary's edit path: prefills from an already-logged session. Duration
    /// and name come straight from the entry; intensity has no server-side
    /// equivalent (it's purely this sheet's way of deriving a calorie
    /// estimate), so it's reverse-picked as whichever preset's kcal/min is
    /// closest to what was actually logged — an approximation, not a stored
    /// fact, and re-saving without changing duration will land on the same
    /// calorie figure only if it happens to match a preset exactly.
    init(
        editingEntryId id: String, exerciseId: String, name: String,
        durationMinutes: Double, caloriesBurned: Double, entryDate: Date,
        apiClient: APIClientProtocol = APIClient.shared
    ) {
        self.apiClient = apiClient
        self.existingEntryId = id
        self.existingExerciseId = exerciseId
        self.entryDate = entryDate
        self.activityName = name
        self.durationMinutesText = durationMinutes > 0 ? String(Int(durationMinutes)) : ""
        let actualRate = durationMinutes > 0 ? caloriesBurned / durationMinutes : ExerciseIntensity.moderate.caloriesPerMinute
        self.intensity = ExerciseIntensity.allCases.min {
            abs($0.caloriesPerMinute - actualRate) < abs($1.caloriesPerMinute - actualRate)
        } ?? .moderate
    }

    private var durationMinutes: Double? {
        Double(durationMinutesText).flatMap { $0 > 0 ? $0 : nil }
    }

    var estimatedCalories: Double? {
        durationMinutes.map { $0 * intensity.caloriesPerMinute }
    }

    @discardableResult
    private func validate() -> Bool {
        activityError = activityName.trimmingCharacters(in: .whitespaces).isEmpty ? "What did you do?" : nil
        durationError = durationMinutes == nil ? "How many minutes?" : nil
        return activityError == nil && durationError == nil
    }

    @discardableResult
    func save() async -> Bool {
        guard validate(), let minutes = durationMinutes else {
            Haptics.error()
            return false
        }
        isSaving = true
        bannerMessage = nil
        defer { isSaving = false }
        do {
            let caloriesBurned = minutes * intensity.caloriesPerMinute
            if let existingEntryId, let existingExerciseId {
                _ = try await apiClient.updateExerciseEntry(id: existingEntryId, ExerciseEntryInput(
                    exerciseId: existingExerciseId, durationMinutes: minutes,
                    caloriesBurned: caloriesBurned, entryDate: entryDate
                ))
            } else {
                let exercise = try await apiClient.findOrCreateExercise(named: activityName)
                _ = try await apiClient.createExerciseEntry(ExerciseEntryInput(
                    exerciseId: exercise.id, durationMinutes: minutes,
                    caloriesBurned: caloriesBurned, entryDate: entryDate
                ))
            }
            Haptics.success()
            return true
        } catch {
            bannerMessage = error.localizedDescription
            Haptics.error()
            return false
        }
    }
}
