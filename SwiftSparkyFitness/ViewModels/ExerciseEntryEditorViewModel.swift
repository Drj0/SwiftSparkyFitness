//
//  ExerciseEntryEditorViewModel.swift
//  SwiftSparkyFitness
//
//  Replaces the old flat LogExerciseViewModel now that the real backend
//  schema is known: `exercise_entries.duration_minutes` and
//  `calories_burned` are always required (client-supplied, never
//  server-recalculated — verified live), and `modality` decides what else
//  the form needs:
//
//    weightReps        -> sets (reps + weight, + optional RPE/notes)
//    repsOnly          -> sets (reps only)
//    duration          -> nothing extra
//    durationDistance  -> distance (+ optional avg heart rate)
//
//  `sets`/`distance`/`avgHeartRate` are additive on top of the always-
//  present duration+calories, not alternatives to them — a real
//  `exercise_entry_sets` row still sits under a session that also has its
//  own total duration.
//

import Foundation
import Combine

/// One row of the strength set editor. Kept as strings (like the rest of
/// this app's numeric fields) so an in-progress "10." doesn't get rejected
/// mid-type; converted to real numbers only at save.
struct ExerciseSetRow: Identifiable, Equatable {
    let id = UUID()
    var repsText = ""
    var weightText = ""
    var rpeText = ""
    var notes = ""

    func input(setNumber: Int) -> ExerciseSetInput {
        ExerciseSetInput(
            setNumber: setNumber,
            reps: Int(repsText),
            weight: Double(weightText),
            rpe: Double(rpeText),
            notes: notes.isEmpty ? nil : notes
        )
    }

    var isBlank: Bool { repsText.isEmpty && weightText.isEmpty }
}

@MainActor
final class ExerciseEntryEditorViewModel: ObservableObject {
    let exercise: Exercise
    let modality: ExerciseModality

    @Published var durationMinutesText = ""
    @Published var caloriesText = ""
    @Published var distanceText = ""
    @Published var avgHeartRateText = ""
    @Published var notes = ""
    @Published var setRows: [ExerciseSetRow]

    @Published private(set) var durationError: String?
    @Published private(set) var caloriesError: String?
    @Published private(set) var distanceError: String?
    @Published private(set) var setsError: String?
    @Published private(set) var isSaving = false
    @Published var bannerMessage: String?
    /// Distance is stored in the user's preferred unit (see
    /// HealthWorkoutImporter), so the field has to say which one it is.
    @Published private(set) var distanceUnit = UserPreferences.serverDefaults.distanceUnitLabel

    private let apiClient: APIClientProtocol
    private let existingEntryId: String?
    private let entryDate: Date
    var isEditing: Bool { existingEntryId != nil }

    func loadDistanceUnit() async {
        guard modality == .durationDistance, let preferences = try? await apiClient.userPreferences() else { return }
        distanceUnit = preferences.distanceUnitLabel
    }

    /// Create mode: a freshly-materialized or already-owned exercise, no
    /// prior entry.
    init(exercise: Exercise, entryDate: Date = Date(), apiClient: APIClientProtocol = AppServices.client) {
        self.exercise = exercise
        self.modality = exercise.modality ?? .duration
        self.entryDate = entryDate
        self.existingEntryId = nil
        self.apiClient = apiClient
        self.setRows = modality.usesSets ? [ExerciseSetRow()] : []
    }

    /// Edit mode: reopens an already-logged session, prefilled from it
    /// rather than the exercise's defaults — `entry.effectiveModality`
    /// covers the case where the live catalog exercise was later edited to
    /// a different modality than what was actually logged.
    init(editing entry: ExerciseSessionSummary, exercise: Exercise, apiClient: APIClientProtocol = AppServices.client) {
        self.exercise = exercise
        self.modality = entry.effectiveModality
        self.entryDate = ExerciseEntryEditorViewModel.parseEntryDate(entry.entryDate) ?? Date()
        self.existingEntryId = entry.id
        self.apiClient = apiClient
        self.durationMinutesText = entry.durationMinutes.map { $0 > 0 ? String(Int($0)) : "" } ?? ""
        self.caloriesText = entry.caloriesBurned.map { $0 > 0 ? String(Int($0)) : "" } ?? ""
        self.distanceText = entry.distance.map(Self.trimmedNumber) ?? ""
        self.avgHeartRateText = entry.avgHeartRate.map { String($0) } ?? ""
        self.notes = entry.notes ?? ""
        let existingSets = entry.setsList.map { set -> ExerciseSetRow in
            var row = ExerciseSetRow()
            row.repsText = set.reps.map { String($0) } ?? ""
            row.weightText = set.weight.map(Self.trimmedNumber) ?? ""
            row.rpeText = set.rpe.map(Self.trimmedNumber) ?? ""
            row.notes = set.notes ?? ""
            return row
        }
        self.setRows = modality.usesSets ? (existingSets.isEmpty ? [ExerciseSetRow()] : existingSets) : []
    }

    /// "100" for a whole weight/distance/RPE, "102.5" for a fractional one —
    /// `String(Double)` alone always renders "100.0", which reads oddly in a
    /// field the user is about to keep typing into.
    private static func trimmedNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func parseEntryDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.date(from: string)
    }

    private var durationMinutes: Double? {
        Double(durationMinutesText).flatMap { $0 > 0 ? $0 : nil }
    }

    private var caloriesBurned: Double? {
        Double(caloriesText).flatMap { $0 > 0 ? $0 : nil }
    }

    private var distance: Double? {
        Double(distanceText).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Rough time for a set-based session the user didn't time: about two
    /// minutes a set including rest. Only used when duration is left blank.
    static let minutesPerSet: Double = 2

    /// What the calorie math and the saved entry use: the typed duration, or
    /// for a set-based exercise with none typed, one derived from its sets.
    var effectiveMinutes: Double? {
        if let durationMinutes { return durationMinutes }
        guard modality.usesSets else { return nil }
        let sets = setRows.filter { !$0.isBlank }.count
        return sets > 0 ? Double(sets) * Self.minutesPerSet : nil
    }

    /// The last figure this model wrote into the calories field. While the
    /// field still holds it, it's ours to update; once it differs, the user
    /// typed their own number and it's left alone.
    private var lastEstimateText: String?

    var caloriesAreEstimated: Bool { !caloriesText.isEmpty && caloriesText == lastEstimateText }

    /// A default the user can override, not a locked-in figure — the server
    /// never recalculates this, it stores whatever is sent. The rate comes
    /// from ExerciseSearchViewModel (catalog MET × weight, else a provider's
    /// figure); a custom exercise has none, so there is nothing to default
    /// from. nil once the user has typed their own number.
    var estimatedCalories: Double? {
        guard caloriesText.isEmpty || caloriesAreEstimated,
              let rate = exercise.caloriesPerHour, rate > 0, let minutes = effectiveMinutes else { return nil }
        return (rate * minutes / 60).rounded()
    }

    /// Keeps the calories field following duration/sets as they change, so
    /// Save has a sensible figure even if the user never looks at it — and
    /// stops the moment they type their own.
    func applyEstimateIfNeeded() {
        guard let estimated = estimatedCalories else { return }
        caloriesText = String(Int(estimated))
        lastEstimateText = caloriesText
    }

    func addSet() {
        setRows.append(ExerciseSetRow())
    }

    func removeSet(_ row: ExerciseSetRow) {
        guard setRows.count > 1 else { return }
        setRows.removeAll { $0.id == row.id }
    }

    @discardableResult
    private func validate() -> Bool {
        durationError = effectiveMinutes == nil ? "How many minutes?" : nil
        caloriesError = caloriesBurned == nil ? "How many calories?" : nil
        distanceError = modality == .durationDistance && distance == nil ? "How far?" : nil
        if modality.usesSets {
            let usable = setRows.filter { !$0.isBlank }
            setsError = usable.isEmpty ? "Add at least one set." : nil
        } else {
            setsError = nil
        }
        return durationError == nil && caloriesError == nil && distanceError == nil && setsError == nil
    }

    private func buildInput() -> ExerciseEntryInput? {
        guard validate(), let minutes = effectiveMinutes, let calories = caloriesBurned else { return nil }
        var input = ExerciseEntryInput(
            exerciseId: exercise.id, modality: modality, entryDate: entryDate,
            durationMinutes: minutes, caloriesBurned: calories,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        )
        if modality == .durationDistance {
            input.distance = distance
            input.avgHeartRate = Int(avgHeartRateText)
        }
        if modality.usesSets {
            input.sets = setRows.filter { !$0.isBlank }.enumerated().map { index, row in row.input(setNumber: index + 1) }
        }
        return input
    }

    @discardableResult
    func save() async -> Bool {
        guard let input = buildInput() else {
            Haptics.error()
            return false
        }
        isSaving = true
        bannerMessage = nil
        defer { isSaving = false }
        do {
            if let existingEntryId {
                _ = try await apiClient.updateExerciseEntry(id: existingEntryId, input)
            } else {
                _ = try await apiClient.createExerciseEntry(input)
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
