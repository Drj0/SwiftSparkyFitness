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
            weight: weightText.parsedDecimal,
            rpe: rpeText.parsedDecimal,
            notes: notes.isEmpty ? nil : notes
        )
    }

    var isBlank: Bool { repsText.isEmpty && weightText.isEmpty }
}

extension String {
    /// A number field's value: "22.5", or "22,5" where the decimal pad
    /// types a comma. `Double("22,5")` is nil, which silently dropped a
    /// typed weight on save and restarted the steppers from zero.
    var parsedDecimal: Double? {
        Double(trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
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
    @Published private(set) var isDeleting = false
    @Published var bannerMessage: String?
    /// Distance is stored in the user's preferred unit (see
    /// HealthWorkoutImporter), so the field has to say which one it is.
    @Published private(set) var distanceUnit = UserPreferences.serverDefaults.distanceUnitLabel
    /// Same rule for set weights: labelled from the preference, never
    /// converted. The field used to say "kg" whatever the preference was.
    @Published private(set) var weightUnit = UserPreferences.serverDefaults.weightUnitLabel

    /// The session this one started from — the last time this exercise was
    /// logged — when there is one. Nil in edit mode.
    let lastSession: ExerciseLastSession?

    private let apiClient: APIClientProtocol
    private let existingEntryId: String?
    private let entryDate: Date
    var isEditing: Bool { existingEntryId != nil }
    /// The time the entry already carries when reopened. Saving must send it
    /// back: an edit used to clear it, which would stop an imported workout
    /// being matched against a hand-logged one.
    private var existingEntryTime: String?

    /// The form's content as it opened (including anything prefilled from
    /// the last session); edits are measured against this.
    private var baseline = ""
    private var snapshot: String {
        let sets = setRows.map { [$0.repsText, $0.weightText, $0.rpeText, $0.notes].joined(separator: "|") }
        return ([durationMinutesText, caloriesText, distanceText, avgHeartRateText, notes] + sets).joined(separator: "\n")
    }
    var isDirty: Bool { snapshot != baseline }

    /// True when the form opened pre-filled from `lastSession`: the common
    /// case is then just Save, so nothing grabs focus and raises a keyboard
    /// over it.
    var startsFromLastSession: Bool { lastSession != nil && !isEditing }

    func loadUnits() async {
        guard let preferences = try? await apiClient.userPreferences() else { return }
        distanceUnit = preferences.distanceUnitLabel
        weightUnit = preferences.weightUnitLabel
    }

    /// Create mode: a freshly-materialized or already-owned exercise, no
    /// prior entry — started from `lastSession` when there is one.
    init(
        exercise: Exercise,
        entryDate: Date = Date(),
        lastSession: ExerciseLastSession? = nil,
        apiClient: APIClientProtocol = AppServices.client
    ) {
        let modality = exercise.modality ?? .duration
        self.exercise = exercise
        self.modality = modality
        self.entryDate = entryDate
        self.existingEntryId = nil
        self.apiClient = apiClient
        // A last session logged under another modality (the exercise was
        // since edited) doesn't describe this form's fields.
        let usable = lastSession.flatMap { last in (last.modality ?? modality) == modality ? last : nil }
        self.lastSession = usable
        let previousSets = (usable?.sets ?? []).map { set -> ExerciseSetRow in
            var row = ExerciseSetRow()
            row.repsText = set.reps.map { String($0) } ?? ""
            row.weightText = set.weight.map(Self.trimmedNumber) ?? ""
            return row
        }
        self.setRows = modality.usesSets ? (previousSets.isEmpty ? [ExerciseSetRow()] : previousSets) : []
        if let usable, !modality.usesSets {
            // Set-based sessions' minutes were usually the 2-a-set estimate,
            // so only timed modalities carry their duration over.
            durationMinutesText = usable.durationMinutes > 0 ? Self.trimmedNumber(usable.durationMinutes) : ""
            distanceText = usable.distance.map(Self.trimmedNumber) ?? ""
        }
        applyEstimateIfNeeded()
        baseline = snapshot
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
        self.existingEntryTime = entry.entryTime
        self.apiClient = apiClient
        self.lastSession = nil
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
        baseline = snapshot
    }

    /// "100" for a whole weight/distance/RPE, "102.5" for a fractional one —
    /// `String(Double)` alone always renders "100.0", which reads oddly in a
    /// field the user is about to keep typing into. Two places at most, so a
    /// half-step from 2.2 reads 1.7 rather than 1.7000000000000002, in the
    /// locale's own decimal separator (`parsedDecimal` reads either back).
    private static func trimmedNumber(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    private static func parseEntryDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.date(from: string)
    }

    private var durationMinutes: Double? {
        durationMinutesText.parsedDecimal.flatMap { $0 > 0 ? $0 : nil }
    }

    private var caloriesBurned: Double? {
        caloriesText.parsedDecimal.flatMap { $0 > 0 ? $0 : nil }
    }

    private var distance: Double? {
        distanceText.parsedDecimal.flatMap { $0 > 0 ? $0 : nil }
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
        caloriesText = Self.trimmedNumber(estimated)
        lastEstimateText = caloriesText
    }

    /// Starts from the last set's reps and weight: most sets repeat the one
    /// before, so the common case is one tap and the rest is an edit.
    func addSet() {
        var next = ExerciseSetRow()
        if let last = setRows.last {
            next.repsText = last.repsText
            next.weightText = last.weightText
        }
        setRows.append(next)
        applyEstimateIfNeeded()
    }

    func removeSet(_ row: ExerciseSetRow) {
        guard setRows.count > 1 else { return }
        setRows.removeAll { $0.id == row.id }
        applyEstimateIfNeeded()
    }

    // MARK: - Steppers

    enum SetField { case reps, weight }

    /// A plate's worth either side: 2.5 kg, 5 lb, or half a stone.
    var weightStep: Double {
        switch weightUnit {
        case "lb": return 5
        case "st": return 0.5
        default: return 2.5
        }
    }

    /// −/+ on a set's reps or weight. A blank field starts from the set
    /// above — the next set is usually the same — or from zero. Zero goes
    /// back to blank, so stepping a blank row up and down leaves it blank
    /// rather than a saved "0 kg" set.
    func step(_ row: ExerciseSetRow, _ field: SetField, by direction: Double) {
        guard let index = setRows.firstIndex(where: { $0.id == row.id }) else { return }
        let keyPath: WritableKeyPath<ExerciseSetRow, String> = field == .reps ? \.repsText : \.weightText
        let increment = field == .reps ? 1 : weightStep
        let above = index > 0 ? setRows[index - 1][keyPath: keyPath].parsedDecimal : nil
        let current = setRows[index][keyPath: keyPath].parsedDecimal ?? above ?? 0
        let next = max(0, current + direction * increment)
        setRows[index][keyPath: keyPath] = next == 0 ? "" : Self.trimmedNumber(next)
        applyEstimateIfNeeded()
    }

    /// Minutes in fives — sessions get rounded that way anyway. An odd
    /// figure goes to the next five in the direction pressed: 32 becomes 35
    /// or 30, never 25.
    ///
    /// A blank strength duration starts from the estimate its placeholder
    /// shows ("≈ 16"), so + can't drop it to 5.
    func stepDuration(by direction: Double) {
        let current = durationMinutesText.parsedDecimal ?? (modality.usesSets ? effectiveMinutes ?? 0 : 0)
        let fives = direction > 0 ? (current / 5).rounded(.down) : (current / 5).rounded(.up)
        let next = max(0, (fives + direction) * 5)
        durationMinutesText = next == 0 ? "" : Self.trimmedNumber(next)
        applyEstimateIfNeeded()
    }

    /// The preset chips under Duration.
    func setDuration(_ minutes: Int) {
        durationMinutesText = String(minutes)
        applyEstimateIfNeeded()
    }

    /// Half a kilometre (or mile) either side.
    func stepDistance(by direction: Double) {
        let current = distanceText.parsedDecimal ?? 0
        let next = max(0, current + direction * 0.5)
        distanceText = next == 0 ? "" : Self.trimmedNumber(next)
    }

    // MARK: - Delete

    /// Edit mode only: removing the entry from inside it, where the user
    /// already is, rather than only by swiping its row.
    @discardableResult
    func delete() async -> Bool {
        guard let existingEntryId else { return false }
        isDeleting = true
        bannerMessage = nil
        defer { isDeleting = false }
        do {
            try await apiClient.deleteExerciseEntry(id: existingEntryId)
            Haptics.warning()
            return true
        } catch {
            bannerMessage = error.localizedDescription
            Haptics.error()
            return false
        }
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
        // When it was logged, so it can be matched to a Health workout from
        // the same time. Only for today: a past day has no meaningful "now".
        if isEditing {
            input.entryTime = existingEntryTime
        } else {
            input.stampTimeIfToday()
        }
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
